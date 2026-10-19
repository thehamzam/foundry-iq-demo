#!/usr/bin/env pwsh
# List users, groups, and current SharePoint site info by hitting Graph directly
# with a fresh token (so we bypass `az rest`'s cached token that failed CAE).

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

$gt = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv
if (-not $gt) { throw 'no graph token' }
$h = @{ Authorization = "Bearer $gt" }

Write-Host "=== users ===" -ForegroundColor Cyan
$u = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,accountEnabled' -Headers $h
$u.value | Format-Table id, userPrincipalName, displayName, accountEnabled -AutoSize | Out-Host

Write-Host "`n=== groups ===" -ForegroundColor Cyan
$g = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName,securityEnabled,mailEnabled,groupTypes' -Headers $h
$g.value | Format-Table id, displayName, securityEnabled, mailEnabled, @{n = 'types'; e = { $_.groupTypes -join ',' } } -AutoSize | Out-Host

Write-Host "`n=== SharePoint sites ===" -ForegroundColor Cyan
try {
    $s = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/sites?search=*' -Headers $h
    $s.value | Format-Table id, displayName, webUrl -AutoSize | Out-Host
}
catch { Write-Host "sites err: $($_.Exception.Message)" }
