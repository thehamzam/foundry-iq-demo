#requires -Version 7.4
[CmdletBinding()]
param(
  [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
  [Parameter(Mandatory)]
  [string]$CompiledTemplatePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Passed = 0
$modulePath = Join-Path $RepositoryRoot 'scripts\quickstart\Quickstart.Common.psm1'
Import-Module $modulePath -Force
. (Join-Path $PSScriptRoot 'Quickstart.TestFixture.ps1')

function Assert-Contract {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
  $script:Passed++
  Write-Host "PASS: $Message"
}

$contract = New-TestQuickstartContract
Assert-Contract (Test-QuickstartContract -Contract $contract) 'Valid canonical versioned contract is accepted'

$main = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\main.bicep') -Raw
$parameters = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\main.bicepparam') -Raw
$resources = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\resources.bicep') -Raw
$storage = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\storage.bicep') -Raw
$network = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\private-network.bicep') -Raw
$pipeline = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\custom-search-pipeline.bicep') -Raw
$module = Get-Content -LiteralPath $modulePath -Raw
$compiledTemplate = Get-Content -LiteralPath $CompiledTemplatePath -Raw | ConvertFrom-Json -Depth 100
$executableBicep = @(
  Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Filter '*.bicep'
  Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Filter '*.bicepparam'
) | ForEach-Object {
  [pscustomobject]@{
    RelativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $_.FullName)
    Content = Get-Content -LiteralPath $_.FullName -Raw
  }
}
foreach ($required in @(
  "targetScope = 'subscription'",
  "var contractSchemaVersion = '3.1.0'",
  "var resourceGroupName = 'rg-`${normalizedEnvironmentName}-`${normalizedDeploymentId}'",
  'var provenanceId = uniqueString(',
  "'quickstart.deploymentName': deployment().name",
  "'quickstart.provenanceId': provenanceId",
  'operatorPrincipalId: operatorPrincipalId',
  'functionAuthClientId: functionAuthClientId',
  'functionAuthAudience: functionAuthAudience',
  'operations: customSearchPipeline.outputs.operations',
  'provenanceId: provenanceId',
  'requiredOwnershipTags: ownershipTags'
)) {
  Assert-Contract $main.Contains($required) "Bicep contract contains $required"
}

Assert-Contract ($main -notmatch '(?im)^\s*param\s+(resourceGroupName|networkProfile)\b') 'Public entrypoint removes caller-controlled resource-group and network-profile inputs'
Assert-Contract ($parameters -notmatch '(?im)^\s*param\s+(resourceGroupName|networkProfile)\b') 'Published parameters remove stale resource-group and private-profile inputs'
Assert-Contract ($parameters -notmatch '(?i)readEnvironmentVariable|/subscriptions/|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') 'Published parameter file is placeholder-only and environment independent'
Assert-Contract ($resources -notmatch '(?i)networkProfile|publicNetworkAccess:\s*''Disabled''') 'Search and Foundry retain the sole public-keyless inbound profile'
Assert-Contract ($resources -match "project\.properties\.endpoints\['AI Foundry API'\]" -and $resources -match 'resource operatorFoundryUser') 'Contract uses the modern Foundry project endpoint and grants operator Toolbox access'
Assert-Contract ($main -match '(?m)^param embeddingCapacity int = 50$') 'Bundled corpus uses the validated 50K TPM embedding default'
Assert-Contract ($storage -match "publicNetworkAccess:\s*'Disabled'" -and $storage -match "defaultAction:\s*'Deny'") 'Storage rejects public network access'
Assert-Contract ($network -match 'Microsoft\.Network/privateEndpoints@' -and $network -match 'Microsoft\.Network/privateDnsZones@' -and $network -match 'sharedPrivateLinkResources@') 'Storage private topology and Search outbound private link are complete'
Assert-Contract ($pipeline -match 'Microsoft\.Web/sites/networkConfig@' -and $pipeline -match "vnetRouteAllEnabled:\s*true" -and $pipeline -notmatch '(?i)networkProfile|isReadOnly') 'Function uses unconditional VNet integration without mutable profile switches'
Assert-Contract ($pipeline -match "(?s)excludedPaths:\s*\[\s*'/api/health'\s*\].*?allowedPrincipals:.*?identities:\s*\[\s*searchPrincipalId\s*\]") 'Easy Auth exposes only the health route and permits only Search MI to invoke the custom skill'
Assert-Contract ($pipeline -match '(?s)registration:\s*\{.*?clientId:\s*functionAuthClientId' -and $pipeline -match 'authResourceId:\s*functionAuthAudience') 'Easy Auth and Search custom skill share the supplied Function API registration'
Assert-Contract ($main -match 'functionStorageName:\s*names\.corpusStorage' -and $pipeline -match '(?s)resource functionStorageBlobRole.*?scope:\s*functionStorage.*?roleDefinitionId:\s*storageBlobDataOwnerRoleId') 'Function host storage is covered by the Function Blob Data Owner role'
Assert-Contract ($pipeline -match 'resource functionStorageReaderRole' -and $pipeline -match "SCM_DO_BUILD_DURING_DEPLOYMENT" -and $pipeline -notmatch 'WEBSITE_RUN_FROM_PACKAGE') 'Function host has Storage Reader and uses extracted ZIP deployment'
Assert-Contract ($pipeline -match "(?s)name:\s*'chunk_id'.*?key:\s*true.*?analyzer:\s*'keyword'") 'Index projection key uses the required keyword analyzer'
Assert-Contract ($pipeline -match "kind:\s*'indexer-status'" -and $pipeline -match 'maxAttempts:\s*30' -and $pipeline -match "successStatus:\s*'success'") 'Indexer verification emits bounded terminal-success polling'
Assert-Contract ($pipeline -match "resultCollectionField:\s*'response'" -and $pipeline -match "citationCollectionField:\s*'references'" -and $pipeline -match "sourceIdField:\s*'id'") 'Retrieval verification emits non-empty result/citation source semantics'
Assert-Contract ($module -notmatch "'Invoke-QuickstartHttp'") 'Raw HTTP transport is not exported'
Assert-Contract ($module -notmatch '\[bool\]\$check\.isReadOnly') 'Authorization does not trust a mutable isReadOnly boolean'
Assert-Contract (@($executableBicep | Where-Object { $_.Content -match '(?i)\bnetworkProfile\b' }).Count -eq 0) 'Executable Bicep contains no private-profile input or binding'
Assert-Contract (@($executableBicep | Where-Object { $_.Content -match '(?im)^\s*publicNetworkAccess\s*:\s*.*\?' }).Count -eq 0) 'Executable Bicep contains no conditional public-network profile'
Assert-Contract (@($executableBicep | Where-Object { $_.Content -match '(?i)Microsoft\.(Network/(privateEndpoints|privateDnsZones)|Web/sites/networkConfig)@' }).Count -ge 1) 'Executable Bicep contains private-endpoint, private-DNS, and VNet-integration resources'
$managed = @(Assert-TestQuickstartCompiledInventory -Template $compiledTemplate)
Assert-Contract ($managed.Count -gt 0) 'Compiled inventory contains the supported private-Storage resource topology'

Write-Host "$script:Passed public quickstart contract checks passed; no Azure operation occurred."
