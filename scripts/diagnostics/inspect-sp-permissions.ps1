#!/usr/bin/env pwsh
# Query the SharePoint knowledge-source index directly (bypassing the KB) so we can
# see the raw ACL / group metadata attached to each SP document. If our user is not
# in any of those group IDs, the KB permission trimmer will silently hide SP docs.

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

$t = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
$h = @{ Authorization = "Bearer $t"; 'Content-Type' = 'application/json' }
$svc = "https://$env:AZURE_SEARCH_SERVICE.search.windows.net"

# discover fields on the SP index
Write-Host "--- SP index fields ---" -ForegroundColor Cyan
$def = Invoke-RestMethod -Uri "$svc/indexes/demofs-sharepoint-source-index?api-version=2026-04-01" -Headers $h
$def.fields | ForEach-Object { Write-Host "  $($_.name)  ($($_.type))  retrievable=$($_.retrievable)  filterable=$($_.filterable)" }

Write-Host "`n--- SP docs (top 3, all fields) ---" -ForegroundColor Cyan
$q = @{ search = '*'; top = 3 } | ConvertTo-Json -Compress
$r = Invoke-RestMethod -Method POST -Uri "$svc/indexes/demofs-sharepoint-source-index/docs/search?api-version=2026-04-01" -Headers $h -Body $q
foreach ($d in $r.value) {
    Write-Host "`n---"
    foreach ($p in $d.PSObject.Properties) {
        $v = "$($p.Value)"
        if ($v.Length -gt 300) { $v = $v.Substring(0, 300) + '…' }
        Write-Host "  $($p.Name) = $v"
    }
}

Write-Host "`n--- my user's group memberships (transitive) ---" -ForegroundColor Cyan
$myGroups = az rest --method GET --uri 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf?$select=id,displayName' --query 'value[].{id:id,name:displayName}' -o json | ConvertFrom-Json
$myGroups | ForEach-Object { Write-Host "  $($_.id)  $($_.name)" }
