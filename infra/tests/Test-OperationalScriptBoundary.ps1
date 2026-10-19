[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$passed = 0

function Assert-Boundary {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
  $script:passed++
  Write-Host "PASS: $Message"
}

function Get-ScriptAst {
  param([string]$Name)
  $parseErrors = $null
  $tokens = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot "scripts/$Name"), [ref]$tokens, [ref]$parseErrors)
  Assert-Boundary ($parseErrors.Count -eq 0) "$Name parses"
  return $ast
}

$kbAst = Get-ScriptAst 'setup/03c-create-foundry-iq-kb.ps1'
$mergeFunction = $kbAst.Find({ param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -eq 'Merge-KnowledgeBaseBlobSource'
}, $true)
Assert-Boundary ($null -ne $mergeFunction) 'KB merge function is available without executing the script'
. ([scriptblock]::Create($mergeFunction.Extent.Text))

$initial = @{ name = 'kb'; knowledgeSources = @(@{ name = 'blob'; enableFreshness = $true }); retrieveDefaults = @{ maxOutputDocuments = 5 } }
$twoSource = @{ name = 'kb'; knowledgeSources = @(@{ name = 'blob'; enableFreshness = $false }, @{ name = 'sharepoint'; custom = 'keep' }); retrieveDefaults = @{ maxOutputDocuments = 8; maxOutputSizeInTokens = 6000 }; retrievalInstructions = 'preserve'; '@odata.etag' = 'etag' }
$result = Merge-KnowledgeBaseBlobSource -Existing $twoSource -Initial $initial -BlobSourceName 'blob'
Assert-Boundary ($result.knowledgeSources.Count -eq 2 -and $result.knowledgeSources[1].custom -eq 'keep') 'Existing SharePoint source survives Blob reconciliation'
Assert-Boundary ($result.retrieveDefaults.maxOutputDocuments -eq 8 -and $result.retrievalInstructions -eq 'preserve' -and -not $result.knowledgeSources[0].enableFreshness) 'Existing KB and source settings survive'
Assert-Boundary (-not $result.ContainsKey('@odata.etag')) 'ETag is not included in the request body'
$result = Merge-KnowledgeBaseBlobSource -Existing @{ knowledgeSources = @(@{ name = 'sharepoint' }); answerInstructions = 'keep' } -Initial $initial -BlobSourceName 'blob'
Assert-Boundary ($result.knowledgeSources.Count -eq 2 -and $result.answerInstructions -eq 'keep') 'Missing Blob is appended without replacing SharePoint'
$result = Merge-KnowledgeBaseBlobSource -Existing $null -Initial $initial -BlobSourceName 'blob'
Assert-Boundary ($result.knowledgeSources.Count -eq 1 -and $result.knowledgeSources[0].name -eq 'blob') 'Absent KB retains initial Blob bootstrap'
$rejected = $false
try { Merge-KnowledgeBaseBlobSource -Existing @{ name = 'invalid' } -Initial $initial -BlobSourceName 'blob' | Out-Null } catch { $rejected = $true }
Assert-Boundary $rejected 'Unreadable source collection is rejected'
Assert-Boundary ($kbAst.Extent.Text.Contains("['If-Match']") -and $kbAst.Extent.Text.Contains("['If-None-Match']")) 'KB writes carry concurrency guards'

function Get-CommandText {
  param([System.Management.Automation.Language.Ast]$Ast)
  return @($Ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
  }, $true) | ForEach-Object {
    ($_.CommandElements | ForEach-Object { $_.Extent.Text }) -join ' '
  })
}

function Test-ForbiddenProvisioning {
  param([string[]]$Commands)
  return @($Commands | Where-Object {
    $_ -match '^az role assignment (create|delete|update)\b' -or
    $_ -match '^az (identity|network|storage account|storage container|group|cognitiveservices|resource|deployment)\b.*\b(create|update|delete|deploy)\b' -or
    $_ -match '^az provider register\b' -or
    ($_ -match '^az rest\b' -and $_ -notmatch '--method GET\b')
  }).Count -gt 0
}

