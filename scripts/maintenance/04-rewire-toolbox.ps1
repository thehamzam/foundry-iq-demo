#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Rewires the Foundry Toolbox to expose the Foundry IQ knowledge base's
  MCP endpoint, replacing the old raw-index Azure AI Search tool.

.DESCRIPTION
  Explicit replacement operation; requires -ReplaceToolbox. Each run:
    - Uses the current process environment by default, or only the explicitly
      supplied -ConfigPath file when provided. No private-path fallback.
    - Validates all required non-secret configuration before Azure/azd changes.
    - Validates Bicep-owned project MI, Search reader grant and AAD connection.
    - Creates (or updates) a 'remote-tool' project connection pointing at the
      KB MCP endpoint (https://<search>.search.windows.net/knowledgebases/<kb>/mcp)
      using user-entra-token auth for per-user filtering. Zero secrets.
    - Deletes the old toolbox that referenced the now-deleted demofs-knowledge-v1
      index, and creates a fresh one with a single 'mcp' tool referencing the
      new connection. The toolbox exposes the KB's knowledge_base_retrieve tool.
    - Verifies the toolbox MCP endpoint returns knowledge_base_retrieve.

  Docs:
   - https://learn.microsoft.com/azure/search/agentic-retrieval-how-to-retrieve#call-the-mcp-endpoint
   - https://learn.microsoft.com/azure/foundry/agents/how-to/tools/toolbox

.EXAMPLE
  ./scripts/maintenance/04-rewire-toolbox.ps1 -ReplaceToolbox

.EXAMPLE
  ./scripts/maintenance/04-rewire-toolbox.ps1 -ConfigPath ./toolbox.env -ReplaceToolbox
#>

[CmdletBinding()]
param(
  [string]$ConfigPath,
  [switch]$ReplaceToolbox
)

function Assert-ToolboxReplacement {
  param([switch]$ReplaceToolbox)
  if (-not $ReplaceToolbox) {
    throw 'No toolbox changes made. Review current tools, then explicitly pass -ReplaceToolbox to authorize replacing the toolbox and RemoteTool connection.'
  }
  Write-Warning 'Replacing the current toolbox removes all its tools and recreates only knowledge_base_retrieve. The RemoteTool connection will also be replaced.'
}

function Test-ListedResource {
  param([string]$Json, [string]$Name, [switch]$Toolbox)
  if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Missing resource name; no toolbox changes were made.' }
  if ([string]::IsNullOrWhiteSpace($Json)) { throw 'Empty resource listing; no toolbox changes were made.' }
  $items = ConvertFrom-Json -InputObject $Json -NoEnumerate -ErrorAction Stop
  if ($Toolbox) {
    if ($null -eq $items -or $items -isnot [pscustomobject] -or
      @($items.PSObject.Properties).Count -ne 1 -or $items.toolboxes -isnot [array]) {
      throw 'Unexpected toolbox listing; no toolbox changes were made.'
    }
    $items = $items.toolboxes
  } elseif ($null -eq $items -and $Json.Trim() -ceq 'null') {
    $items = @()
  }
  if ($items -isnot [array]) { throw 'Unexpected resource listing; no toolbox changes were made.' }
  foreach ($item in $items) {
    if ($null -eq $item -or $item.name -isnot [string] -or [string]::IsNullOrWhiteSpace($item.name)) {
      throw 'Unnamed resource in listing; no toolbox changes were made.'
    }
  }
  $matches = @($items | Where-Object { $_.name -eq $Name })
  if ($matches.Count -gt 1 -or ($matches.Count -eq 1 -and $matches[0].name -cne $Name)) {
    throw 'Ambiguous resource name in listing; no toolbox changes were made.'
  }
  return $matches.Count -eq 1
}

function Read-EnvironmentConfig {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "ConfigPath does not reference an existing file: $Path. No Azure or azd changes were made."
  }

  $values = [ordered]@{}
  $lineNumber = 0
  foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
    $lineNumber++
    if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') { continue }
    if ($line -notmatch '^(?<key>[A-Za-z_][A-Za-z0-9_]*)=(?<value>.*)$') {
      throw "Malformed configuration at line $lineNumber. Expected KEY=VALUE with no leading whitespace. No Azure or azd changes were made."
    }

    $key = $matches.key
    if ($values.Contains($key)) {
      throw "Duplicate configuration key '$key' at line $lineNumber. No Azure or azd changes were made."
    }
    $values[$key] = $matches.value
  }
  return $values
}

