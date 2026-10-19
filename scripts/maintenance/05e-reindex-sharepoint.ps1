#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Step 5 — reset the SharePoint indexer so it re-crawls every doc and captures
  the freshly-granted per-folder ACLs, then poll until it finishes.
#>
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}
$t = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
$h = @{ Authorization = "Bearer $t"; 'Content-Type' = 'application/json' }
$svc = "https://$env:AZURE_SEARCH_SERVICE.search.windows.net"
$api = 'api-version=2026-04-01'
$ixr = 'demofs-sharepoint-source-indexer'

Write-Host "→ resetting indexer $ixr" -ForegroundColor Cyan
Invoke-RestMethod -Method POST -Uri "$svc/indexers/$ixr/reset?$api" -Headers $h | Out-Null
Write-Host "  reset ok"

Write-Host "→ running indexer" -ForegroundColor Cyan
Invoke-RestMethod -Method POST -Uri "$svc/indexers/$ixr/run?$api" -Headers $h | Out-Null
Write-Host "  run submitted"

Write-Host "→ polling (up to 5 min)" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(5)
$last = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $s = Invoke-RestMethod -Uri "$svc/indexers/$ixr/status?$api" -Headers $h
    $lr = $s.lastResult
    $cur = "$($lr.status) processed=$($lr.itemsProcessed) failed=$($lr.itemsFailed)"
    if ($cur -ne $last) { Write-Host "  [$((Get-Date).ToString('HH:mm:ss'))] $cur"; $last = $cur }
    if ($lr.status -in @('success', 'transientFailure', 'persistentFailure')) { break }
}
$final = Invoke-RestMethod -Uri "$svc/indexers/$ixr/status?$api" -Headers $h
Write-Host "`n=== final indexer status ===" -ForegroundColor Cyan
Write-Host "  status:           $($final.lastResult.status)"
Write-Host "  itemsProcessed:   $($final.lastResult.itemsProcessed)"
Write-Host "  itemsFailed:      $($final.lastResult.itemsFailed)"
Write-Host "  startTime:        $($final.lastResult.startTime)"
Write-Host "  endTime:          $($final.lastResult.endTime)"
if ($final.lastResult.errors.Count -gt 0) {
    $final.lastResult.errors | Select-Object -First 5 | ForEach-Object { Write-Host "  ERR: $($_.errorMessage)" -ForegroundColor Red }
}

Write-Host "`n→ SP index doc count" -ForegroundColor Cyan
$stats = Invoke-RestMethod -Uri "$svc/indexes/demofs-sharepoint-source-index/stats?$api" -Headers $h
Write-Host "  documents: $($stats.documentCount)"