$uploadAst = Get-ScriptAst 'maintenance/03b-upload-corpus.ps1'
$toolboxAst = Get-ScriptAst 'maintenance/04-rewire-toolbox.ps1'
$sharePointSourceAst = Get-ScriptAst 'setup/03d-add-sharepoint-source.ps1'
$trimmingAst = Get-ScriptAst 'setup/07b-enable-trimming.ps1'
$owners = @{
  upload = $uploadAst
  knowledgeBase = $kbAst
  toolbox = $toolboxAst
}
foreach ($owner in $owners.Keys) {
  $ast = $owners[$owner]
  $commands = Get-CommandText $ast
  Assert-Boundary (-not (Test-ForbiddenProvisioning $commands)) "$owner has no duplicate ARM/RBAC/identity/network/storage provisioning"
  Assert-Boundary ($ast.Extent.Text -notmatch 'Microsoft.Authorization/roleAssignments|isSharedToAll\s*=\s*\$true') "$owner cannot declare role assignments or reset AAD sharing"
  Assert-Boundary ($ast.Extent.Text -notmatch '(?i)(client_secret|account-key|listKeys|listCredentials|password\s*=)') "$owner introduces no secret authentication or credential listing"
  $logging = @($commands | Where-Object { $_ -match '^(Write-Host|Write-Output|Write-Warning|Write-Error)\b' })
  Assert-Boundary (-not ($logging | Where-Object { $_ -match '\$(searchToken|aiToken|headers|tarB64|bootstrapJson)\b' })) "$owner does not log credentials or upload payload"
  Assert-Boundary ($ast.Extent.Text -match '\$LASTEXITCODE -ne 0' -and $ast.Extent.Text -match '\$_.scope -eq \$(Scope|storageId|searchId)' -and $ast.Extent.Text -match '\$_.principalType -eq ''ServicePrincipal''') "$owner validates read failures and exact RBAC scope/type"
}
Assert-Boundary (Test-ForbiddenProvisioning @('az role assignment create --scope fake')) 'Provisioning detector rejects role writes'
Assert-Boundary (Test-ForbiddenProvisioning @('az identity create --name fake')) 'Provisioning detector rejects UAMI writes'
Assert-Boundary (Test-ForbiddenProvisioning @('az rest --method PUT --uri fake')) 'Provisioning detector rejects ARM writes'
Assert-Boundary (-not (Test-ForbiddenProvisioning @('az container create --file job'))) 'Operational ACI creation remains allowed'
Assert-Boundary (@(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Recurse -File -Filter '03-create-foundry-project.ps1').Count -eq 0) 'Legacy raw-index project provisioner is retired'

