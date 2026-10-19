#requires -Version 7.4
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ContractPath,
  [Parameter(Mandatory)]
  [string]$SubscriptionId,
  [Parameter(Mandatory)]
  [string]$ConfirmResourceGroupName,
  [switch]$ConfirmDeletion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Quickstart.Common.psm1') -Force

$contract = Read-QuickstartContract -Path $ContractPath
$canonicalContract = Get-QuickstartDeploymentContract `
  -SubscriptionId $SubscriptionId `
  -DeploymentName ([string]$contract.cleanup.deploymentName)
Assert-QuickstartContractBinding -LocalContract $contract -DeploymentContract $canonicalContract | Out-Null

$ResourceGroupName = [string]$contract.cleanup.resourceGroupName
if ([string]$contract.cleanup.expectedSubscriptionId -cne $SubscriptionId) {
  throw 'Cleanup subscription does not match the immutable contract.'
}
if ($ConfirmResourceGroupName -cne $ResourceGroupName -or -not $ConfirmDeletion) {
  throw 'Cleanup requires exact resource-group confirmation and ConfirmDeletion.'
}

$group = Invoke-QuickstartAzJson -Arguments @(
  'group', 'show',
  '--subscription', $SubscriptionId,
  '--name', $ResourceGroupName,
  '--output', 'json'
) -Phase 'Cleanup resource group read'
Assert-QuickstartOwnership -Contract $contract -ResourceGroup $group | Out-Null

Write-Host "Deleting the complete quickstart-owned resource group: $($contract.cleanup.resourceGroupId)"
& az group delete `
  --subscription $SubscriptionId `
  --name $ResourceGroupName `
  --yes `
  --output none
if ($LASTEXITCODE -ne 0) {
  throw 'Resource group deletion failed.'
}
Write-Host "Deleted quickstart resource group '$ResourceGroupName'."
