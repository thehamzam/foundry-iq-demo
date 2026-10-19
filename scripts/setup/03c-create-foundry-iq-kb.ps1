#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Provisions the Foundry IQ (Azure AI Search) blob knowledge source + knowledge base
  that powers agentic retrieval for the hosted Foundry agent and local agent.

.DESCRIPTION
  Idempotent — safe to re-run. Creates:
    - Validates Bicep-owned Search MI model and storage access (no RBAC writes).
    - Azure Blob knowledge source pointed at the private storage account.
      Uses connectionString="ResourceId=<arm-id>" so the search service
      authenticates via its system-assigned MI + the resource instance rule
      managed by Bicep. Auto-refresh every 5 minutes (PT5M).
    - Knowledge base referencing the blob source. Uses 2026-08-01-preview
      to enable answer synthesis, query planning, and low-reasoning retrieval.
    - Waits for first ingestion pass, then runs a smoke-test retrieve.

.EXAMPLE
  ./scripts/setup/03c-create-foundry-iq-kb.ps1
#>

[CmdletBinding()]
param()

function Merge-KnowledgeBaseBlobSource {
  param([hashtable]$Existing, [hashtable]$Initial, [string]$BlobSourceName)
  if (-not $Existing) { return $Initial }
  if (-not $Existing.ContainsKey('knowledgeSources')) {
    throw 'Existing knowledge base has no readable knowledgeSources; refusing to replace it.'
  }
  $sources = @($Existing.knowledgeSources)
  if (-not ($sources | Where-Object { $_.name -eq $BlobSourceName })) {
    $Existing.knowledgeSources = @($sources) + @($Initial.knowledgeSources | Where-Object { $_.name -eq $BlobSourceName })
  }
  $Existing.Remove('@odata.etag') | Out-Null
  $Existing.Remove('@odata.context') | Out-Null
  return $Existing
}

function Assert-KnowledgeSourceRole {
  param([string]$PrincipalId, [string]$Scope, [string]$RoleDefinitionGuid)
  $assignmentsJson = az role assignment list --scope $Scope --all -o json --only-show-errors
  if ($LASTEXITCODE -ne 0) {
    throw 'Cannot read infrastructure role assignments. Check authorization; no changes were made.'
  }
  $assignments = $assignmentsJson | ConvertFrom-Json
  $matching = @($assignments | Where-Object {
    $_.principalId -eq $PrincipalId -and $_.principalType -eq 'ServicePrincipal' -and
    $_.scope -eq $Scope -and $_.roleDefinitionId.Split('/')[-1] -eq $RoleDefinitionGuid -and
    [string]::IsNullOrEmpty($_.condition)
  })
  if ($matching.Count -eq 0) {
    throw "Missing Bicep-owned role $RoleDefinitionGuid at $Scope. Run the approved Bicep deployment before this operation."
  }
}

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Get-Content "$RepoRoot/config/demo.env" | ForEach-Object {
  if ($_ -match '^\s*#') { return }
  if ($_ -match '^\s*$') { return }
  $key, $value = $_ -split '=', 2
  Set-Item -Path "env:$($key.Trim())" -Value $value.Trim()
}

$searchApiVersion = '2026-08-01-preview'

Write-Host "→ Setting subscription $env:AZURE_SUBSCRIPTION_ID" -ForegroundColor Cyan
az account set --subscription $env:AZURE_SUBSCRIPTION_ID --output none
if ($LASTEXITCODE -ne 0) { throw 'Cannot select the configured subscription.' }

# --- Discover resource IDs ---
$searchId = az search service show `
  --name $env:AZURE_SEARCH_SERVICE `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --query id -o tsv

if ($LASTEXITCODE -ne 0 -or -not $searchId) { throw 'Cannot read Search. Check authorization and run the approved Bicep deployment.' }

$searchMi = az search service show `
  --name $env:AZURE_SEARCH_SERVICE `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --query "identity.principalId" -o tsv

if ($LASTEXITCODE -ne 0 -or -not $searchMi) { throw 'Cannot read Search managed identity. Check authorization and run the approved Bicep deployment.' }

$storageId = az storage account show `
  --name $env:AZURE_STORAGE_ACCOUNT `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --query id -o tsv

if ($LASTEXITCODE -ne 0 -or -not $storageId) { throw 'Cannot read storage. Check authorization and run the approved Bicep deployment.' }

$foundryId = az cognitiveservices account show `
  --name $env:FOUNDRY_ACCOUNT_NAME `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --query id -o tsv

if ($LASTEXITCODE -ne 0 -or -not $foundryId) { throw 'Cannot read Foundry. Check authorization and run the approved Bicep deployment.' }

