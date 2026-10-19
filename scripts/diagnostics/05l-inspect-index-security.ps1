#!/usr/bin/env pwsh
# Inspect the SP index-level security settings (permissionFilterOption, field
# permissionFilter attributes) so we can see whether query-time trimming is on.
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

$idx = Invoke-RestMethod -Uri "$svc/indexes/demofs-sharepoint-source-index?api-version=2026-04-01" -Headers $h
Write-Host "permissionFilterOption at index level: $($idx.permissionFilterOption)"
Write-Host "`nFields with permissionFilter attribute set:" -ForegroundColor Cyan
$secFields = $idx.fields | Where-Object { $_.permissionFilter }
if ($secFields) {
    $secFields | ForEach-Object { Write-Host "  $($_.name)  permissionFilter=$($_.permissionFilter)" }
} else { Write-Host "  (none)" -ForegroundColor Yellow }
Write-Host "`nAll fields:" -ForegroundColor Cyan
$idx.fields | ForEach-Object { Write-Host "  $($_.name)  type=$($_.type)  filterable=$($_.filterable)  retrievable=$($_.retrievable)  permissionFilter=$($_.permissionFilter)" }
