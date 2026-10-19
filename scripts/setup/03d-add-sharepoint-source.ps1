#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Adds the SharePoint knowledge source to Foundry IQ using SECRETLESS auth
  (federated credential from search-service MI → ingestion app), then wires it
  into the knowledge base as a second retrieval fan-out.

.DESCRIPTION
  Idempotent — safe to re-run. Uses the Microsoft-recommended pattern from
  https://learn.microsoft.com/azure/search/agentic-knowledge-source-how-to-sharepoint-indexed
  and https://learn.microsoft.com/azure/search/search-how-to-index-sharepoint-online.

  Each run:
    - Looks up the search-service system-assigned MI's principal ID + application ID.
    - Adds a federated identity credential (FIC) to sp-demofs-langgraph-agent-local that
      trusts the search MI. No client secret involved.
    - PUTs the SharePoint knowledge source with a secretless connection string
      using FederatedCredentialApplicationId=<search-mi-app-id>.
    - Updates the knowledge base to fan out over blob + SharePoint.
    - Polls ingestion status until first sync completes.
    - Runs a cross-source smoke test.

.EXAMPLE
  ./scripts/setup/03d-add-sharepoint-source.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Get-Content "$RepoRoot/config/demo.env" | ForEach-Object {
  if ($_ -match '^\s*#') { return }
  if ($_ -match '^\s*$') { return }
  $key, $value = $_ -split '=', 2
  Set-Item -Path "env:$($key.Trim())" -Value $value.Trim()
}

$searchApiVersion = '2026-08-01-preview'
$spDisplayName    = $env:LANGGRAPH_AGENT_LOCAL_SP_NAME
$ficName          = 'fic-search-mi-to-sp-ingestion'

Write-Host "→ Setting subscription $env:AZURE_SUBSCRIPTION_ID" -ForegroundColor Cyan
az account set --subscription $env:AZURE_SUBSCRIPTION_ID --output none

# --- 1. Look up the ingestion app (sp-demofs-langgraph-agent-local) ---
Write-Host "→ Locating ingestion app $spDisplayName" -ForegroundColor Cyan
$sp = az ad sp list --display-name $spDisplayName --query "[0].{appId:appId, id:id}" -o json | ConvertFrom-Json
if (-not $sp -or -not $sp.appId) {
  Write-Host "❌ $spDisplayName not found" -ForegroundColor Red
  exit 1
}
Write-Host "  appId: $($sp.appId)"

# --- 2. Look up the Search MI's principal + application IDs ---
Write-Host "→ Looking up Search service MI" -ForegroundColor Cyan
$searchMiPrincipalId = az search service show `
  --name $env:AZURE_SEARCH_SERVICE `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --query "identity.principalId" -o tsv
$searchMi = az ad sp show --id $searchMiPrincipalId --query "{appId:appId}" -o json | ConvertFrom-Json
Write-Host "  MI principal ID: $searchMiPrincipalId"
Write-Host "  MI application ID (for FCA): $($searchMi.appId)"

# --- 3. Add federated identity credential on the ingestion app ---
# Trusts the search MI; the FCA in the KS connection string is validated against this.
Write-Host "→ Adding federated identity credential on $spDisplayName" -ForegroundColor Cyan
$existingFic = az ad app federated-credential list `
  --id $sp.appId `
  --query "[?name=='$ficName']" -o json | ConvertFrom-Json
if ($existingFic.Count -eq 0) {
  $ficBody = @{
    name        = $ficName
    issuer      = "https://login.microsoftonline.com/$env:AZURE_TENANT_ID/v2.0"
    subject     = $searchMiPrincipalId
    audiences   = @('api://AzureADTokenExchange')
    description = 'Trust the srch-demofs-demo system-assigned MI to obtain tokens as this ingestion app'
  } | ConvertTo-Json -Depth 5 -Compress
  $ficBodyFile = Join-Path $env:TEMP 'fic-body.json'
  Set-Content -Path $ficBodyFile -Value $ficBody -Encoding UTF8
  az ad app federated-credential create --id $sp.appId --parameters "@$ficBodyFile" --output none
  Write-Host "  created — waiting 45s for AAD propagation" -ForegroundColor Green
  Start-Sleep -Seconds 45
} else {
  Write-Host "  already present" -ForegroundColor DarkGray
}