$uploadCommands = Get-CommandText $uploadAst
Assert-Boundary (($uploadCommands | Where-Object { $_ -match '^az container create ' }).Count -eq 1 -and ($uploadCommands | Where-Object { $_ -match '^az container delete ' }).Count -eq 2) 'ACI launch and both cleanup paths remain operational'
Assert-Boundary ($uploadAst.Extent.Text.Contains('az storage blob delete-batch') -and $uploadAst.Extent.Text.Contains('az storage blob upload-batch') -and $uploadAst.Extent.Text.Contains('sample-data/documents')) 'Existing Blob corpus replacement operations remain intact'
$additivePath = Join-Path $repoRoot 'scripts/maintenance/upload-private-blob-additive.ps1'
$additiveAst = Get-ScriptAst 'maintenance/upload-private-blob-additive.ps1'
$additiveText = $additiveAst.Extent.Text
Assert-Boundary ($additiveText -notmatch '(?i)delete-batch|storage blob delete\b' -and $additiveText -match 'az container delete') 'Additive uploader never deletes Blob data and only cleans up its ACI'
Assert-Boundary ($additiveText -notmatch '(?i)\b(sas|account[-_]?key|connectionstring|listkeys|storageToken)\b') 'Additive uploader does not use keys, SAS, or connection strings'
Assert-Boundary ($additiveText -match 'snet-aci|AciSubnetName' -and $additiveText -match 'uami-demofs-upload|UamiName' -and $additiveText -match 'privateEndpoint') 'Additive uploader requires the delegated ACI subnet, UAMI, and private endpoint'
Assert-Boundary ($additiveText -match 'PackagePath' -and $additiveText -match 'DocumentPaths' -and $additiveText -match 'DocumentDestinations' -and $additiveText -match 'custom-skill.*\.zip') 'Additive uploader requires explicit package or document selections and destinations'
Assert-Boundary ($additiveText -match 'overwrite.*false' -and $additiveText -match 'destination already exists' -and $additiveText -match 'evaluation-queries\.json') 'Additive uploader preflights destinations and rejects forbidden evaluation data'
Assert-Boundary ($additiveText -match '\[System\.IO\.Path\]::GetTempPath\(\)' -and $additiveText -match 'PackageSha256' -and $additiveText -match 'PackageLength') 'Additive uploader scopes TEMP packages to the current user and requires integrity inputs'
$documentFunction = $additiveAst.Find({ param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-ApprovedFile'
}, $true)
Assert-Boundary ($null -ne $documentFunction) 'Additive uploader document allowlist is available for offline testing'
. ([scriptblock]::Create($documentFunction.Extent.Text))
$sampleRoot = Join-Path $repoRoot 'sample-data'
$documentsRoot = Join-Path $sampleRoot 'documents'
$expectedDocuments = @(
  'COMP-CHUNKLAB-303-synthetic-network-rules.md'
  'PROC-CHUNKLAB-101-synthetic-duplicate-intake.md'
  'RUN-CHUNKLAB-202-synthetic-fraud-escalation.md'
)
$actualDocuments = @(Get-ChildItem -LiteralPath $documentsRoot -File | Select-Object -ExpandProperty Name | Sort-Object)
Assert-Boundary (($actualDocuments -join '|') -ceq ($expectedDocuments -join '|')) 'Sample document allowlist matches disk reality'
foreach ($documentName in $expectedDocuments) {
  $document = Resolve-ApprovedFile -Path (Join-Path $documentsRoot $documentName) -ApprovedRoot $documentsRoot -Mode 'Document'
  Assert-Boundary ($document.Extension -ceq '.md') "Sample document is accepted by the upload allowlist: $documentName"
}
$evaluationPath = Join-Path $sampleRoot 'evaluation-queries.json'
Assert-Boundary (Test-Path -LiteralPath $evaluationPath -PathType Leaf) 'Evaluation queries remain outside the uploadable document directory'
$rejected = $false
try { Resolve-ApprovedFile -Path $evaluationPath -ApprovedRoot $sampleRoot -Mode 'Document' | Out-Null } catch { $rejected = $true }
Assert-Boundary $rejected 'Evaluation queries are rejected by the Markdown document allowlist'
$rejected = $false
try { Resolve-ApprovedFile -Path $evaluationPath -ApprovedRoot $documentsRoot -Mode 'Document' | Out-Null } catch { $rejected = $true }
Assert-Boundary $rejected 'Evaluation queries are rejected outside the approved document root'
$packageFunction = $additiveAst.Find({ param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-ApprovedPackage'
}, $true)
Assert-Boundary ($null -ne $packageFunction) 'Additive uploader exposes the package boundary resolver without executing the script'
. ([scriptblock]::Create($packageFunction.Extent.Text))
$probePackage = Join-Path ([System.IO.Path]::GetTempPath()) "demofs-boundary-$([guid]::NewGuid().ToString('N')).zip"
try {
  Set-Content -LiteralPath $probePackage -Value 'approved package probe' -Encoding ascii
  $probeHash = (Get-FileHash -LiteralPath $probePackage -Algorithm SHA256).Hash
  $resolvedProbe = Resolve-ApprovedPackage -Path $probePackage -ApprovedRoot (Join-Path $repoRoot 'custom-skill') -PackageSha256 $probeHash -PackageLength (Get-Item -LiteralPath $probePackage).Length
  Assert-Boundary ($resolvedProbe.FullName -eq (Get-Item -LiteralPath $probePackage).FullName) 'Current-user TEMP package passes exact integrity validation'
  $rejected = $false
  try { Resolve-ApprovedPackage -Path $probePackage -ApprovedRoot (Join-Path $repoRoot 'custom-skill') | Out-Null } catch { $rejected = $true }
  Assert-Boundary $rejected 'TEMP package without integrity values is rejected'
  $rejected = $false
  try { Resolve-ApprovedPackage -Path $probePackage -ApprovedRoot (Join-Path $repoRoot 'custom-skill') -PackageSha256 ('0' * 64) -PackageLength ((Get-Item -LiteralPath $probePackage).Length + 1) | Out-Null } catch { $rejected = $true }
  Assert-Boundary $rejected 'TEMP package with mismatched integrity is rejected'
} finally {
  Remove-Item -LiteralPath $probePackage -Force -ErrorAction SilentlyContinue
}
foreach ($variable in @('uamiId', 'uamiPrincipalId', 'uamiClientId', 'storageId', 'aciSubnetId')) {
  $assignment = $uploadAst.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -eq $variable
  }, $true) | Select-Object -First 1
  $consumer = $uploadAst.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$aciYaml'
  }, $true)
  Assert-Boundary ($null -ne $assignment -and $assignment.Extent.StartOffset -lt $consumer.Extent.StartOffset) "Upload dependency $variable is defined before job serialization"
}

