#!/usr/bin/env pwsh
# Look at every search index (KB creates its own), plus the SharePoint knowledge
# source configuration so we can tell whether SP docs made it in and if permission
# trimming is on.

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

Write-Host "--- all indexes ---" -ForegroundColor Cyan
$idxs = Invoke-RestMethod -Uri "$svc/indexes?api-version=2026-04-01" -Headers $h
foreach ($i in $idxs.value) {
    try {
        $s = Invoke-RestMethod -Uri "$svc/indexes/$($i.name)/stats?api-version=2026-04-01" -Headers $h
        Write-Host "  $($i.name)  docs=$($s.documentCount)  size=$($s.storageSize)"
    }
    catch { Write-Host "  $($i.name) — stats err" }
}

Write-Host "`n--- sharepoint KS full spec ---" -ForegroundColor Cyan
$sp = Invoke-RestMethod -Uri "$svc/knowledgeSources/$env:FOUNDRY_KB_SHAREPOINT_SOURCE`?api-version=2026-08-01-preview" -Headers $h
$sp | ConvertTo-Json -Depth 15

Write-Host "`n--- blob KS full spec ---" -ForegroundColor Cyan
$b = Invoke-RestMethod -Uri "$svc/knowledgeSources/$env:FOUNDRY_KB_BLOB_SOURCE`?api-version=2026-08-01-preview" -Headers $h
$b | ConvertTo-Json -Depth 15
