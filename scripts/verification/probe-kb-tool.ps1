#!/usr/bin/env pwsh
# Probe the raw shape of the Foundry KB `knowledge_base_retrieve` MCP tool response
# so we can see whether citations include a clickable source URL (blob URL, SharePoint
# webUrl, etc.) and what field name it lives under.

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)

Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

$searchToken = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
if (-not $searchToken) { throw 'no search token' }

$mcpUrl = "$env:AZURE_SEARCH_ENDPOINT/knowledgebases/$env:FOUNDRY_KB_NAME/mcp?api-version=2026-08-01-preview"
Write-Host "MCP URL: $mcpUrl" -ForegroundColor Cyan

# 1) initialize
$initBody = @{
    jsonrpc = '2.0'
    id      = 1
    method  = 'initialize'
    params  = @{
        protocolVersion = '2025-11-25'
        capabilities    = @{}
        clientInfo      = @{ name = 'probe'; version = '0.1' }
    }
} | ConvertTo-Json -Depth 10 -Compress

$headers = @{
    Authorization  = "Bearer $searchToken"
    'Content-Type' = 'application/json'
    Accept         = 'application/json, text/event-stream'
}

$initResp = Invoke-WebRequest -Method POST -Uri $mcpUrl -Headers $headers -Body $initBody -TimeoutSec 60
$sessionId = $initResp.Headers['mcp-session-id']
if (-not $sessionId) { $sessionId = $initResp.Headers['Mcp-Session-Id'] }
Write-Host "session=$sessionId" -ForegroundColor DarkGray

$headers['mcp-session-id'] = "$sessionId"

# 2) initialized notification
$notifyBody = @{ jsonrpc = '2.0'; method = 'notifications/initialized' } | ConvertTo-Json -Compress
Invoke-WebRequest -Method POST -Uri $mcpUrl -Headers $headers -Body $notifyBody -TimeoutSec 30 | Out-Null

# 3) call the retrieve tool
$callBody = @{
    jsonrpc = '2.0'
    id      = 2
    method  = 'tools/call'
    params  = @{
        name      = 'knowledge_base_retrieve'
        arguments = @{
            query_variants = @('DemoFS dispute policy', 'duplicate charge procedure', 'frontline representative dispute intake runbook', 'SharePoint policy')
            messages       = @(@{ role = 'user'; content = 'What are DemoFS''s frontline dispute intake policies and procedures for a duplicate charge?' })
        }
    }
} | ConvertTo-Json -Depth 10 -Compress

$callResp = Invoke-WebRequest -Method POST -Uri $mcpUrl -Headers $headers -Body $callBody -TimeoutSec 120
Write-Host "`n===== RAW KB TOOL RESPONSE =====" -ForegroundColor Green
$body = $callResp.Content
# SSE-wrap prefix: strip "event: message\ndata: " if present
if ($body -match '(?s)^event: [^\n]+\r?\ndata: (.+)$') { $body = $matches[1] }
$parsed = $body | ConvertFrom-Json
$parsed | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 tmp-kb-raw.json
Write-Host "Wrote tmp-kb-raw.json ($((Get-Item tmp-kb-raw.json).Length) bytes)"
foreach ($blk in $parsed.result.content) {
    if ($blk.type -ne 'text') { continue }
    $t = $blk.text
    if ($t.StartsWith('{')) {
        try {
            $ref = $t | ConvertFrom-Json
            Write-Host "`n--- REFERENCE ref_id=$($ref.ref_id) ---" -ForegroundColor Yellow
            Write-Host "uri:      $($ref.uri)"
            Write-Host "mimeType: $($ref.mimeType)"
            if ($ref.sourceData) {
                Write-Host "sourceData keys: $(($ref.sourceData.PSObject.Properties.Name) -join ', ')"
                foreach ($p in $ref.sourceData.PSObject.Properties) {
                    if ($p.Name -in @('uid', 'chunk', 'content')) { continue }
                    $v = "$($p.Value)"
                    if ($v.Length -gt 200) { $v = $v.Substring(0, 200) + '…' }
                    Write-Host "  $($p.Name) = $v"
                }
            }
        } catch { Write-Host "(couldn't parse as JSON)" }
    } else {
        Write-Host "`n--- ANSWER TEXT ---" -ForegroundColor Cyan
        Write-Host $t.Substring(0, [Math]::Min(600, $t.Length))
    }
}
Write-Host "================================" -ForegroundColor Green
