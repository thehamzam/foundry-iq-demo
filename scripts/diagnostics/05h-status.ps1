#!/usr/bin/env pwsh
# Quick, non-blocking status probe of the SP indexer + KS + index. No mutations.
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}
$t = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
$h = @{ Authorization = "Bearer $t" }
$svc = "https://$env:AZURE_SEARCH_SERVICE.search.windows.net"

Write-Host "=== indexer status ===" -ForegroundColor Cyan
$s = Invoke-RestMethod -Uri "$svc/indexers/demofs-sharepoint-source-indexer/status?api-version=2026-04-01" -Headers $h
Write-Host "  status:               $($s.status)"
Write-Host "  lastResult.status:    $($s.lastResult.status)"
Write-Host "  lastResult.start:     $($s.lastResult.startTime)"
Write-Host "  lastResult.end:       $($s.lastResult.endTime)"
Write-Host "  lastResult.processed: $($s.lastResult.itemsProcessed)"
Write-Host "  lastResult.failed:    $($s.lastResult.itemsFailed)"
if ($s.lastResult.errors) { $s.lastResult.errors | Select-Object -First 3 | ForEach-Object { Write-Host "  ERR: $($_.errorMessage)" -ForegroundColor Red } }

Write-Host "`n=== execution history (last 3) ===" -ForegroundColor Cyan
$s.executionHistory | Select-Object -First 3 | ForEach-Object {
    Write-Host "  [$($_.startTime)] $($_.status) processed=$($_.itemsProcessed) failed=$($_.itemsFailed)"
}

Write-Host "`n=== SP index doc count ===" -ForegroundColor Cyan
$st = Invoke-RestMethod -Uri "$svc/indexes/demofs-sharepoint-source-index/stats?api-version=2026-04-01" -Headers $h
Write-Host "  documents: $($st.documentCount)"
