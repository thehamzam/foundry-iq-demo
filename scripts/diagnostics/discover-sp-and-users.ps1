#!/usr/bin/env pwsh
# Discover the SharePoint site targeted by the KS + list its files + list users
# in the tenant so we can design a per-persona permission split.

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

Write-Host "`n=== SP KS connection string ===" -ForegroundColor Cyan
$searchToken = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
$svc = "https://$env:AZURE_SEARCH_SERVICE.search.windows.net"
# NOTE: Search REST usually redacts connectionString. Grab it by pulling with admin-key path only if REST returns it.
$sp = Invoke-RestMethod -Uri "$svc/knowledgeSources/$env:FOUNDRY_KB_SHAREPOINT_SOURCE`?api-version=2026-08-01-preview" -Headers @{ Authorization = "Bearer $searchToken" }
Write-Host "  connectionString (redacted expected): $($sp.indexedSharePointParameters.connectionString)"
# Also pull the datasource which should still have the SP URL
$ds = Invoke-RestMethod -Uri "$svc/datasources/demofs-sharepoint-source-datasource?api-version=2026-04-01" -Headers @{ Authorization = "Bearer $searchToken" }
Write-Host "  datasource.container: $($ds.container | ConvertTo-Json -Compress)"
Write-Host "  datasource.credentials.connectionString: $($ds.credentials.connectionString)"

Write-Host "`n=== users in the tenant ===" -ForegroundColor Cyan
az rest --method GET --uri 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,accountEnabled' `
    --query 'value[].{id:id,upn:userPrincipalName,name:displayName,enabled:accountEnabled}' -o table

Write-Host "`n=== groups in the tenant (filtered) ===" -ForegroundColor Cyan
az rest --method GET --uri 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName,securityEnabled,groupTypes' `
    --query 'value[].{id:id,name:displayName,sec:securityEnabled,types:groupTypes}' -o table

Write-Host "`n=== my current identity ===" -ForegroundColor Cyan
az account show --query "{user:user.name,tenant:tenantId,sub:name}" -o table
