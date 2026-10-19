#!/usr/bin/env pwsh
# Inspect the state of Foundry IQ knowledge sources, the KB, the underlying search
# index, and any indexers so we can tell whether SharePoint content is actually
# ingested or being silently permission-trimmed at query time.

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

$t = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
if (-not $t) { throw 'no token' }
$h = @{ Authorization = "Bearer $t"; 'Content-Type' = 'application/json' }
$svc = "https://$env:AZURE_SEARCH_SERVICE.search.windows.net"
$apiKb = 'api-version=2026-08-01-preview'
$apiIdx = 'api-version=2026-04-01'

Write-Host "`n--- knowledge sources ---" -ForegroundColor Cyan
$ks = Invoke-RestMethod -Uri "$svc/knowledgeSources?$apiKb" -Headers $h
$ks.value | ForEach-Object { Write-Host "  $($_.name)  kind=$($_.kind)" }

Write-Host "`n--- KB detail ---" -ForegroundColor Cyan
$kb = Invoke-RestMethod -Uri "$svc/knowledgeBases/$env:FOUNDRY_KB_NAME`?$apiKb" -Headers $h
Write-Host "sources on KB:"
$kb.knowledgeSources | ForEach-Object { Write-Host "  $($_.name)" }

Write-Host "`n--- index docs count ---" -ForegroundColor Cyan
$stats = Invoke-RestMethod -Uri "$svc/indexes/$env:AZURE_SEARCH_INDEX/stats?$apiIdx" -Headers $h
Write-Host "  documents: $($stats.documentCount)"

Write-Host "`n--- indexers status ---" -ForegroundColor Cyan
$ixrs = Invoke-RestMethod -Uri "$svc/indexers?$apiIdx" -Headers $h
foreach ($i in $ixrs.value) {
    try {
        $s = Invoke-RestMethod -Uri "$svc/indexers/$($i.name)/status?$apiIdx" -Headers $h
        Write-Host "  $($i.name): lastResult=$($s.lastResult.status) processed=$($s.lastResult.itemsProcessed) failed=$($s.lastResult.itemsFailed)"
        if ($s.lastResult.errors.Count -gt 0) {
            $s.lastResult.errors | Select-Object -First 5 | ForEach-Object { Write-Host "    ERR: $($_.errorMessage)" -ForegroundColor Red }
        }
    }
    catch { Write-Host "  $($i.name): status err $($_.Exception.Message)" }
}

Write-Host "`n--- sample docs by source ---" -ForegroundColor Cyan
$q = @{ search = '*'; select = 'ref_id,source_name,uri,title'; count = $true; top = 5; facets = @('source_name') } | ConvertTo-Json -Compress
try {
    $srch = Invoke-RestMethod -Method POST -Uri "$svc/indexes/$env:AZURE_SEARCH_INDEX/docs/search?$apiIdx" -Headers $h -Body $q
    Write-Host "  total docs: $($srch.'@odata.count')"
    if ($srch.'@search.facets'.source_name) {
        Write-Host "  facets(source_name):"
        $srch.'@search.facets'.source_name | ForEach-Object { Write-Host "    $($_.value): $($_.count)" }
    }
}
catch {
    Write-Host "  facet query failed: $($_.Exception.Message)" -ForegroundColor Yellow
    # try without facet in case field name differs
    $q2 = @{ search = '*'; count = $true; top = 3 } | ConvertTo-Json -Compress
    try {
        $srch = Invoke-RestMethod -Method POST -Uri "$svc/indexes/$env:AZURE_SEARCH_INDEX/docs/search?$apiIdx" -Headers $h -Body $q2
        Write-Host "  total docs: $($srch.'@odata.count')"
        Write-Host "  first doc fields: $(($srch.value[0].PSObject.Properties.Name) -join ', ')"
    }
    catch { Write-Host "  raw search also failed: $($_.Exception.Message)" -ForegroundColor Red }
}