# --- 4. Get AAD token for Search REST API ---
$searchToken = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
$headers = @{
  'Authorization' = "Bearer $searchToken"
  'Content-Type'  = 'application/json'
}

# --- 5. Create the SharePoint knowledge source (secretless) ---
Write-Host "→ Creating SharePoint knowledge source $env:FOUNDRY_KB_SHAREPOINT_SOURCE" -ForegroundColor Cyan
$sharePointConnStr = "SharePointOnlineEndpoint=$env:SHAREPOINT_SITE_URL;ApplicationId=$($sp.appId);TenantId=$env:AZURE_TENANT_ID;FederatedCredentialApplicationId=$($searchMi.appId)"

$spKsBody = @{
  name        = $env:FOUNDRY_KB_SHAREPOINT_SOURCE
  kind        = 'indexedSharePoint'
  description = 'DemoFS frontline runbooks, procedures, policies, Reg E + Visa rules (SharePoint collaboration site)'
  indexedSharePointParameters = @{
    connectionString = $sharePointConnStr
    containerName    = 'defaultSiteLibrary'
    ingestionParameters = @{
      networkAccessMode = 'public'
      identity          = $null
      embeddingModel    = @{
        kind = 'azureOpenAI'
        azureOpenAIParameters = @{
          resourceUri  = $env:AZURE_OPENAI_ENDPOINT
          deploymentId = $env:AZURE_OPENAI_EMBEDDING_DEPLOYMENT
          modelName    = 'text-embedding-3-large'
        }
      }
      chatCompletionModel        = $null
      ingestionSchedule          = @{ interval = $env:FOUNDRY_KB_REFRESH_INTERVAL }
      contentExtractionMode      = 'minimal'
      disableImageVerbalization  = $false
      # Ingest SharePoint ACLs so the KB can filter results per calling user at
      # query time. Requires x-ms-query-source-authorization header on retrieve
      # (which the Toolbox forwards when connection auth is user-entra-token).
      ingestionPermissionOptions = @('groupIds')
    }
  }
} | ConvertTo-Json -Depth 10

$spKsUri = "$env:AZURE_SEARCH_ENDPOINT/knowledgesources('$($env:FOUNDRY_KB_SHAREPOINT_SOURCE)')?api-version=$searchApiVersion"
try {
  $response = Invoke-WebRequest -Method PUT -Uri $spKsUri -Headers $headers -Body $spKsBody -ErrorAction Stop
  Write-Host "  $($response.StatusCode) — SharePoint knowledge source created (secretless)" -ForegroundColor Green
} catch {
  Write-Host "❌ SharePoint KS creation failed:" -ForegroundColor Red
  Write-Host $_.Exception.Message
  if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
  exit 1
}

