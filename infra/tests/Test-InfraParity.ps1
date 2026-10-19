#requires -Version 7.4
[CmdletBinding()]
param(
  [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
  [string]$CompiledTemplatePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Passed = 0

function Assert-Parity {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
  $script:Passed++
  Write-Host "PASS: $Message"
}

. (Join-Path $PSScriptRoot 'Quickstart.TestFixture.ps1')

$main = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\main.bicep') -Raw
$resources = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\resources.bicep') -Raw
$storage = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\storage.bicep') -Raw
$network = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\private-network.bicep') -Raw
$custom = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'infra\custom-search-pipeline.bicep') -Raw

Assert-Parity ($main -notmatch '(?i)\bexisting\b') 'Composition contains no existing-resource adoption declaration'
Assert-Parity ($main -notmatch '(?im)^\s*param\s+(resourceGroupName|networkProfile)\b') 'Composition exposes no adoption or conditional network-profile switch'
Assert-Parity ($resources -match "Microsoft\.Search/searchServices@2025-05-01'\s*=") 'Search service is created by Bicep'
Assert-Parity ($resources -match "Microsoft\.CognitiveServices/accounts/projects@2025-04-01-preview'\s*=") 'Foundry project is created by Bicep'
Assert-Parity ([regex]::Matches($resources, "Microsoft\.CognitiveServices/accounts/deployments@2025-04-01-preview'\s*=").Count -eq 2) 'Both model deployments are created by Bicep'
Assert-Parity ($resources -match "Microsoft\.CognitiveServices/accounts/projects/connections@2025-04-01-preview'\s*=") 'Search connection is created by Bicep'
Assert-Parity ($resources -match "project\.properties\.endpoints\['AI Foundry API'\]" -and $resources -match 'cognitiveServicesUserRoleId') 'Foundry contract emits the modern project endpoint and grants operator data-plane access'
Assert-Parity ($main -match '(?m)^param embeddingCapacity int = 50$') 'Embedding deployment defaults to 50K TPM for the bundled corpus'
Assert-Parity ($storage -match 'allowSharedKeyAccess:\s*false' -and $storage -match 'allowBlobPublicAccess:\s*false' -and $storage -match "publicNetworkAccess:\s*'Disabled'" -and $storage -match "defaultAction:\s*'Deny'") 'Corpus storage is keyless and private-only'
Assert-Parity ([regex]::Matches($network, "'privatelink\.(blob|queue|table|file)\.").Count -eq 4) 'Private DNS covers Blob, Queue, Table, and File storage endpoints'
Assert-Parity ($network -match 'Microsoft\.Network/virtualNetworks@' -and $network -match 'Microsoft\.Network/privateEndpoints@' -and $network -match 'Microsoft\.Network/privateDnsZones@') 'Private network module owns the VNet, private endpoints, and private DNS'
Assert-Parity ($network -match 'Microsoft\.ContainerInstance/containerGroups' -and $network -match 'Microsoft\.Web/serverFarms') 'Upload and Function integration subnets carry the required delegations'
Assert-Parity ($network -match 'Microsoft\.Search/searchServices/sharedPrivateLinkResources@' -and $network -match "groupId:\s*'blob'") 'Search reaches private corpus storage through a Blob shared private link'
Assert-Parity ($custom -match "minTlsVersion:\s*'1.2'" -and $custom -match "(?s)AzureWebJobsStorage__credential'.*?'managedidentity'") 'Function hosting uses managed identity and TLS hardening'
Assert-Parity ($custom -match "alwaysOn:\s*true" -and $custom -match "vnetRouteAllEnabled:\s*true" -and $custom -match 'Microsoft\.Web/sites/networkConfig@') 'Elastic Premium Function uses Always On and regional VNet integration'
Assert-Parity ($custom -match "AzureWebJobsStorage__tableServiceUri" -and $custom -match 'storageTableDataContributorRoleId' -and $custom -match 'resource functionStorageReaderRole') 'Function host storage includes private Table connectivity and management-plane Reader RBAC'
Assert-Parity ($custom -match "SCM_DO_BUILD_DURING_DEPLOYMENT" -and $custom -notmatch 'WEBSITE_RUN_FROM_PACKAGE') 'Function uses extracted ZIP deployment instead of private Blob package mounting'
Assert-Parity ($custom -match "executionEnvironment:\s*'private'") 'Search indexer is pinned to its private execution environment'
Assert-Parity ($custom -match "(?s)excludedPaths:\s*\[\s*'/api/health'\s*\].*?identities:\s*\[\s*searchPrincipalId\s*\]") 'Function authentication exposes only health and permits only Search MI on protected routes'
Assert-Parity ($main -match 'functionStorageName:\s*names\.corpusStorage' -and $custom -match '(?s)resource functionStorageBlobRole.*?scope:\s*functionStorage.*?storageBlobDataOwnerRoleId') 'Function host storage has Blob Data Owner access'
Assert-Parity ($custom -notmatch 'Microsoft\.Resources/deploymentScripts|listKeys|listCredentials') 'Custom Search pipeline has no deployment script or key retrieval'
Assert-Parity ([regex]::Matches($custom, "(?m)^\s+id:\s*'(search|foundry)-").Count -eq 6) 'Bicep emits six ordered data-plane operations'
Assert-Parity ($custom -match "var searchApiVersion = '2024-09-01-preview'" -and $custom -match "var foundryIqApiVersion = '2026-08-01-preview'") 'Bicep owns the pinned data-plane API profile'

if ($CompiledTemplatePath) {
  $template = Get-Content -LiteralPath $CompiledTemplatePath -Raw | ConvertFrom-Json -Depth 100
  Assert-Parity ($template.'$schema' -like '*subscriptionDeploymentTemplate.json#') 'Compiled public entrypoint has subscription scope'
  Assert-Parity ($template.outputs.quickstartContract.type -eq 'object') 'Compiled template emits one object quickstartContract'
  $managed = @(Assert-TestQuickstartCompiledInventory -Template $template)
  Assert-Parity ($managed.Count -gt 0) 'Compiled inventory contains only the supported public-keyless resource topology'
  $types = @($managed | ForEach-Object { $_.type })
  foreach ($requiredType in @(
    'Microsoft.Resources/resourceGroups',
    'Microsoft.Search/searchServices',
    'Microsoft.CognitiveServices/accounts',
    'Microsoft.CognitiveServices/accounts/projects',
    'Microsoft.CognitiveServices/accounts/deployments',
    'Microsoft.CognitiveServices/accounts/projects/connections',
    'Microsoft.OperationalInsights/workspaces',
    'Microsoft.Insights/components',
    'Microsoft.ManagedIdentity/userAssignedIdentities',
    'Microsoft.Network/virtualNetworks',
    'Microsoft.Network/privateEndpoints',
    'Microsoft.Network/privateDnsZones',
    'Microsoft.Storage/storageAccounts',
    'Microsoft.Storage/storageAccounts/blobServices/containers',
    'Microsoft.Web/serverfarms',
    'Microsoft.Web/sites',
    'Microsoft.Web/sites/config',
    'Microsoft.Web/sites/networkConfig',
    'Microsoft.Search/searchServices/sharedPrivateLinkResources',
    'Microsoft.Authorization/roleAssignments'
  )) {
    Assert-Parity ($requiredType -in $types) "Compiled inventory contains $requiredType"
  }
}

Write-Host "$script:Passed infrastructure parity checks passed; no Azure operation occurred."