$toolboxCommands = Get-CommandText $toolboxAst
Assert-Boundary (($toolboxCommands | Where-Object { $_ -match '^azd ai connection create ' -and $_ -match '--auth-type user-entra-token' -and $_ -match '--audience ''https://search.azure.com''' }).Count -eq 1) 'RemoteTool retains user-token Search audience'
Assert-Boundary ($sharePointSourceAst.Extent.Text.Contains("ingestionPermissionOptions = @('groupIds')")) 'SharePoint source retains group ACL ingestion'
Assert-Boundary ($sharePointSourceAst.Extent.Text.Contains('includeReferenceSourceData = $true')) 'SharePoint citations retain source document URLs'
Assert-Boundary ($trimmingAst.Extent.Text.Contains("permissionFilterOption -NotePropertyValue 'enabled'") -and
  $trimmingAst.Extent.Text.Contains("permissionFilter -NotePropertyValue 'groupIds'")) 'SharePoint index retains group permission enforcement'
$hostedRequirements = Get-Content -LiteralPath (Join-Path $repoRoot 'langgraph-agent-hosted-foundry/requirements.txt') -Raw
$hostedManifest = Get-Content -LiteralPath (Join-Path $repoRoot 'langgraph-agent-hosted-foundry/azure.yaml') -Raw
Assert-Boundary ($hostedRequirements.Contains('langchain-azure-ai[hosting,tools]==1.2.8')) 'Hosted Toolbox retains request-scoped caller forwarding support'
Assert-Boundary ($hostedManifest.Contains('version: 2.0.0')) 'Hosted protocol retains request-scoped caller context'
Assert-Boundary ($toolboxAst.Extent.Text.Contains('$bootstrap.isSharedToAll -ne $false') -and $toolboxAst.Extent.Text.Contains('--method GET --uri $bootstrapUri')) 'AAD connection is validated read-only against the non-shared baseline'
$configParameter = @($toolboxAst.ParamBlock.Parameters | Where-Object {
  $_.Name.VariablePath.UserPath -eq 'ConfigPath'
})
Assert-Boundary ($configParameter.Count -eq 1 -and $configParameter[0].StaticType -eq [string] -and
  $configParameter[0].Extent.Text -notmatch 'Mandatory') 'ConfigPath is an optional string parameter'
Assert-Boundary ($toolboxAst.Extent.Text -notmatch 'config[/\\]demo\.env') 'Toolbox replacement has no private config fallback'
foreach ($name in @(
  'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_SEARCH_SERVICE',
  'AZURE_SEARCH_ENDPOINT', 'FOUNDRY_ACCOUNT_NAME', 'FOUNDRY_PROJECT_NAME',
  'FOUNDRY_PROJECT_ENDPOINT', 'FOUNDRY_TOOLBOX_NAME', 'FOUNDRY_KB_NAME',
  'AISEARCH_CONNECTION_NAME'
)) {
  Assert-Boundary ($toolboxAst.Extent.Text.Contains("'$name'")) "Toolbox preflight requires $name"
}
$guardCall = $toolboxAst.Find({ param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-ToolboxReplacement'
}, $true)
$configReadCall = $toolboxAst.Find({ param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Read-EnvironmentConfig'
}, $true)
$environmentPreflightCalls = @($toolboxAst.FindAll({ param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-RequiredEnvironment'
}, $true))
$firstAzureMutation = $toolboxAst.Find({ param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and $node.Extent.Text -match '^az account set'
}, $true)
$firstDelete = $toolboxAst.Find({ param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and $node.Extent.Text -match '^azd ai toolbox delete'
}, $true)
Assert-Boundary ($null -ne $configReadCall -and $environmentPreflightCalls.Count -eq 2 -and $null -ne $firstAzureMutation) 'Config loading and both environment preflight paths are present'
Assert-Boundary ($guardCall.Extent.StartOffset -lt $configReadCall.Extent.StartOffset -and
  @($environmentPreflightCalls | Where-Object { $_.Extent.StartOffset -le $guardCall.Extent.StartOffset }).Count -eq 0) 'Replacement consent is checked before configuration access'