$resourceRoot = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers"
if ($searchId -ne "$resourceRoot/Microsoft.Search/searchServices/$($env:AZURE_SEARCH_SERVICE)" -or
  $storageId -ne "$resourceRoot/Microsoft.Storage/storageAccounts/$($env:AZURE_STORAGE_ACCOUNT)" -or
  $foundryId -ne "$resourceRoot/Microsoft.CognitiveServices/accounts/$($env:FOUNDRY_ACCOUNT_NAME)") {
  throw 'Infrastructure IDs do not match the configured subscription/resources. Check Bicep prerequisites.'
}

Write-Host "  Search MI:  $searchMi"
Write-Host "  Storage ID: $storageId"
Write-Host "  Foundry ID: $foundryId"

Write-Host 'Validating Bicep-owned Search MI roles' -ForegroundColor Cyan
Assert-KnowledgeSourceRole -PrincipalId $searchMi -Scope $foundryId -RoleDefinitionGuid 'a97b65f3-24c7-4388-baec-2e87135dc908'
Assert-KnowledgeSourceRole -PrincipalId $searchMi -Scope $storageId -RoleDefinitionGuid '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

# --- 2. Get an AAD token for Search REST API (as your signed-in user) ---
$searchToken = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
$headers = @{
  'Authorization' = "Bearer $searchToken"
  'Content-Type'  = 'application/json'
}

# --- 3. Create the blob knowledge source ---
Write-Host "→ Creating blob knowledge source $env:FOUNDRY_KB_BLOB_SOURCE" -ForegroundColor Cyan
$blobKsBody = @{
  name        = $env:FOUNDRY_KB_BLOB_SOURCE
  kind        = 'azureBlob'
  description = 'DemoFS dispute + fraud policies, procedures, and rulebooks (private blob, MI auth)'
  azureBlobParameters = @{
    connectionString = "ResourceId=$storageId"
    containerName    = $env:AZURE_STORAGE_CONTAINER
    ingestionParameters = @{
      embeddingModel = @{
        kind = 'azureOpenAI'
        azureOpenAIParameters = @{
          resourceUri  = $env:AZURE_OPENAI_ENDPOINT
          deploymentId = $env:AZURE_OPENAI_EMBEDDING_DEPLOYMENT
          modelName    = 'text-embedding-3-large'
        }
      }
      chatCompletionModel = @{
        kind = 'azureOpenAI'
        azureOpenAIParameters = @{
          resourceUri  = $env:AZURE_OPENAI_ENDPOINT
          deploymentId = $env:AZURE_OPENAI_CHAT_DEPLOYMENT
          modelName    = 'gpt-4o'
        }
      }
      ingestionSchedule = @{
        interval = $env:FOUNDRY_KB_REFRESH_INTERVAL
      }
      contentExtractionMode = 'minimal'
    }
  }
} | ConvertTo-Json -Depth 10

$blobKsUri = "$env:AZURE_SEARCH_ENDPOINT/knowledgesources('$($env:FOUNDRY_KB_BLOB_SOURCE)')?api-version=$searchApiVersion"
$response = Invoke-WebRequest -Method PUT -Uri $blobKsUri -Headers $headers -Body $blobKsBody -ErrorAction Stop
Write-Host "  $($response.StatusCode) — knowledge source created" -ForegroundColor Green

# --- 4. Reconcile the knowledge base ---
Write-Host "→ Reconciling knowledge base $env:FOUNDRY_KB_NAME" -ForegroundColor Cyan
$initialKb = @{
  name        = $env:FOUNDRY_KB_NAME
  description = 'Synthetic financial-services dispute knowledge base for retrieval evaluation'
  retrievalInstructions = 'Answer only from the synthetic ChunkingLab documents. Prefer PROC-CHUNKLAB for intake drills, RUN-CHUNKLAB for escalation drills, and COMP-CHUNKLAB for synthetic network-rule drills. Cite every source used.'
  answerInstructions    = 'Return the shortest passage that answers the question with a direct citation. Include the source document ID in every answer.'
  outputMode  = 'answerSynthesis'
  retrievalReasoningEffort = @{ kind = 'low' }
  knowledgeSources = @(
    @{
      name             = $env:FOUNDRY_KB_BLOB_SOURCE
      enableFreshness  = $true
      enableImageServing = $false
    }
  )
  models = @(
    @{
      kind = 'azureOpenAI'
      azureOpenAIParameters = @{
        resourceUri  = $env:AZURE_OPENAI_ENDPOINT
        deploymentId = $env:AZURE_OPENAI_CHAT_DEPLOYMENT
        modelName    = 'gpt-4o'
      }
    }
  )
  retrieveDefaults = @{
    maxRuntimeInSeconds   = 30
    maxOutputDocuments    = 5
    maxOutputSizeInTokens = 5000
  }
}

