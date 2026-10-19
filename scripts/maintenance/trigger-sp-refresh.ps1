#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Force the SharePoint knowledge source indexer to run immediately.

  Foundry IQ auto-refreshes every 5 min (PT5M). For the live freshness demo you
  can either (a) live with the wait, which is realistic, or (b) run this to skip
  the wait once the doc has been uploaded to SharePoint.

  Does NOT re-crawl unchanged items — it only fires the delta-detect run.
#>
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

$t = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
$h = @{ Authorization = "Bearer $t" }
$svc = "https://$env:AZURE_SEARCH_SERVICE.search.windows.net"
$api = 'api-version=2026-04-01'
$ixr = 'demofs-sharepoint-source-indexer'

Write-Host "→ POST /run on $ixr" -ForegroundColor Cyan
Invoke-RestMethod -Method POST -Uri "$svc/indexers/$ixr/run?$api" -Headers $h | Out-Null
Write-Host "  submitted"

Write-Host "→ polling for completion" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(3)
$last = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep 10
    $s = Invoke-RestMethod -Uri "$svc/indexers/$ixr/status?$api" -Headers $h
    $cur = "status=$($s.status) lastResult=$($s.lastResult.status) processed=$($s.lastResult.itemsProcessed) failed=$($s.lastResult.itemsFailed)"
    if ($cur -ne $last) { Write-Host "  [$((Get-Date).ToString('HH:mm:ss'))] $cur"; $last = $cur }
    if ($s.status -ne 'running' -and $s.lastResult.itemsProcessed -gt 0) {
        Write-Host "`n  → processed $($s.lastResult.itemsProcessed) items. Re-ask the agent." -ForegroundColor Green
        break
    }
    if ($s.status -ne 'running' -and $s.lastResult.itemsProcessed -eq 0) {
        Write-Host "`n  ⚠ indexer ran but processed 0 items — SP delta hasn't picked up the new file yet." -ForegroundColor Yellow
        Write-Host "  Wait 30s and re-run this script, or wait for the next PT5M cycle."
        break
    }
}
