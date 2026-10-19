#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Option B, step 2 — wait for SP ingestion to complete, then apply ONLY the
  two settings we know are safe:
    - permissionFilterOption = enabled
    - GroupIds field: permissionFilter = groupIds

  Do NOT touch SharePointSiteUrl / sharePointConnectorAppRegistration. Those
  broke the projection last round.
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
$api = 'api-version=2026-08-01-preview'
$idxName = 'demofs-sharepoint-source-index'
$ixr = 'demofs-sharepoint-source-indexer'

Write-Host "→ waiting for SP ingestion to land docs in the index" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(6)
$lastCount = -1
while ((Get-Date) -lt $deadline) {
    try {
        $stats = Invoke-RestMethod -Uri "$svc/indexes/$idxName/stats?api-version=2026-04-01" -Headers $h
        if ($stats.documentCount -ne $lastCount) {
            Write-Host "  [$((Get-Date).ToString('HH:mm:ss'))] docCount=$($stats.documentCount)"
            $lastCount = $stats.documentCount
        }
        if ($stats.documentCount -ge 7) { Write-Host "  → enough docs, proceeding"; break }
    }
    catch {
        Write-Host "  [$((Get-Date).ToString('HH:mm:ss'))] index not yet available: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
    Start-Sleep 15
}

Write-Host "`n→ patching index: permissionFilterOption + GroupIds.permissionFilter" -ForegroundColor Cyan
$idx = Invoke-RestMethod -Uri "$svc/indexes/$idxName`?$api" -Headers $h
$idx | Add-Member -Force -NotePropertyName permissionFilterOption -NotePropertyValue 'enabled'
foreach ($f in $idx.fields) {
    if ($f.name -eq 'GroupIds') {
        $f | Add-Member -Force -NotePropertyName permissionFilter -NotePropertyValue 'groupIds'
    }
}
$body = $idx | Select-Object -Property * -ExcludeProperty '@odata.context', '@odata.etag' | ConvertTo-Json -Depth 40
Invoke-RestMethod -Method PUT -Uri "$svc/indexes/$idxName`?$api" -Headers $h -Body $body | Out-Null
Write-Host "  ok"

Write-Host "`n=== verify ===" -ForegroundColor Cyan
$idx2 = Invoke-RestMethod -Uri "$svc/indexes/$idxName`?$api" -Headers $h
Write-Host "  permissionFilterOption: $($idx2.permissionFilterOption)"
$idx2.fields | Where-Object { $_.permissionFilter } | ForEach-Object {
    Write-Host "  '$($_.name)' permissionFilter=$($_.permissionFilter)"
}
