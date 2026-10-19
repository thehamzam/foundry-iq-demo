#requires -Version 7.4
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$SubscriptionId,
  [Parameter(Mandatory)]
  [string]$Location,
  [Parameter(Mandatory)]
  [ValidatePattern('^[a-z][a-z0-9-]{2,23}$')]
  [string]$Environment,
  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
  [string]$DeploymentId,
  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9a-fA-F-]{36}$')]
  [string]$OperatorPrincipalId,
  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
  [string]$FunctionAuthClientId,
  [Parameter(Mandatory)]
  [ValidatePattern('^api://[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
  [string]$FunctionAuthAudience,
  [ValidateSet('standard', 'standard2')]
  [string]$SearchSku = 'standard',
  [ValidateSet('P1v3')]
  [string]$FunctionPlanSku = 'P1v3',
  [string]$ChatModelName = 'gpt-4o',
  [Parameter(Mandatory)]
  [string]$ChatModelVersion,
  [ValidateRange(1, 1000)]
  [int]$ChatCapacity = 10,
  [string]$EmbeddingModelName = 'text-embedding-3-large',
  [Parameter(Mandatory)]
  [string]$EmbeddingModelVersion,
  [ValidateRange(1, 1000)]
  [int]$EmbeddingCapacity = 50,
  [hashtable]$Tags = @{},
  [switch]$WhatIf,
  [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'Quickstart.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PrivateStorage.psm1') -Force

$DeploymentId = ([guid]$DeploymentId).ToString('D')
$FunctionAuthClientId = ([guid]$FunctionAuthClientId).ToString('D')
if ($FunctionAuthAudience -cne "api://$FunctionAuthClientId") {
  throw 'FunctionAuthAudience must exactly equal api://<FunctionAuthClientId>.'
}
$ResourceGroupName = "rg-$Environment-$DeploymentId"
$deploymentName = "quickstart-$DeploymentId"
$templatePath = Join-Path $repoRoot 'infra\main.bicep'
$corpusPath = Join-Path $repoRoot 'sample-data\documents'
$customSkillPath = Join-Path $repoRoot 'custom-skill'
$customSkillPackageFiles = @(
  (Join-Path $customSkillPath 'function_app.py')
  (Join-Path $customSkillPath 'policy_enrichment.py')
  (Join-Path $customSkillPath 'host.json')
  (Join-Path $customSkillPath 'requirements.txt')
)
foreach ($path in @($templatePath, $corpusPath, $customSkillPath)) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Required quickstart source was not found: $path"
  }
}
if (@(Get-ChildItem -LiteralPath $corpusPath -File | Where-Object Extension -ne '.md').Count -ne 0) {
  throw 'The sample document directory may contain Markdown files only.'
}

$immutableTags = @{
  'quickstart.owner' = 'financial-services-knowledge-quickstart'
  'quickstart.schemaVersion' = '3.1.0'
  'quickstart.deploymentId' = $DeploymentId
  'quickstart.deploymentName' = $deploymentName
  'quickstart.provenanceId' = '<Bicep-owned>'
  'quickstart.protected' = 'false'
}
foreach ($key in $immutableTags.Keys) {
  if ($Tags.ContainsKey($key)) {
    throw "Tags cannot override immutable ownership key '$key'."
  }
}

$context = Invoke-QuickstartAzJson -Arguments @('account', 'show', '--output', 'json') -Phase 'Azure context validation'
if ([string]$context.id -cne $SubscriptionId) {
  throw 'The active Azure subscription does not match SubscriptionId.'
}

$stateDirectory = Join-Path $repoRoot '.azure'
$contractPath = Join-Path $stateDirectory "quickstart-contract-$DeploymentId.json"
$groupExistsOutput = & az group exists --subscription $SubscriptionId --name $ResourceGroupName --output tsv 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Resource group preflight failed: $(Protect-QuickstartText ($groupExistsOutput -join [Environment]::NewLine))"
}
if (($groupExistsOutput -join '').Trim() -eq 'true') {
  if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    throw 'The deterministic resource group already exists, but no prior local contract proves a supported quickstart rerun. Refusing adoption.'
  }
  $priorContract = Read-QuickstartContract -Path $contractPath
  $canonicalPriorContract = Get-QuickstartDeploymentContract -SubscriptionId $SubscriptionId -DeploymentName $deploymentName
  Assert-QuickstartContractBinding -LocalContract $priorContract -DeploymentContract $canonicalPriorContract | Out-Null
  if ([string]$priorContract.deployment.resourceGroupName -cne $ResourceGroupName) {
    throw 'The prior canonical deployment contract does not own the deterministic resource group.'
  }
  $existingGroup = Invoke-QuickstartAzJson -Arguments @('group', 'show', '--subscription', $SubscriptionId, '--name', $ResourceGroupName, '--output', 'json') -Phase 'Existing resource group ownership validation'
  Assert-QuickstartOwnership -Contract $priorContract -ResourceGroup $existingGroup | Out-Null
} elseif (Test-Path -LiteralPath $contractPath -PathType Leaf) {
  throw 'A stale local contract exists without its canonical resource group. Remove or archive the stale contract before a new deployment.'
}

