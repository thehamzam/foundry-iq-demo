#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Contract')]
param(
  [Parameter(Mandatory, ParameterSetName = 'Contract')]
  [string]$ContractPath,
  [Parameter(Mandatory, ParameterSetName = 'Deployment')]
  [string]$SubscriptionId,
  [Parameter(Mandatory, ParameterSetName = 'Deployment')]
  [string]$DeploymentName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Quickstart.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PrivateStorage.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'Deployment') {
  $contract = Get-QuickstartDeploymentContract -SubscriptionId $SubscriptionId -DeploymentName $DeploymentName
} else {
  $localContract = Read-QuickstartContract -Path $ContractPath
  $SubscriptionId = [string]$localContract.deployment.subscriptionId
  $contract = Get-QuickstartDeploymentContract `
    -SubscriptionId $SubscriptionId `
    -DeploymentName ([string]$localContract.deployment.deploymentName)
  Assert-QuickstartContractBinding -LocalContract $localContract -DeploymentContract $contract | Out-Null
}

$group = Invoke-QuickstartAzJson -Arguments @(
  'group', 'show',
  '--subscription', $SubscriptionId,
  '--name', [string]$contract.deployment.resourceGroupName,
  '--output', 'json'
) -Phase 'Resource group ownership verification'
Assert-QuickstartOwnership -Contract $contract -ResourceGroup $group | Out-Null
Test-QuickstartPrivateStorage -Contract $contract -SubscriptionId $SubscriptionId

$resourceIds = [ordered]@{
  search = $contract.resources.search.id
  foundry = $contract.resources.foundry.accountId
  project = $contract.resources.foundry.projectId
  corpus = $contract.resources.corpus.storageAccountId
  package = $contract.resources.package.storageAccountId
  function = $contract.resources.function.id
  logAnalytics = $contract.resources.observability.logAnalyticsId
  applicationInsights = $contract.resources.observability.applicationInsightsId
}
$observed = @{}
foreach ($entry in $resourceIds.GetEnumerator()) {
  $observed[$entry.Key] = Invoke-QuickstartAzJson -Arguments @(
    'resource', 'show',
    '--subscription', $SubscriptionId,
    '--ids', [string]$entry.Value,
    '--output', 'json'
  ) -Phase "Control-plane verification for $($entry.Value)"
  $actualLocation = ([string]$observed[$entry.Key].location).Replace(' ', '').ToLowerInvariant()
  $expectedLocation = ([string]$contract.deployment.location).Replace(' ', '').ToLowerInvariant()
  if ($actualLocation -cne $expectedLocation) {
    throw "Resource '$($entry.Key)' is outside the contract location."
  }
}
if ([string]$observed.search.identity.type -notmatch 'SystemAssigned' -or
    [bool]$observed.search.properties.disableLocalAuth -ne $true) {
  throw 'Search identity or local-auth configuration drifted.'
}
if ([string]$observed.foundry.identity.type -notmatch 'SystemAssigned' -or
    [bool]$observed.foundry.properties.disableLocalAuth -ne $true) {
  throw 'Foundry identity or local-auth configuration drifted.'
}
foreach ($name in @('corpus', 'package')) {
  if ([bool]$observed[$name].properties.allowSharedKeyAccess -ne $false -or
      [bool]$observed[$name].properties.allowBlobPublicAccess -ne $false -or
      [string]$observed[$name].properties.publicNetworkAccess -cne 'Disabled' -or
      [string]$observed[$name].properties.minimumTlsVersion -cne 'TLS1_2') {
    throw "Storage security configuration drifted for '$name'."
  }
}
if ([string]$observed.function.identity.type -notmatch 'SystemAssigned' -or
    [bool]$observed.function.properties.httpsOnly -ne $true) {
  throw 'Function identity or HTTPS-only configuration drifted.'
}
if ([bool]$observed.applicationInsights.properties.DisableLocalAuth -ne $true) {
  throw 'Application Insights local authentication is enabled.'
}
foreach ($diagnosticSettingId in @($contract.resources.observability.diagnosticSettingIds)) {
  $null = Invoke-QuickstartAzJson -Arguments @(
    'resource', 'show',
    '--subscription', $SubscriptionId,
    '--ids', [string]$diagnosticSettingId,
    '--output', 'json'
  ) -Phase "Diagnostic setting verification for $diagnosticSettingId"
}

foreach ($expected in @($contract.resources.security.roleAssignments)) {
  $assignments = @(Invoke-QuickstartAzJson -Arguments @(
    'role', 'assignment', 'list',
    '--subscription', $SubscriptionId,
    '--scope', [string]$expected.scope,
    '--output', 'json'
  ) -Phase "RBAC verification for $($expected.scope)")
  $actual = @($assignments | Where-Object { [string]$_.id -ceq [string]$expected.id })
  if ($actual.Count -ne 1 -or
      [string]$actual[0].scope -cne [string]$expected.scope -or
      [string]$actual[0].principalId -cne [string]$expected.principalId -or
      [string]$actual[0].principalType -cne [string]$expected.principalType -or
      [string]$actual[0].roleDefinitionId -cne [string]$expected.roleDefinitionId) {
    throw "RBAC verification failed for assignment '$($expected.id)'."
  }
}

Invoke-QuickstartDriftVerification -Contract $contract

$results = Invoke-QuickstartVerification -Contract $contract
$results | Format-Table -AutoSize
Write-Host "Verification passed for deployment '$($contract.deployment.deploymentId)'."