$kbUri = "$env:AZURE_SEARCH_ENDPOINT/knowledgebases('$($env:FOUNDRY_KB_NAME)')?api-version=$searchApiVersion"
$existingKb = $null
$kbHeaders = $headers.Clone()
try {
  $currentKb = Invoke-WebRequest -Method GET -Uri $kbUri -Headers $headers -ErrorAction Stop
  $existingKb = $currentKb.Content | ConvertFrom-Json -AsHashtable
  $etag = @($currentKb.Headers['ETag'])[0]
  if (-not $etag) { $etag = $existingKb['@odata.etag'] }
  if (-not $etag) { throw 'Existing knowledge base has no ETag; refusing an unconditional overwrite.' }
  $kbHeaders['If-Match'] = $etag
} catch {
  if ($_.Exception.Response.StatusCode -ne 404) { throw }
  $kbHeaders['If-None-Match'] = '*'
}
$kbBody = Merge-KnowledgeBaseBlobSource -Existing $existingKb -Initial $initialKb -BlobSourceName $env:FOUNDRY_KB_BLOB_SOURCE |
  ConvertTo-Json -Depth 100
$response = Invoke-WebRequest -Method PUT -Uri $kbUri -Headers $kbHeaders -Body $kbBody -ErrorAction Stop
Write-Host "  $($response.StatusCode) — knowledge base created" -ForegroundColor Green

# --- 5. Wait for first ingestion pass ---
Write-Host "→ Waiting for first ingestion pass (usually ~1-3 min)" -ForegroundColor Cyan
$indexName = "$($env:FOUNDRY_KB_BLOB_SOURCE)-index"
$maxWaitSec = 300
$waited = 0
$docCount = 0
while ($waited -lt $maxWaitSec) {
  Start-Sleep -Seconds 15
  $waited += 15
  try {
    $r = Invoke-WebRequest `
      -Method GET `
      -Uri "$env:AZURE_SEARCH_ENDPOINT/indexes/$indexName/docs/`$count?api-version=2026-04-01" `
      -Headers @{ Authorization = "Bearer $searchToken" } `
      -ErrorAction SilentlyContinue
    $docCount = [int]($r.Content -replace '\D','')
  } catch { $docCount = 0 }
  Write-Host "  ${waited}s — docs in index: $docCount" -ForegroundColor DarkGray
  if ($docCount -gt 0) { break }
}

if ($docCount -eq 0) {
  Write-Host "❌ No documents ingested after ${maxWaitSec}s — check portal (Search → Indexers → status)" -ForegroundColor Red
  exit 1
}
Write-Host "  ✅ $docCount chunks indexed" -ForegroundColor Green

# --- 6. Smoke-test retrieve via knowledge base ---
Write-Host "→ Smoke-test retrieve" -ForegroundColor Cyan
$retrieveBody = @{
  messages = @(
    @{ role = 'user'; content = @(@{ type = 'text'; text = 'What must a cardholder do first if they see a duplicate charge from the same merchant?' }) }
  )
} | ConvertTo-Json -Depth 10
$retrieveUri = "$env:AZURE_SEARCH_ENDPOINT/knowledgebases/$($env:FOUNDRY_KB_NAME)/retrieve?api-version=$searchApiVersion"
try {
  $r = Invoke-WebRequest -Method POST -Uri $retrieveUri -Headers $headers -Body $retrieveBody
  $json = $r.Content | ConvertFrom-Json
  Write-Host ""
  Write-Host "=== Retrieval response ===" -ForegroundColor Cyan
  $json | ConvertTo-Json -Depth 8 | Write-Host
} catch {
  Write-Host "  retrieve failed: $($_.Exception.Message)" -ForegroundColor Yellow
  Write-Host "  (this can happen on first call — try again in a minute)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "✅ Foundry IQ knowledge base ready" -ForegroundColor Green
Write-Host ""
Write-Host "  Blob source:      $env:FOUNDRY_KB_BLOB_SOURCE ($docCount chunks)"
Write-Host "  Knowledge base:   $env:FOUNDRY_KB_NAME"
Write-Host "  Retrieve URL:     $retrieveUri"
Write-Host ""
Write-Host "  Next: rewire the Toolbox to point at the KB (scripts/maintenance/04-rewire-toolbox.ps1 -ReplaceToolbox)" -ForegroundColor Cyan
