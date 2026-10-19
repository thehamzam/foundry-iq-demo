#requires -Version 7.4
[CmdletBinding()]
param(
  [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Passed = 0
Import-Module (Join-Path $RepositoryRoot 'scripts\quickstart\Quickstart.Common.psm1') -Force
. (Join-Path $PSScriptRoot 'Quickstart.TestFixture.ps1')

function Assert-Mutation {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
  $script:Passed++
  Write-Host "PASS: $Message"
}

function Assert-Rejected {
  param([scriptblock]$Action, [string]$Expected, [string]$Message)
  $errorMessage = ''
  try {
    & $Action
  } catch {
    $errorMessage = $_.Exception.Message
  }
  Assert-Mutation (-not [string]::IsNullOrWhiteSpace($errorMessage) -and $errorMessage -like "*$Expected*") $Message
}

function Copy-Value($Value) {
  return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
}

$canonical = New-TestQuickstartContract
Assert-Mutation (Test-QuickstartContract -Contract $canonical) 'Canonical mutation fixture is valid'

$compiledFixture = @{
  resources = @(
    @{
      type = 'Microsoft.Resources/resourceGroups'
      name = 'synthetic'
    }
  )
} | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
Assert-Mutation (@(Assert-TestQuickstartCompiledInventory -Template $compiledFixture).Count -eq 1) 'Canonical compiled-inventory fixture is valid'

foreach ($inventoryMutation in @(
    @{
      Type = 'Microsoft.Network/publicIPAddresses'
      Error = 'unsupported orphan resource types'
      Message = 'Public IP resource mutation is rejected semantically'
    }
    @{
      Type = 'Microsoft.Network/networkSecurityGroups'
      Error = 'unsupported orphan resource types'
      Message = 'Unreviewed network security group mutation is rejected semantically'
    }
    @{
      Type = 'Microsoft.Web/sites/privateEndpointConnections'
      Error = 'unsupported orphan resource types'
      Message = 'Function inbound private endpoint mutation is rejected semantically'
    }
    @{
      Type = 'Microsoft.ContainerInstance/containerGroups'
      Error = 'unsupported orphan resource types'
      Message = 'Persistent ACI resource mutation is rejected semantically'
    }
  )) {
  $mutation = Copy-Value $compiledFixture
  $mutation.resources += [pscustomobject]@{
    type = $inventoryMutation.Type
    name = 'mutated'
  }
  Assert-Rejected {
    Assert-TestQuickstartCompiledInventory -Template $mutation
  } $inventoryMutation.Error $inventoryMutation.Message
}

$mutation = Copy-Value $compiledFixture
$mutation.resources[0] | Add-Member -NotePropertyName properties -NotePropertyValue ([pscustomobject]@{
    networkProfile = [pscustomobject]@{ mode = 'private' }
  })
Assert-Rejected {
  Assert-TestQuickstartCompiledInventory -Template $mutation
} 'unsupported networkProfile' 'Unsupported networkProfile mutation is rejected semantically'

$mutation = Copy-Value $canonical
$mutation.deployment.location = 'forged'
Assert-Rejected {
  Assert-QuickstartContractBinding -LocalContract $mutation -DeploymentContract $canonical
} 'does not match the complete canonical' 'Forged persisted local contract is rejected'

$mutation = Copy-Value $canonical
$mutation.resources.function.authClientId = 'not-a-guid'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'client ID must be a canonical GUID' 'Malformed Function authentication client ID is rejected'

$mutation = Copy-Value $canonical
$mutation.resources.function.authAudience = 'api://44444444-4444-4444-4444-444444444444'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'audience must exactly match its client ID' 'Mismatched Function authentication audience is rejected'

$mutation = Copy-Value $canonical
$mutation.resources.function.PSObject.Properties.Remove('authAudience')
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'audience must exactly match its client ID' 'Missing Function authentication audience is rejected'

$legacyHealthContract = Copy-Value $canonical
$legacyHealthContract.verification.checks[0].audience = $legacyHealthContract.resources.function.authAudience
Assert-Mutation (Test-QuickstartContract -Contract $legacyHealthContract) 'Prior authenticated-health contract remains accepted for guarded deployment resume'

$mutation = Copy-Value $canonical
$mutation.verification.checks[0].audience = 'https://management.azure.com/'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'unsupported kind, method, path, host, or audience' 'Function health verification rejects an unrelated token audience'

$mutation = Copy-Value $canonical
$mutation.dataPlane.operations[0].method = 'POST'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'unsupported kind, method, or audience' 'Arbitrary Search provisioning POST is rejected'

$mutation = Copy-Value $canonical
$mutation.dataPlane.operations[0].method = 'DELETE'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'unsupported kind, method, or audience' 'Search document/index deletion is rejected'

$mutation = Copy-Value $canonical
$mutation.dataPlane.operations[0].uri = 'https://owned.search.windows.net/indexes/policy-chunks/docs/index?api-version=2024-09-01-preview'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'unsupported path' 'Search document mutation path is rejected'

$mutation = Copy-Value $canonical
$mutation.dataPlane.operations[0].audience = 'https://management.azure.com/'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'unsupported kind, method, or audience' 'Wrong provisioning audience is rejected'

$mutation = Copy-Value $canonical
$mutation.dataPlane.operations[0].uri = 'https://unowned.example.invalid/indexes/policy-chunks?api-version=2024-09-01-preview'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'outside the owned Search endpoint' 'Wrong provisioning host is rejected'

$mutation = Copy-Value $canonical
$mutation.verification.checks[3].uri = 'https://owned.search.windows.net/indexes/policy-chunks/docs/search?api-version=2026-08-01-preview'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'unsupported path' 'Arbitrary Search verification POST path is rejected'

$mutation = Copy-Value $canonical
$mutation.verification.checks[3].audience = 'https://management.azure.com/'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'unsupported kind, method, response contract, or audience' 'Wrong retrieval audience is rejected'

$mutation = Copy-Value $canonical
$mutation.verification.checks[3].uri = 'https://unowned.example.invalid/knowledgebases/policy-knowledge-base/retrieve?api-version=2026-08-01-preview'
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'outside the owned Search endpoint' 'Wrong retrieval host is rejected'

$mutation = Copy-Value $canonical
$mutation.verification.checks[3].body | Add-Member -NotePropertyName delete -NotePropertyValue $true
Assert-Rejected { Test-QuickstartContract -Contract $mutation } 'unsupported properties' 'Retrieval POST body with mutation intent is rejected'

$group = @{
  id = $canonical.cleanup.resourceGroupId
  name = $canonical.cleanup.resourceGroupName
  tags = Copy-Value $canonical.cleanup.requiredOwnershipTags
} | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
Assert-Mutation (Assert-QuickstartOwnership -Contract $canonical -ResourceGroup $group) 'Exact cleanup ownership and protection evidence is accepted'

$mutation = Copy-Value $group
$mutation.tags.'quickstart.deploymentId' = '33333333-3333-3333-3333-333333333333'
Assert-Rejected { Assert-QuickstartOwnership -Contract $canonical -ResourceGroup $mutation } 'does not match' 'Cleanup deployment tag mismatch is rejected'

$mutation = Copy-Value $group
$mutation.tags.'quickstart.provenanceId' = 'forged-provenance'
Assert-Rejected { Assert-QuickstartOwnership -Contract $canonical -ResourceGroup $mutation } 'does not match' 'Cleanup provenance mismatch is rejected'

$mutation = Copy-Value $group
$mutation.tags.'quickstart.protected' = 'true'
Assert-Rejected { Assert-QuickstartOwnership -Contract $canonical -ResourceGroup $mutation } 'protection tag' 'Cleanup protection is rejected'

$mutation = Copy-Value $group
$mutation.tags.PSObject.Properties.Remove('quickstart.protected')
Assert-Rejected { Assert-QuickstartOwnership -Contract $canonical -ResourceGroup $mutation } 'protection evidence is missing' 'Cleanup with missing protection evidence is rejected'

$indexerCheck = $canonical.verification.checks[1]
Assert-Rejected {
  Assert-QuickstartVerificationResponse -Check $indexerCheck -Body ([pscustomobject]@{
    lastResult = [pscustomobject]@{ status = 'persistentFailure' }
  })
} 'terminal failure' 'Failed indexer state is rejected'

$running = Assert-QuickstartVerificationResponse -Check $indexerCheck -Body ([pscustomobject]@{
  lastResult = [pscustomobject]@{ status = 'inProgress' }
})
Assert-Mutation (-not $running) 'Running indexer remains pending before the bounded final attempt'
Assert-Rejected {
  Assert-QuickstartVerificationResponse -Check $indexerCheck -Body ([pscustomobject]@{
    lastResult = [pscustomobject]@{ status = 'inProgress' }
  }) -FinalAttempt
} 'did not reach terminal success' 'Running indexer at timeout is rejected'

$retrievalCheck = $canonical.verification.checks[3]
Assert-Rejected {
  Assert-QuickstartVerificationResponse -Check $retrievalCheck -Body ([pscustomobject]@{
    response = @()
    references = @([pscustomobject]@{ id = 'source-1' })
  })
} 'no retrieval results' 'Empty retrieval result collection is rejected'

Assert-Rejected {
  Assert-QuickstartVerificationResponse -Check $retrievalCheck -Body ([pscustomobject]@{
    response = @([pscustomobject]@{ content = 'answer' })
    references = @()
  })
} 'no citations' 'Empty citation collection is rejected'

Assert-Rejected {
  Assert-QuickstartVerificationResponse -Check $retrievalCheck -Body ([pscustomobject]@{
    response = @([pscustomobject]@{ content = 'answer' })
    references = @([pscustomobject]@{ title = 'missing-source-id' })
  })
} 'without a source identifier' 'Citation without source identifier is rejected'

Assert-Mutation ($null -eq (Get-Command Invoke-QuickstartHttp -ErrorAction SilentlyContinue)) 'Raw arbitrary HTTP transport is not callable after module import'

Write-Host "$script:Passed quickstart mutation checks passed; no Azure operation occurred."