# --- 6. Update the KB to reference both sources ---
Write-Host "→ Updating KB $env:FOUNDRY_KB_NAME to reference both sources" -ForegroundColor Cyan
$kbBody = @{
  name        = $env:FOUNDRY_KB_NAME
  description = 'Synthetic financial-services retrieval evaluation across configured Blob and SharePoint sources'
  retrievalInstructions = 'Answer only from explicitly synthetic evaluation documents. The public Blob sample contains the ChunkingLab procedure, runbook, and network-rule drills. Treat any separately configured SharePoint content as synthetic test data and cite every source used.'
  answerInstructions    = 'Return the shortest passage that answers the question with direct citations. Include the source document ID in every answer. When a case implicates both frontline procedure and confidential guidance, cite both sources.'
  outputMode  = 'answerSynthesis'
  retrievalReasoningEffort = @{ kind = 'low' }
  knowledgeSources = @(
    @{ name = $env:FOUNDRY_KB_BLOB_SOURCE;       enableFreshness = $true; enableImageServing = $false },
    @{
      name                       = $env:FOUNDRY_KB_SHAREPOINT_SOURCE
      enableFreshness            = $true
      enableImageServing         = $false
      includeReferenceSourceData = $true
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
    maxOutputDocuments    = 8
    maxOutputSizeInTokens = 6000
  }
} | ConvertTo-Json -Depth 10

$kbUri = "$env:AZURE_SEARCH_ENDPOINT/knowledgebases('$($env:FOUNDRY_KB_NAME)')?api-version=$searchApiVersion"
$response = Invoke-WebRequest -Method PUT -Uri $kbUri -Headers $headers -Body $kbBody -ErrorAction Stop
Write-Host "  $($response.StatusCode) — KB updated" -ForegroundColor Green

# --- 7. Wait for SharePoint first ingestion via KS status endpoint ---
Write-Host "→ Polling SharePoint ingestion status (up to 7 min)" -ForegroundColor Cyan
$statusUri = "$env:AZURE_SEARCH_ENDPOINT/knowledgesources/$($env:FOUNDRY_KB_SHAREPOINT_SOURCE)/status?api-version=$searchApiVersion"
$maxWaitSec = 420
$waited = 0
$done = $false
while ($waited -lt $maxWaitSec) {
  Start-Sleep -Seconds 20
  $waited += 20
  try {
    $r = Invoke-WebRequest -Method GET -Uri $statusUri -Headers @{ Authorization = "Bearer $searchToken" } -ErrorAction Stop
    $status = $r.Content | ConvertFrom-Json
    $lastState  = $status.lastSynchronizationState
    $curState   = $status.currentSynchronizationState
    $syncStatus = $status.synchronizationStatus
    Write-Host ("  {0}s — status={1} last={2} processed={3} failed={4}" -f `
      $waited, $syncStatus, $lastState.status, $curState.itemUpdatesProcessed, $curState.itemsUpdatesFailed) -ForegroundColor DarkGray
    if ($lastState -and $lastState.endTime -and $lastState.status -in @('success','partialSuccess')) {
      $done = $true
      break
    }
    if ($curState -and $curState.errors) {
      Write-Host "  errors surfaced during current sync:" -ForegroundColor Yellow
      $curState.errors | ForEach-Object { "    $($_.errorMessage)" | Write-Host }
    }
  } catch {
    Write-Host "  ${waited}s — status probe error: $($_.Exception.Message)" -ForegroundColor DarkGray
  }
}

if (-not $done) {
  Write-Host "⚠️ SharePoint ingestion didn't complete inside ${maxWaitSec}s." -ForegroundColor Yellow
  Write-Host "   Blob source is still available — you can proceed to Toolbox rewire" -ForegroundColor Yellow
} else {
  Write-Host "  ✅ SharePoint ingestion completed" -ForegroundColor Green
}

# --- 8. Cross-source smoke test ---
Write-Host "→ Cross-source smoke-test retrieve" -ForegroundColor Cyan
$retrieveBody = @{
  messages = @(
    @{ role = 'user'; content = @(@{ type = 'text'; text = 'A cardholder reports two identical $49.99 grocery charges from the same coastal Florida merchant last night. What should the agent do, and what confidential guidance applies?' }) }
  )
} | ConvertTo-Json -Depth 10
$retrieveUri = "$env:AZURE_SEARCH_ENDPOINT/knowledgebases/$($env:FOUNDRY_KB_NAME)/retrieve?api-version=$searchApiVersion"
try {
  $r = Invoke-WebRequest -Method POST -Uri $retrieveUri -Headers $headers -Body $retrieveBody
  $json = $r.Content | ConvertFrom-Json
  Write-Host ""
  Write-Host "=== Answer ===" -ForegroundColor Cyan
  $json.response[0].content[0].text | Write-Host
  Write-Host ""
  Write-Host "=== Sources cited ===" -ForegroundColor Cyan
  $json.references | ForEach-Object {
    $src = if ($_.blobUrl) { $_.blobUrl } elseif ($_.sharePointUrl) { $_.sharePointUrl } elseif ($_.docKey) { $_.docKey } else { $_.citationUrl }
    "{0,-20} score={1,-8:N2}  {2}" -f $_.type, $_.rerankerScore, $src | Write-Host
  }
} catch {
  Write-Host "  retrieve failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✅ SharePoint source wired in (secretless, MI-backed federated credential)" -ForegroundColor Green
Write-Host ""
Write-Host "  Blob source:        $env:FOUNDRY_KB_BLOB_SOURCE"
Write-Host "  SharePoint source:  $env:FOUNDRY_KB_SHAREPOINT_SOURCE"
Write-Host "  Knowledge base:     $env:FOUNDRY_KB_NAME (fans out to both)"
Write-Host ""
Write-Host "  Next: rewire the Toolbox to point at the KB" -ForegroundColor Cyan
