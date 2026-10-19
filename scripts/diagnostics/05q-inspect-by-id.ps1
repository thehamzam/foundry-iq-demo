#!/usr/bin/env pwsh
# Look at Runbooks folder permissions using the saved folder ID (works even if
# the caller can't list the drive root, e.g., a non-site-member).
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
$gt = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv
$h = @{ Authorization = "Bearer $gt" }
$driveId = (Get-Content config/.sp-drive-id -Raw).Trim()
$folderMap = Get-Content config/.sp-folder-ids.json -Raw | ConvertFrom-Json

foreach ($fname in @('Runbooks', 'Compliance', 'Policies', 'VisaRules')) {
    $fid = $folderMap.$fname
    Write-Host "`n=== $fname ($fid) ===" -ForegroundColor Cyan
    try {
        $perms = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/drives/$driveId/items/$fid/permissions" -Headers $h
        foreach ($p in $perms.value) {
            $roles = $p.roles -join ','
            $who = if ($p.grantedToV2.user) { "USER:$($p.grantedToV2.user.displayName)($($p.grantedToV2.user.id))" }
            elseif ($p.grantedToV2.group) { "GROUP:$($p.grantedToV2.group.displayName)($($p.grantedToV2.group.id))" }
            elseif ($p.grantedToV2.siteGroup) { "SITEGROUP:$($p.grantedToV2.siteGroup.displayName)" }
            else { '(unknown)' }
            $inh = if ($p.inheritedFrom) { 'INHERITED' } else { 'DIRECT   ' }
            Write-Host "  $inh  $roles  ← $who"
        }
    }
    catch { Write-Host "  err: $($_.Exception.Message)" -ForegroundColor Red }
}