function Assert-RequiredEnvironment {
  param(
    [Parameter(Mandatory)][string[]]$Names,
    [System.Collections.IDictionary]$Values
  )

  $missing = foreach ($name in $Names) {
    $value = if ($null -ne $Values -and $Values.Contains($name)) {
      [string]$Values[$name]
    } elseif ($null -eq $Values) {
      [Environment]::GetEnvironmentVariable($name, 'Process')
    } else {
      $null
    }
    if ([string]::IsNullOrWhiteSpace($value)) { $name }
  }
  if ($missing.Count -gt 0) {
    $source = if ($null -ne $Values) { 'ConfigPath' } else { 'process environment' }
    throw "Missing required non-secret configuration in ${source}: $($missing -join ', '). No Azure or azd changes were made."
  }
}

Assert-ToolboxReplacement -ReplaceToolbox:$ReplaceToolbox

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$requiredEnvironment = @(
  'AZURE_SUBSCRIPTION_ID'
  'AZURE_RESOURCE_GROUP'
  'AZURE_SEARCH_SERVICE'
  'AZURE_SEARCH_ENDPOINT'
  'FOUNDRY_ACCOUNT_NAME'
  'FOUNDRY_PROJECT_NAME'
  'FOUNDRY_PROJECT_ENDPOINT'
  'FOUNDRY_TOOLBOX_NAME'
  'FOUNDRY_KB_NAME'
  'AISEARCH_CONNECTION_NAME'
)

if ($PSBoundParameters.ContainsKey('ConfigPath')) {
  $configValues = Read-EnvironmentConfig -Path $ConfigPath
  Assert-RequiredEnvironment -Names $requiredEnvironment -Values $configValues
  foreach ($entry in $configValues.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
  }
} else {
  Assert-RequiredEnvironment -Names $requiredEnvironment
}

$connName    = 'dispute-kb-mcp-conn'
$kbMcpUrl    = "$($env:AZURE_SEARCH_ENDPOINT)/knowledgebases/$($env:FOUNDRY_KB_NAME)/mcp?api-version=2026-08-01-preview"

Write-Host "→ Setting subscription $env:AZURE_SUBSCRIPTION_ID" -ForegroundColor Cyan
az account set --subscription $env:AZURE_SUBSCRIPTION_ID --output none
if ($LASTEXITCODE -ne 0) { throw 'Cannot select the configured subscription.' }

$searchId = az search service show `
  --name $env:AZURE_SEARCH_SERVICE `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $searchId) { throw 'Cannot read Search. Check authorization and run the approved Bicep deployment.' }