Assert-Boundary (@($environmentPreflightCalls | Where-Object {
  $_.Extent.StartOffset -ge $firstAzureMutation.Extent.StartOffset
}).Count -eq 0) 'Required environment preflight completes before the first Azure mutation'
Assert-Boundary ($guardCall.Extent.StartOffset -lt $firstDelete.Extent.StartOffset) 'Replacement consent is checked before deletion'
& {
  $guard = $toolboxAst.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ToolboxReplacement'
  }, $true)
  . ([scriptblock]::Create($guard.Extent.Text))
  $rejected = $false
  try { Assert-ToolboxReplacement } catch { $rejected = $_.Exception.Message -like 'No toolbox changes made*' }
  Assert-Boundary $rejected 'Unconfirmed replacement fails without mutations'
  Assert-ToolboxReplacement -ReplaceToolbox -WarningAction SilentlyContinue
  Assert-Boundary $true 'Explicit replacement opt-in is accepted'
}

& {
  $roleFunction = $kbAst.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-KnowledgeSourceRole'
  }, $true)
  . ([scriptblock]::Create($roleFunction.Extent.Text))
  $originalExit = $global:LASTEXITCODE
  $mockExit = 0
  $scope = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/test'
  $roleGuid = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  $grant = @{ principalId = 'search-mi'; principalType = 'ServicePrincipal'; scope = $scope; roleDefinitionId = "/subscriptions/test/providers/Microsoft.Authorization/roleDefinitions/$roleGuid"; condition = $null }
  $mockJson = ConvertTo-Json -InputObject @($grant)
  function az {
    if (($args -join ' ') -notmatch '^role assignment list ') { throw 'Unexpected command in offline mock' }
    $global:LASTEXITCODE = $mockExit
    return $mockJson
  }
  try {
    Assert-KnowledgeSourceRole -PrincipalId 'search-mi' -Scope $scope -RoleDefinitionGuid $roleGuid
    Assert-Boundary $true 'Exact existing managed-identity grant is accepted'
    foreach ($failure in @('scope', 'principal', 'role', 'condition', 'missing', 'authorization')) {
      $candidate = $grant.Clone()
      $mockExit = 0
      switch ($failure) {
        scope { $candidate.scope = '/subscriptions/test' }
        principal { $candidate.principalId = 'other-mi' }
        role { $candidate.roleDefinitionId = '/roleDefinitions/wrong-role' }
        condition { $candidate.condition = 'restricted' }
        authorization { $mockExit = 1 }
      }
      $mockJson = ConvertTo-Json -InputObject @($candidate)
      if ($failure -eq 'missing') { $mockJson = '[]' }
      $message = ''
      try { Assert-KnowledgeSourceRole -PrincipalId 'search-mi' -Scope $scope -RoleDefinitionGuid $roleGuid } catch { $message = $_.Exception.Message }
      Assert-Boundary (-not [string]::IsNullOrEmpty($message)) "RBAC rejects $failure"
      if ($failure -eq 'authorization') {
        Assert-Boundary ($message -like 'Cannot read*' -and $message -notlike '*Missing*') 'Authorization failure is not reported as absent RBAC'
      }
    }
  } finally { $global:LASTEXITCODE = $originalExit }
}

foreach ($retained in @('setup/03d-add-sharepoint-source.ps1', 'setup/07b-enable-trimming.ps1')) {
  Assert-Boundary (Test-Path (Join-Path $repoRoot "scripts/$retained")) "Retained tenant/SharePoint owner exists: $retained"
}
foreach ($retired in @('05p-grant-search-mi-graph.ps1', '06a-grant-sp-user-read-all.ps1')) {
  $copies = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Recurse -File -Filter $retired)
  Assert-Boundary ($copies.Count -eq 0) "Native-owned tenant grant script is retired from every category: $retired"
}