$parameterArguments = @(
  "location=$Location"
  "environment=$Environment"
  "deploymentId=$DeploymentId"
  "operatorPrincipalId=$OperatorPrincipalId"
  "functionAuthClientId=$FunctionAuthClientId"
  "functionAuthAudience=$FunctionAuthAudience"
  "searchSku=$SearchSku"
  "functionPlanSku=$FunctionPlanSku"
  "chatModelName=$ChatModelName"
  "chatModelVersion=$ChatModelVersion"
  "chatCapacity=$ChatCapacity"
  "embeddingModelName=$EmbeddingModelName"
  "embeddingModelVersion=$EmbeddingModelVersion"
  "embeddingCapacity=$EmbeddingCapacity"
  "tags=$($Tags | ConvertTo-Json -Compress)"
)

& az deployment sub what-if `
  --subscription $SubscriptionId `
  --location $Location `
  --name $deploymentName `
  --template-file $templatePath `
  --parameters @parameterArguments `
  --no-pretty-print
if ($LASTEXITCODE -ne 0) {
  throw 'Subscription deployment what-if failed.'
}

& az deployment sub validate `
  --subscription $SubscriptionId `
  --location $Location `
  --name $deploymentName `
  --template-file $templatePath `
  --parameters @parameterArguments `
  --output none
if ($LASTEXITCODE -ne 0) {
  throw 'Subscription deployment validation failed.'
}
if ($WhatIf) {
  Write-Host 'What-if and validation completed. No resource, package, corpus, or data-plane write was attempted.'
  exit 0
}
if ($NonInteractive) {
  throw 'NonInteractive deployment is not supported without a separately reviewed authorization workflow.'
}

$deploymentErrorPath = [IO.Path]::GetTempFileName()
try {
  $contractJson = & az deployment sub create `
    --subscription $SubscriptionId `
    --location $Location `
    --name $deploymentName `
    --template-file $templatePath `
    --parameters @parameterArguments `
    --query properties.outputs.quickstartContract.value `
    --output json 2> $deploymentErrorPath
  $deploymentExitCode = $LASTEXITCODE
  $deploymentError = Get-Content -LiteralPath $deploymentErrorPath -Raw
} finally {
  Remove-Item -LiteralPath $deploymentErrorPath -Force -ErrorAction SilentlyContinue
}
if ($deploymentExitCode -ne 0) {
  throw "Bicep deployment failed: $(Protect-QuickstartText $deploymentError)"
}
$contract = ($contractJson -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
Test-QuickstartContract -Contract $contract | Out-Null

New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$contract | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $contractPath -Encoding utf8NoBOM

Approve-QuickstartStoragePrivateLink -Contract $contract -SubscriptionId $SubscriptionId
Test-QuickstartPrivateStorage -Contract $contract -SubscriptionId $SubscriptionId

Invoke-QuickstartPrivateBlobUpload `
  -Contract $contract `
  -SubscriptionId $SubscriptionId `
  -UploadName 'function-package' `
  -SourceFiles $customSkillPackageFiles `
  -Destinations @([string]$contract.resources.package.blobName) `
  -ContainerName ([string]$contract.resources.package.containerName) `
  -BuildPythonFunctionPackage

$functionStagePath = Join-Path ([IO.Path]::GetTempPath()) "quickstart-function-$([guid]::NewGuid().ToString('N'))"
$functionZipPath = "$functionStagePath.zip"
try {
  New-Item -ItemType Directory -Path $functionStagePath | Out-Null
  foreach ($sourceFile in $customSkillPackageFiles) {
    Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $functionStagePath ([IO.Path]::GetFileName($sourceFile)))
  }
  [IO.Compression.ZipFile]::CreateFromDirectory(
    $functionStagePath,
    $functionZipPath,
    [IO.Compression.CompressionLevel]::Optimal,
    $false
  )
  & az functionapp deployment source config-zip `
    --subscription $SubscriptionId `
    --resource-group ([string]$contract.resources.function.resourceGroup) `
    --name ([string]$contract.resources.function.name) `
    --src $functionZipPath `
    --build-remote false `
    --timeout 600 `
    --output none `
    --only-show-errors
  if ($LASTEXITCODE -ne 0) {
    throw 'Entra-authenticated Function ZIP extraction failed.'
  }
} finally {
  Remove-Item -LiteralPath $functionStagePath, $functionZipPath -Recurse -Force -ErrorAction SilentlyContinue
}

& az functionapp restart `
  --subscription $SubscriptionId `
  --resource-group ([string]$contract.resources.function.resourceGroup) `
  --name ([string]$contract.resources.function.name) `
  --only-show-errors
if ($LASTEXITCODE -ne 0) {
  throw 'Function restart after private package upload failed.'
}
& az rest `
  --method POST `
  --uri "https://management.azure.com$([string]$contract.resources.function.id)/syncfunctiontriggers?api-version=2023-12-01" `
  --output none `
  --only-show-errors
if ($LASTEXITCODE -ne 0) {
  throw 'Function trigger synchronization after private package upload failed.'
}

$corpusFiles = @(Get-ChildItem -LiteralPath $corpusPath -File -Filter '*.md' | Sort-Object Name)
Invoke-QuickstartPrivateBlobUpload `
  -Contract $contract `
  -SubscriptionId $SubscriptionId `
  -UploadName 'synthetic-corpus' `
  -SourceFiles @($corpusFiles.FullName) `
  -Destinations @($corpusFiles.Name) `
  -ContainerName ([string]$contract.resources.corpus.containerName)

Invoke-QuickstartOperations -Contract $contract
$verification = Invoke-QuickstartVerification -Contract $contract
$verification | Format-Table -AutoSize
Write-Host "Quickstart deployment completed. Contract: $contractPath"
