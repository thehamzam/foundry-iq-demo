<#
.SYNOPSIS
Checks native tenant templates against a checked-in explicitly synthetic capture without Graph reads or writes.
.EXAMPLE
./infra/tests/Test-TenantParity.ps1 -RunMutationTests
.NOTES
Uses local Bicep compilation only. Does not authenticate, collect a live baseline,
deploy, perform what-if, or prove FIC parent routing or runtime adoption.
#>
[CmdletBinding()]
param(
  [ValidateNotNullOrEmpty()]
  [string]$FixturePath = (Join-Path $PSScriptRoot 'fixtures\tenant-parity.synthetic.json'),
  [string]$BicepPath = (Join-Path $HOME '.azure/bin/bicep.exe'),
  [switch]$RunMutationTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tenantRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'tenant'

function Assert-Parity([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) {
  throw "Synthetic tenant parity fixture was not found: $FixturePath"
}
try {
  $fixture = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json -AsHashtable
} catch {
  throw "Synthetic tenant parity fixture is not valid JSON: $($_.Exception.Message)"
}
Assert-Parity ($fixture -is [hashtable]) 'Synthetic tenant parity fixture must be a JSON object.'
Assert-Parity ($fixture.schemaVersion -eq 1) 'Unsupported synthetic tenant parity fixture schema.'
Assert-Parity ($fixture.synthetic -eq $true) 'Tenant parity refuses evidence that is not explicitly marked synthetic.'
Assert-Parity ($fixture.capture -is [hashtable] -and $fixture.evidence -is [hashtable]) 'Synthetic tenant parity fixture must contain capture and evidence objects.'
$baseline = $fixture.capture
$evidence = $fixture.evidence

function Get-Tuple($Assignment) {
  "$($Assignment.principalId)|$($Assignment.resourceId)|$($Assignment.appRoleId)"
}

function Assert-Context($Context) {
  Assert-Parity ($Context.tenantId -eq $evidence.tenantId -and $Context.subscriptionId -eq $evidence.subscriptionId) 'Authentication context drift.'
}

function Assert-AuthenticationTenantContract($Template, $ParameterDocument) {
  $tenantParameter = $Template.parameters.tenantId
  Assert-Parity ($tenantParameter.type -eq 'string' -and -not $tenantParameter.ContainsKey('defaultValue')) 'Authentication tenant must be a required string parameter.'
  $tenantOutput = $Template.outputs.expectedTenantId
  Assert-Parity ($tenantOutput.type -eq 'string' -and $tenantOutput.value -eq "[parameters('tenantId')]") 'Authentication tenant output must expose the required tenant parameter.'
  Assert-Parity ($ParameterDocument.parameters.tenantId.value -eq $evidence.tenantId) 'Parameter tenant drift.'
}

function Assert-GrantContract($Grants, $Capture) {
  Assert-Parity ($Grants.Count -eq 3) 'Expected exactly three verified grants.'
  Assert-Parity (@($Grants | ForEach-Object { Get-Tuple $_ } | Sort-Object -Unique).Count -eq 3) 'Duplicate assignment tuple.'
  $assignments = @($Capture.searchAssignments) + @($Capture.ingestionAssignments)
  foreach ($grant in $Grants) {
    Assert-Parity ((($grant.Keys | Sort-Object) -join ',') -eq 'appRoleId,principalId,resourceId') 'Grant input contains unexpected fields.'
    $expected = @($evidence.assignments | Where-Object { (Get-Tuple $_) -eq (Get-Tuple $grant) })
    Assert-Parity ($expected.Count -eq 1) 'Native tuple is outside the approved three grants.'
    $actual = @($assignments | Where-Object { (Get-Tuple $_) -eq (Get-Tuple $grant) })
    Assert-Parity ($actual.Count -eq 1 -and $actual[0].id -eq $expected[0].id) 'Captured assignment ID mismatch.'
  }
}

function Assert-AdoptionGates($Fic, $Group) {
  $application = $Fic.resources.ingestionApplication
  Assert-Parity ($application.existing -eq $true -and $application.type -eq 'Microsoft.Graph/applications@v1.0') 'Application must remain existing-only.'
  Assert-Parity ((($application.properties.Keys | Sort-Object) -join ',') -eq 'uniqueName') 'Application metadata must not be managed.'
  Assert-Parity ($application.properties.uniqueName -eq "[parameters('applicationUniqueName')]") 'Application key must be a verified input, never a literal.'
  $groupProperties = $Group.resources.frontlineGroup.properties
  Assert-Parity ((($groupProperties.Keys | Sort-Object) -join ',') -eq 'displayName,mailEnabled,mailNickname,members,securityEnabled,uniqueName') 'Group writable property inventory drift.'
  Assert-Parity ($groupProperties.uniqueName -eq "[parameters('existingGroupUniqueName')]") 'Group key must be a verified input, never a literal.'
  foreach ($gate in @(@{ template = $Fic; key = 'applicationUniqueName' }, @{ template = $Group; key = 'existingGroupUniqueName' })) {
    $parameter = $gate.template.parameters[$gate.key]
    Assert-Parity ($parameter.type -eq 'string' -and $parameter.minLength -eq 1 -and -not $parameter.ContainsKey('defaultValue')) 'Adoption key must be mandatory, nonempty and have no invented default.'
  }
  Assert-Parity ($groupProperties.members.relationshipSemantics -eq 'append') 'Membership must explicitly append.'
  Assert-Parity ($groupProperties.members.relationships -eq "[parameters('memberObjectIds')]") 'Intended native membership drift.'
}

function ConvertTo-CompiledJson([string]$Name, [switch]$Parameters) {
  $operation = if ($Parameters) { 'build-params' } else { 'build' }
  $errorPath = [IO.Path]::GetTempFileName()
  try {
    $json = & $BicepPath $operation (Join-Path $tenantRoot $Name) --stdout 2> $errorPath
    $exitCode = $LASTEXITCODE
    $diagnostics = Get-Content $errorPath -Raw
    Assert-Parity ($exitCode -eq 0) "Compilation failed for ${Name}: $diagnostics"
    Assert-Parity ([string]::IsNullOrWhiteSpace($diagnostics)) "Compiler diagnostics for ${Name}: $diagnostics"
    $json | ConvertFrom-Json -AsHashtable
  } finally { Remove-Item $errorPath }
}

Assert-Parity ($baseline.failures.Count -eq 0) 'Baseline has failed reads; cannot claim parity.'
Assert-Parity ($baseline.context.tenantId -eq $evidence.tenantId -and $baseline.context.subscriptionId -eq $evidence.subscriptionId) 'Capture context drift.'
Assert-Context $baseline.context
Assert-Parity ($baseline.searchIdentity.tenantId -eq $evidence.tenantId -and $baseline.searchIdentity.principalId -eq $evidence.searchPrincipalId) 'ARM Search identity drift.'
Assert-Parity ($baseline.searchPrincipal.id -eq $evidence.searchPrincipalId -and $baseline.searchPrincipal.appId -eq $evidence.searchClientId) 'Search object/client ID drift.'
Assert-Parity ($baseline.application.id -eq $evidence.applicationObjectId -and $baseline.application.appId -eq $evidence.applicationClientId) 'Application identity drift.'
Assert-Parity ($baseline.ingestionPrincipal.id -eq $evidence.ingestionPrincipalId -and $baseline.ingestionPrincipal.appId -eq $evidence.applicationClientId) 'Ingestion SP identity drift.'
$config = Get-Content (Join-Path $tenantRoot 'bicepconfig.json') -Raw | ConvertFrom-Json -AsHashtable
Assert-Parity ($config.extensions.microsoftGraphV1_0 -eq 'br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0') 'Extension pin drift.'

$main = ConvertTo-CompiledJson 'main.bicep'
$previousTenantId = [Environment]::GetEnvironmentVariable('AZURE_TENANT_ID', 'Process')
$previousGrants = [Environment]::GetEnvironmentVariable('TENANT_APP_ROLE_GRANTS_JSON', 'Process')
try {
  $fixtureGrants = @($evidence.assignments | ForEach-Object {
    @{
      principalId = $_.principalId
      resourceId = $_.resourceId
      appRoleId = $_.appRoleId
    }
  })
  [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $evidence.tenantId, 'Process')
  [Environment]::SetEnvironmentVariable('TENANT_APP_ROLE_GRANTS_JSON', ($fixtureGrants | ConvertTo-Json -Depth 4 -Compress), 'Process')
  $parameterDocument = ConvertTo-CompiledJson 'main.bicepparam' -Parameters
} finally {
  [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $previousTenantId, 'Process')
  [Environment]::SetEnvironmentVariable('TENANT_APP_ROLE_GRANTS_JSON', $previousGrants, 'Process')
}
$parameters = if ($parameterDocument.ContainsKey('parametersJson')) { $parameterDocument.parametersJson | ConvertFrom-Json -AsHashtable } else { $parameterDocument }
$grants = @($parameters.parameters.grants.value)
Assert-GrantContract $grants $baseline
Assert-AuthenticationTenantContract $main $parameters
Assert-Parity ($main.resources.Count -eq 1) 'Main must manage assignments only.'
$assignmentResource = $main.resources.assignments
Assert-Parity ((($assignmentResource.Keys | Sort-Object) -join ',') -eq 'copy,import,properties,type') 'Assignment must be unconditional and managed; unexpected compiled fields.'
Assert-Parity ($main.parameters.grants.minLength -eq 3 -and $main.parameters.grants.maxLength -eq 3 -and -not $main.parameters.grants.ContainsKey('defaultValue')) 'Main must require exactly three grants.'
Assert-Parity ($assignmentResource.type -eq 'Microsoft.Graph/appRoleAssignedTo@v1.0') 'Wrong native assignment type.'
Assert-Parity ($assignmentResource.import -eq 'microsoftGraphV1_0') 'Assignment is not a Graph extension resource.'
Assert-Parity (($assignmentResource.properties.Keys | Sort-Object) -join ',' -eq 'appRoleId,principalId,resourceId') 'Assignment contains fields beyond its native tuple.'
Assert-Parity ($assignmentResource.copy.count -eq "[length(parameters('grants'))]") 'Assignment loop count drift.'
foreach ($field in @('principalId', 'resourceId', 'appRoleId')) {
  Assert-Parity ($assignmentResource.properties[$field] -eq "[parameters('grants')[copyIndex()].$field]") "Assignment $field expression drift."
}
Assert-Parity ($grants.Count -eq 3 -and $evidence.assignments.Count -eq 3) 'Expected exactly three verified grants.'
Assert-Parity (@($grants | ForEach-Object { Get-Tuple $_ } | Sort-Object -Unique).Count -eq 3) 'Duplicate assignment tuple.'
$allAssignments = @($baseline.searchAssignments) + @($baseline.ingestionAssignments)
Assert-Parity ($baseline.searchAssignments.Count -eq 3 -and $baseline.ingestionAssignments.Count -eq 9) 'Captured assignment inventory drift: expected three Search and nine ingestion assignments.'
Assert-Parity (@($allAssignments | ForEach-Object { Get-Tuple $_ } | Sort-Object -Unique).Count -eq 12) 'Duplicate captured assignment tuple.'
$managedTuples = @($grants | ForEach-Object { Get-Tuple $_ })
$externalAssignments = @($allAssignments | Where-Object { (Get-Tuple $_) -notin $managedTuples })
Assert-Parity ($externalAssignments.Count -eq 9) 'Exactly nine captured assignments must remain externally owned.'
foreach ($external in $externalAssignments) {
  Assert-Parity (-not [string]::IsNullOrWhiteSpace($external.id)) 'External assignment is missing its captured ID.'
  Assert-Parity (@($grants | Where-Object { (Get-Tuple $_) -eq (Get-Tuple $external) }).Count -eq 0) 'An unrelated captured assignment became managed.'
}
foreach ($expected in $evidence.assignments) {
  $tuple = Get-Tuple $expected
  $actual = @($allAssignments | Where-Object { (Get-Tuple $_) -eq $tuple })
  Assert-Parity ($actual.Count -eq 1 -and $actual[0].id -eq $expected.id) "Missing or replaced live assignment: $tuple"
  Assert-Parity (@($grants | Where-Object { (Get-Tuple $_) -eq $tuple }).Count -eq 1) "Native tuple mismatch: $tuple"
  $api = if ($expected.apiAppId -eq $baseline.graphApi.appId) { $baseline.graphApi } else { $baseline.sharePointApi }
  Assert-Parity ($api.id -eq $expected.resourceId -and $api.appId -eq $expected.apiAppId) 'API service principal mismatch.'
  $role = @($api.appRoles | Where-Object { $_.id -eq $expected.appRoleId -and $_.value -eq $expected.roleValue -and $_.isEnabled -and $_.allowedMemberTypes -contains 'Application' })
  Assert-Parity ($role.Count -eq 1) 'Role is not the intended enabled Application permission.'
}
foreach ($external in $evidence.externallyOwnedSitesReadAll) {
  Assert-Parity (@($grants | Where-Object { (Get-Tuple $_) -eq (Get-Tuple $external) }).Count -eq 0) 'External Sites.Read.All became managed.'
  Assert-Parity (@($allAssignments | Where-Object { (Get-Tuple $_) -eq (Get-Tuple $external) -and $_.id -eq $external.id }).Count -eq 1) 'External Sites.Read.All assignment drift.'
}

$fic = ConvertTo-CompiledJson 'ingestion-fic.bicep'
Assert-Parity ($fic.resources.Count -eq 2) 'FIC inventory must contain one existing app and one child.'
Assert-Parity ($fic.resources.ingestionApplication.existing -eq $true) 'Application must remain existing-only.'
Assert-Parity (($fic.resources.ingestionApplication.properties.Keys -join ',') -eq 'uniqueName') 'Application metadata must not be managed.'
Assert-Parity ($fic.resources['ingestionApplication::searchCredential'].type -eq 'Microsoft.Graph/applications/federatedIdentityCredentials@v1.0') 'FIC is not the native child resource.'
$ficProperties = $fic.resources['ingestionApplication::searchCredential'].properties
Assert-Parity (($ficProperties.Keys | Sort-Object) -join ',' -eq 'audiences,description,issuer,name,subject') 'FIC must not manage id or additional properties.'
foreach ($field in @('name', 'issuer', 'subject', 'audiences', 'description')) {
  Assert-Parity ($ficProperties[$field] -eq "[parameters('credential').$field]") "FIC $field expression drift."
}
$liveFic = @($baseline.federatedCredentials | Where-Object { $_.name -eq $evidence.federatedCredential.name })
Assert-Parity ($liveFic.Count -eq 1) 'Named FIC missing or ambiguous.'
foreach ($property in @('id', 'name', 'issuer', 'subject', 'description')) {
  Assert-Parity ($liveFic[0][$property] -eq $evidence.federatedCredential[$property]) "FIC $property drift."
}
Assert-Parity (($liveFic[0].audiences -join ',') -eq 'api://AzureADTokenExchange') 'FIC audience drift.'
Assert-Parity ($liveFic[0].subject -eq $baseline.searchPrincipal.id -and $liveFic[0].subject -ne $baseline.searchPrincipal.appId) 'FIC subject must be Search object ID.'
Assert-Parity ($null -eq $baseline.application.uniqueName) 'Application adoption gate changed; review before enabling native FIC.'
Assert-Parity (-not (Test-Path (Join-Path $tenantRoot 'ingestion-fic.bicepparam'))) 'Blocked FIC must not have synthetic live parameters.'

$group = ConvertTo-CompiledJson 'frontline-group.bicep'
Assert-AdoptionGates $fic $group
Assert-Parity ($group.resources.Count -eq 1 -and $group.resources.frontlineGroup.type -eq 'Microsoft.Graph/groups@v1.0') 'Group inventory drift.'
$groupProperties = $group.resources.frontlineGroup.properties
Assert-Parity ($groupProperties.members.relationshipSemantics -eq 'append') 'Membership must explicitly append.'
Assert-Parity (-not $groupProperties.ContainsKey('id') -and -not $groupProperties.ContainsKey('owners')) 'Group cannot write id or owners.'
Assert-Parity ($baseline.frontlineGroups.Count -eq 1) 'Ambiguous group.'
$liveGroup = $baseline.frontlineGroups[0]
foreach ($property in @('id', 'uniqueName', 'displayName', 'mailNickname', 'mailEnabled', 'securityEnabled', 'isAssignableToRole', 'onPremisesSyncEnabled')) {
  Assert-Parity ($liveGroup[$property] -eq $evidence.frontlineGroup[$property]) "Group $property drift."
}
Assert-Parity ($liveGroup.groupTypes.Count -eq 0) 'Unexpected group type.'
Assert-Parity ((($baseline.frontlineMemberIds | Sort-Object) -join ',') -eq (($evidence.frontlineGroup.memberIds | Sort-Object) -join ',')) 'Captured group membership differs from the approved baseline; review extras, do not remove them.'
foreach ($field in @('displayName', 'mailNickname', 'mailEnabled', 'securityEnabled')) {
  Assert-Parity ($groupProperties[$field] -eq $liveGroup[$field]) "Native group $field mismatch."
}
Assert-Parity ($groupProperties.members.relationships -eq "[parameters('memberObjectIds')]") 'Intended native membership drift.'
Assert-Parity ($null -eq $liveGroup.uniqueName -and -not (Test-Path (Join-Path $tenantRoot 'frontline-group.bicepparam'))) 'Group key gate must not be bypassed.'
foreach ($memberId in $evidence.frontlineGroup.memberIds) {
  Assert-Parity ($memberId -is [string] -and $baseline.frontlineMemberIds -contains $memberId) 'Synthetic member does not match selected baseline.'
}
$extraMember = $evidence.ingestionPrincipalId
$modelMembers = @($baseline.frontlineMemberIds) + @($extraMember)
$appendedMembers = @($modelMembers + $evidence.frontlineGroup.memberIds | Sort-Object -Unique)
Assert-Parity ($appendedMembers -contains $extraMember -and @($modelMembers | Where-Object { $_ -notin $appendedMembers }).Count -eq 0) 'Append contract must preserve an unrelated member (offline model only).'
foreach ($template in @($main, $fic, $group)) {
  Assert-Parity ($template.'$schema' -eq 'https://schema.management.azure.com/schemas/2019-08-01/tenantDeploymentTemplate.json#') 'Template must retain tenant deployment scope.'
  Assert-Parity ($template.imports.microsoftGraphV1_0.provider -eq 'MicrosoftGraph' -and $template.imports.microsoftGraphV1_0.version -eq '1.0.0') 'Missing native extension metadata.'
  foreach ($resource in $template.resources.Values) {
    Assert-Parity ($resource.type -in @('Microsoft.Graph/appRoleAssignedTo@v1.0', 'Microsoft.Graph/applications@v1.0', 'Microsoft.Graph/applications/federatedIdentityCredentials@v1.0', 'Microsoft.Graph/groups@v1.0')) 'Unexpected resource, SP write, deployment script or wrapper.'
  }
}
if ($RunMutationTests) {
  $fixtures = @{ grants = $grants; capture = $baseline; fic = $fic; group = $group; context = $baseline.context }
  $cases = @(
    @{ name = 'missing tuple'; mutate = { param($fixture) $fixture.grants = @($fixture.grants[0], $fixture.grants[1]) }; error = 'Expected exactly three verified grants.' }
    @{ name = 'duplicate tuple'; mutate = { param($fixture) $fixture.grants[2] = $fixture.grants[0] }; error = 'Duplicate assignment tuple.' }
    @{ name = 'wrong API SP'; mutate = { param($fixture) $fixture.grants[2].resourceId = $fixture.capture.graphApi.id }; error = 'Native tuple is outside the approved three grants.' }
    @{ name = 'unrelated role'; mutate = { param($fixture) $fixture.grants[2] = $fixture.capture.ingestionAssignments[3].Clone(); [void]$fixture.grants[2].Remove('id') }; error = 'Native tuple is outside the approved three grants.' }
    @{ name = 'fake assignment ID'; mutate = { param($fixture) $fixture.capture.searchAssignments[0].id = 'invalid-assignment-id' }; error = 'Captured assignment ID mismatch.' }
    @{ name = 'writable assignment ID'; mutate = { param($fixture) $fixture.grants[0].id = 'invalid-assignment-id' }; error = 'Grant input contains unexpected fields.' }
    @{ name = 'managed application'; mutate = { param($fixture) $fixture.fic.resources.ingestionApplication.existing = $false }; error = 'Application must remain existing-only.' }
    @{ name = 'application metadata write'; mutate = { param($fixture) $fixture.fic.resources.ingestionApplication.properties.displayName = 'replacement' }; error = 'Application metadata must not be managed.' }
    @{ name = 'invented application key'; mutate = { param($fixture) $fixture.fic.resources.ingestionApplication.properties.uniqueName = 'invented' }; error = 'Application key must be a verified input, never a literal.' }
    @{ name = 'missing group key'; mutate = { param($fixture) [void]$fixture.group.resources.frontlineGroup.properties.Remove('uniqueName') }; error = 'Group writable property inventory drift.' }
    @{ name = 'invented group key'; mutate = { param($fixture) $fixture.group.resources.frontlineGroup.properties.uniqueName = 'invented' }; error = 'Group key must be a verified input, never a literal.' }
    @{ name = 'default adoption key'; mutate = { param($fixture) $fixture.fic.parameters.applicationUniqueName.defaultValue = 'invented' }; error = 'Adoption key must be mandatory, nonempty and have no invented default.' }
    @{ name = 'replace membership'; mutate = { param($fixture) $fixture.group.resources.frontlineGroup.properties.members.relationshipSemantics = 'replace' }; error = 'Membership must explicitly append.' }
    @{ name = 'extra managed member'; mutate = { param($fixture) $fixture.group.resources.frontlineGroup.properties.members.relationships += $evidence.ingestionPrincipalId }; error = 'Intended native membership drift.' }
    @{ name = 'wrong authentication tenant'; mutate = { param($fixture) $fixture.context.tenantId = 'wrong-tenant' }; error = 'Authentication context drift.' }
    @{ name = 'wrong subscription'; mutate = { param($fixture) $fixture.context.subscriptionId = 'wrong-subscription' }; error = 'Authentication context drift.' }
  )
  foreach ($case in $cases) {
    $fixture = $fixtures | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
    & $case.mutate $fixture
    $rejected = $false
    try {
      Assert-Context $fixture.context
      Assert-GrantContract $fixture.grants $fixture.capture
      Assert-AdoptionGates $fixture.fic $fixture.group
    } catch {
      Assert-Parity ($_.Exception.Message -eq $case.error) "Mutation '$($case.name)' failed for an unexpected reason: $($_.Exception.Message)"
      $rejected = $true
    }
    Assert-Parity $rejected "Mutation '$($case.name)' was not rejected."
  }
  Write-Output "PASS: $($cases.Count) in-memory mutations of compiled artifacts and synthetic captured inputs rejected for the expected reason."
}
Write-Output 'PASS: explicitly synthetic fixture; three captured grant tuples and assignment IDs; nine external assignments; existing-only FIC; additive group contract; pinned native inventory; offline context checks.'
Write-Output 'BLOCKED: FIC and group live adoption require verified non-null uniqueName. FIC child parent routing remains unverified despite successful compilation. No deployment readiness, runtime adoption or retrieval parity claimed.'
& $BicepPath --version