$quickstartFiles = @(
  'quickstart/Quickstart.Common.psm1'
  'quickstart/PrivateStorage.psm1'
  'quickstart/deploy.ps1'
  'quickstart/verify.ps1'
  'quickstart/cleanup.ps1'
)
$quickstartText = @{}
foreach ($file in $quickstartFiles) {
  $path = Join-Path $repoRoot "scripts/$file"
  Assert-Boundary (Test-Path -LiteralPath $path -PathType Leaf) "Quickstart operator file exists: $file"
  $parseErrors = $null
  $tokens = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
  Assert-Boundary ($parseErrors.Count -eq 0) "Quickstart operator file parses: $file"
  $quickstartText[$file] = Get-Content -LiteralPath $path -Raw
}

$combinedQuickstart = $quickstartText.Values -join [Environment]::NewLine
foreach ($payloadToken in @(
  '#Microsoft.Skills.Text.SplitSkill',
  'indexProjections',
  'vectorSearchProfile',
  'knowledgeSources =',
  'retrievalReasoningEffort =',
  "api-version=2024-09-01-preview",
  "api-version=2026-08-01-preview"
)) {
  Assert-Boundary (-not $combinedQuickstart.Contains($payloadToken)) "PowerShell does not duplicate Bicep payload token: $payloadToken"
}
Assert-Boundary ($quickstartText['quickstart/Quickstart.Common.psm1'] -match '\$operation\.body' -and
  $quickstartText['quickstart/Quickstart.Common.psm1'].Contains('ConvertTo-Json -Depth 100 -Compress')) 'PowerShell transports the emitted body without reconstructing it'
Assert-Boundary ($quickstartText['quickstart/Quickstart.Common.psm1'] -notmatch "'Invoke-QuickstartHttp'") 'Raw HTTP transport is not exported to arbitrary callers'
Assert-Boundary ($combinedQuickstart -notmatch '\[bool\]\$check\.isReadOnly') 'Quickstart authorization never trusts a mutable isReadOnly flag'

