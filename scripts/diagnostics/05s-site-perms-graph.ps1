#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Use Microsoft Graph to inspect who has access to the DemoFS SP site's
  root drive item (site-level permission). This shows whether "everyone in
  the org" got auto-added to the site's Visitors group, which would explain
  why frontline can see docs whose captured GroupIds only include DemoFS's SP
  Visitors group.
#>
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)

$gt = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv
$h = @{ Authorization = "Bearer $gt" }
$siteId = (Get-Content config/.sp-site-id -Raw).Trim()

Write-Host "=== site-level permissions (Graph /sites/{id}/permissions) ===" -ForegroundColor Cyan
try {
    $p = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$siteId/permissions" -Headers $h
    if ($p.value.Count -eq 0) { Write-Host "  (no site-level Graph permissions returned)" -ForegroundColor Yellow }
    foreach ($x in $p.value) { $x | ConvertTo-Json -Depth 8 }
}
catch { Write-Host "err: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`n=== drive root item permissions (Graph /drives/{drive}/root/permissions) ===" -ForegroundColor Cyan
$driveId = (Get-Content config/.sp-drive-id -Raw).Trim()
try {
    $p = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/drives/$driveId/root/permissions" -Headers $h
    foreach ($x in $p.value) {
        $roles = $x.roles -join ','
        $who = if ($x.grantedToV2.user) { "USER:$($x.grantedToV2.user.displayName)($($x.grantedToV2.user.id))" }
        elseif ($x.grantedToV2.group) { "GROUP:$($x.grantedToV2.group.displayName)($($x.grantedToV2.group.id))" }
        elseif ($x.grantedToV2.siteGroup) { "SITEGROUP:$($x.grantedToV2.siteGroup.displayName)  loginName='$($x.grantedToV2.siteGroup.loginName)'" }
        else { $x.grantedToV2 | ConvertTo-Json -Compress }
        $inh = if ($x.inheritedFrom) { 'INHERITED' } else { 'DIRECT   ' }
        Write-Host "  $inh  $roles  ← $who"
    }
}
catch { Write-Host "err: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`n=== root drive item — Grant relationships ===" -ForegroundColor Cyan
try {
    $s = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$siteId?`$expand=drive,lists,columns" -Headers $h
    Write-Host "  site displayName: $($s.displayName)"
    Write-Host "  webUrl: $($s.webUrl)"
}
catch {}