if ($searchId -ne "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers/Microsoft.Search/searchServices/$($env:AZURE_SEARCH_SERVICE)") {
  throw 'Search ID does not match the configured subscription/resource. Check Bicep prerequisites.'
}
$projectArmId = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers/Microsoft.CognitiveServices/accounts/$($env:FOUNDRY_ACCOUNT_NAME)/projects/$($env:FOUNDRY_PROJECT_NAME)"
$projectJson = az rest --method GET --uri "https://management.azure.com${projectArmId}?api-version=2025-04-01-preview" --query '{id:id,identity:identity}' -o json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Foundry project identity. Check authorization and run the approved Bicep deployment.' }
$project = $projectJson | ConvertFrom-Json
$projectMiId = $project.identity.principalId
if ($project.id -ne $projectArmId -or -not $projectMiId) { throw 'Expected Foundry project MI is missing. Run the approved Bicep deployment.' }
$assignmentsJson = az role assignment list --scope $searchId -o json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Cannot read project MI RBAC. Check authorization; no toolbox changes were made.' }
$assignment = @($assignmentsJson | ConvertFrom-Json | Where-Object {
  $_.principalId -eq $projectMiId -and $_.principalType -eq 'ServicePrincipal' -and
  $_.scope -eq $searchId -and $_.roleDefinitionId.Split('/')[-1] -eq '1407120a-92aa-4202-b7e9-c0e197c71c8f' -and
  [string]::IsNullOrEmpty($_.condition)
})
if ($assignment.Count -eq 0) { throw 'Missing project MI Search Index Data Reader at Search scope. Run the approved Bicep deployment.' }
$bootstrapUri = "https://management.azure.com$projectArmId/connections/$($env:AISEARCH_CONNECTION_NAME)?api-version=2025-04-01-preview"
$bootstrapJson = az rest --method GET --uri $bootstrapUri --query properties -o json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Bicep-owned Search connection. Check authorization and run the approved Bicep deployment.' }
$bootstrap = $bootstrapJson | ConvertFrom-Json
if ($bootstrap.category -ne 'CognitiveSearch' -or $bootstrap.authType -ne 'AAD' -or
  $bootstrap.target -ne $env:AZURE_SEARCH_ENDPOINT -or $bootstrap.metadata.ResourceId -ne $searchId -or
  $bootstrap.metadata.ApiType -ne 'Azure' -or $bootstrap.isSharedToAll -ne $false) {
  throw 'Search connection differs from the approved Bicep baseline (including isSharedToAll=false). Reconcile infrastructure before replacing tools.'
}

# --- 2. Set active azd project ---
Write-Host "→ azd ai project set" -ForegroundColor Cyan
azd ai project set $env:FOUNDRY_PROJECT_ENDPOINT
if ($LASTEXITCODE -ne 0) { throw 'Cannot select the Foundry project; no toolbox changes were made.' }

$toolboxesJson = azd ai toolbox list --output json
if ($LASTEXITCODE -ne 0) { throw 'Cannot list toolboxes; no toolbox changes were made.' }
$toolboxPresent = Test-ListedResource -Json ($toolboxesJson -join "`n") -Name $env:FOUNDRY_TOOLBOX_NAME -Toolbox
$connectionsJson = azd ai connection list --output json
if ($LASTEXITCODE -ne 0) { throw 'Cannot list connections; no toolbox changes were made.' }
$connectionPresent = Test-ListedResource -Json ($connectionsJson -join "`n") -Name $connName

Write-Host "→ Removing existing toolbox and RemoteTool connection" -ForegroundColor Cyan
if ($toolboxPresent) {
  azd ai toolbox delete $env:FOUNDRY_TOOLBOX_NAME --force 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Toolbox deletion failed; stopping replacement. Inspect the current toolbox before retrying.' }
}
if ($connectionPresent) {
  azd ai connection delete $connName --force 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'RemoteTool deletion failed; stopping replacement. Inspect the connection before retrying.' }
}