$deploy = $quickstartText['quickstart/deploy.ps1']
$whatIfGuard = $deploy.IndexOf('if ($WhatIf)')
Assert-Boundary ($whatIfGuard -gt $deploy.IndexOf('deployment sub what-if')) 'What-if guard follows the read-only ARM what-if'
Assert-Boundary ($deploy.IndexOf('deployment sub validate') -gt $deploy.IndexOf('deployment sub what-if') -and $whatIfGuard -gt $deploy.IndexOf('deployment sub validate')) 'What-if mode performs read-only nested deployment validation before exiting'
Assert-Boundary ($deploy.Contains('Refusing adoption') -and $deploy.Contains('Assert-QuickstartContractBinding')) 'Existing groups require a prior local contract bound to canonical deployment output'
Assert-Boundary ($deploy -notmatch '(?im)^\s*\[string\]\$ResourceGroupName\b' -and $deploy.Contains('$ResourceGroupName = "rg-$Environment-$DeploymentId"')) 'Deployment resource-group name is deterministic and not caller controlled'
Assert-Boundary ($deploy.Contains("[ValidateSet('P1v3')]") -and $deploy.Contains('"functionPlanSku=$FunctionPlanSku"')) 'Deployment requires and forwards the VNet-capable Function plan SKU'
Assert-Boundary ($deploy.Contains('[int]$EmbeddingCapacity = 50') -and $deploy.Contains('"embeddingCapacity=$EmbeddingCapacity"')) 'Deployment uses and forwards the validated 50K TPM embedding default'
Assert-Boundary ($deploy.Contains('"functionAuthClientId=$FunctionAuthClientId"') -and $deploy.Contains('"functionAuthAudience=$FunctionAuthAudience"') -and $deploy.Contains('FunctionAuthAudience must exactly equal api://<FunctionAuthClientId>.')) 'Deployment requires a matching Function API app registration and audience'
Assert-Boundary ($deploy.Contains('2> $deploymentErrorPath') -and $deploy -notmatch '--output json 2>&1') 'Deployment keeps Azure CLI warnings out of the JSON contract stream'
Assert-Boundary ($deploy.Contains('-BuildPythonFunctionPackage') -and $deploy -notmatch '\bCompress-Archive\b') 'Function package dependencies are built in the private Linux upload job instead of the operator environment'
$packageUploadPosition = $deploy.IndexOf("-UploadName 'function-package'")
$zipDeployPosition = $deploy.IndexOf('functionapp deployment source config-zip')
$functionRestartPosition = $deploy.IndexOf('functionapp restart')
$triggerSyncPosition = $deploy.IndexOf('syncfunctiontriggers')
Assert-Boundary ($deploy.Contains('[IO.Compression.ZipFile]::CreateFromDirectory') -and $deploy.Contains('--build-remote false') -and $deploy.Contains('Remove-Item -LiteralPath $functionStagePath, $functionZipPath')) 'Function ZIP extraction uses the reviewed source allowlist and removes local staging'
Assert-Boundary ($packageUploadPosition -gt $whatIfGuard -and $zipDeployPosition -gt $packageUploadPosition -and $functionRestartPosition -gt $zipDeployPosition -and $triggerSyncPosition -gt $functionRestartPosition) 'Deployment extracts the Function ZIP, restarts the Function, and synchronizes triggers after private package archival'
foreach ($writeToken in @('deployment sub create', 'Approve-QuickstartStoragePrivateLink', 'Invoke-QuickstartPrivateBlobUpload', 'Invoke-QuickstartOperations')) {
  Assert-Boundary ($deploy.IndexOf($writeToken) -gt $whatIfGuard) "What-if exits before write token: $writeToken"
}
$privateStorage = $quickstartText['quickstart/PrivateStorage.psm1']
Assert-Boundary ($privateStorage -match 'private-endpoint-connection approve' -and $privateStorage -match 'requestMessage' -and $privateStorage -match 'storageAccountId') 'Search approval is constrained to the emitted Storage request identity'
Assert-Boundary ($privateStorage -match 'az container create' -and $privateStorage -match 'az container delete' -and $privateStorage -match 'userAssignedIdentities') 'Private uploads use a managed-identity ACI and delete it after execution'
Assert-Boundary ($privateStorage -match 'BuildPythonFunctionPackage' -and $privateStorage -match 'tdnf install -y python3-pip' -and $privateStorage -match 'python3 -m pip install' -and $privateStorage -match 'function_app\.app\.get_functions\(\)' -and $privateStorage -match '/data/package/\.python_packages/lib/site-packages' -and $privateStorage -match 'zipfile\.ZipFile') 'Private Function package build bootstraps pip, validates trigger discovery, and vendors binary Python dependencies into the Azure Functions package layout'
Assert-Boundary ($privateStorage -notmatch '(?i)\b(sas|account[-_]?key|connectionstring|listkeys)\b') 'Private upload path does not use keys, SAS, or connection strings'
Assert-Boundary ($privateStorage -match 'secureValue:\s*\$payload' -and $privateStorage -match 'Remove-Item -LiteralPath \$stageRoot, \$archivePath, \$yamlPath') 'Private upload payload is secret-valued and local staging is removed'

$verify = $quickstartText['quickstart/verify.ps1']
Assert-Boundary ($verify -notmatch '(?i)\b(PUT|PATCH|DELETE)\b|deployment\s+sub\s+create|group\s+delete|storage\s+blob\s+upload') 'Verification contains no write method or provisioning command'

$cleanup = $quickstartText['quickstart/cleanup.ps1']
Assert-Boundary ($cleanup -notmatch '(?i)\[switch\]\s*\$Force\b|--force\b|delete\s+.*--no-wait') 'Cleanup has no force bypass or detached deletion'
$bindingPosition = $cleanup.IndexOf('Assert-QuickstartContractBinding')
$ownershipPosition = $cleanup.IndexOf('Assert-QuickstartOwnership')
$deletePosition = $cleanup.IndexOf('az group delete')
Assert-Boundary ($bindingPosition -ge 0 -and $ownershipPosition -gt $bindingPosition -and $deletePosition -gt $ownershipPosition) 'Cleanup binds the complete deployment output and proves ownership before whole-RG deletion'
Assert-Boundary ($cleanup.Contains('$ConfirmResourceGroupName -cne $ResourceGroupName') -and $cleanup.Contains('-not $ConfirmDeletion')) 'Cleanup requires exact destructive confirmation'

Write-Host "$passed checks passed; no operational scripts or Azure commands executed."