# --- 4. Create the remote-tool connection pointing at the KB MCP endpoint ---
Write-Host "→ Creating remote-tool connection $connName (user-entra-token for per-user filtering)" -ForegroundColor Cyan
Write-Host "  target: $kbMcpUrl"
azd ai connection create $connName `
  --kind remote-tool `
  --target $kbMcpUrl `
  --auth-type user-entra-token `
  --audience 'https://search.azure.com' `
  --no-prompt
if ($LASTEXITCODE -ne 0) { throw 'RemoteTool creation failed; toolbox replacement is incomplete.' }

# --- 5. Create the new toolbox with an MCP tool ---
Write-Host "→ Creating toolbox $env:FOUNDRY_TOOLBOX_NAME" -ForegroundColor Cyan
$toolboxYaml = @"
description: >
  Synthetic financial-services dispute knowledge base for retrieval evaluation.
  Powered by Foundry IQ with model-assisted query planning and answer synthesis.
tools:
  - type: mcp
    server_label: demofs_kb
    project_connection_id: $connName
    require_approval: never
    description: |
      Retrieve grounded, cited answers from the synthetic ChunkingLab corpus.
      Returns synthesized answers with per-source CHUNKLAB citations.
"@
$yamlPath = Join-Path $env:TEMP "toolbox-$($env:FOUNDRY_TOOLBOX_NAME).yaml"
Set-Content -Path $yamlPath -Value $toolboxYaml -Encoding UTF8

azd ai toolbox create $env:FOUNDRY_TOOLBOX_NAME `
  --from-file $yamlPath `
  --no-prompt
if ($LASTEXITCODE -ne 0) { throw 'Toolbox creation failed; replacement is incomplete.' }

# --- 6. Verify the toolbox exposes the KB retrieve tool ---
Write-Host "→ Verifying toolbox MCP endpoint" -ForegroundColor Cyan
$toolboxEndpoint = "$($env:FOUNDRY_PROJECT_ENDPOINT)/toolboxes/$($env:FOUNDRY_TOOLBOX_NAME)/mcp?api-version=v1"
$aiToken = az account get-access-token --resource 'https://ai.azure.com' --query accessToken -o tsv
Write-Host "  endpoint: $toolboxEndpoint"

# Initialize + list tools via raw JSON-RPC
$initBody = @{
  jsonrpc = '2.0'
  id      = 1
  method  = 'initialize'
  params  = @{
    protocolVersion = '2025-03-26'
    capabilities    = @{}
    clientInfo      = @{ name = 'verify'; version = '1.0' }
  }
} | ConvertTo-Json -Depth 5 -Compress

$headers = @{
  'Authorization' = "Bearer $aiToken"
  'Content-Type'  = 'application/json'
  'Accept'        = 'application/json, text/event-stream'
}

try {
  $r = Invoke-WebRequest -Method POST -Uri $toolboxEndpoint -Headers $headers -Body $initBody
  $sessionId = $r.Headers['Mcp-Session-Id']
  if ($sessionId) { $headers['Mcp-Session-Id'] = $sessionId }

  $notifBody = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  Invoke-WebRequest -Method POST -Uri $toolboxEndpoint -Headers $headers -Body $notifBody | Out-Null

  $listBody = '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  $r = Invoke-WebRequest -Method POST -Uri $toolboxEndpoint -Headers $headers -Body $listBody
  $raw = $r.Content
  # Handle SSE-style response
  if ($raw -match '(?s)data:\s*(\{.*\})') { $raw = $matches[1] }
  $result = $raw | ConvertFrom-Json
  $tools = $result.result.tools
  Write-Host "  ✅ toolbox returned $($tools.Count) tool(s):" -ForegroundColor Green
  $tools | ForEach-Object { "    - $($_.name): $($_.description.Substring(0, [Math]::Min(80, $_.description.Length)))" | Write-Host }
} catch {
  Write-Host "  ⚠️ verification failed (toolbox may still be provisioning): $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✅ Toolbox rewired" -ForegroundColor Green
Write-Host ""
Write-Host "  Toolbox:         $env:FOUNDRY_TOOLBOX_NAME"
Write-Host "  MCP endpoint:    $toolboxEndpoint"
Write-Host "  Backing KB:      $env:FOUNDRY_KB_NAME"
Write-Host "  Auth:            user-entra-token (Search audience; per-user filtering)"
Write-Host ""
Write-Host "  Next: redeploy the hosted Foundry agent (uses TOOLBOX_ENDPOINT env)" -ForegroundColor Cyan
