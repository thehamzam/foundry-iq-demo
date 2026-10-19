#!/usr/bin/env pwsh
# Look at the current ACL on individual SP files. If the /invite grant we made
# on folders isn't propagating to file items, that explains why the indexer
# still doesn't capture DemoFS-Frontline-Staff / DemoFS on the docs.
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
$gt = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv
$h = @{ Authorization = "Bearer $gt" }
$driveId = (Get-Content config/.sp-drive-id -Raw).Trim()
$folderMap = Get-Content config/.sp-folder-ids.json -Raw | ConvertFrom-Json

foreach ($fname in @('Policies', 'Compliance')) {
    $fid = $folderMap.$fname
    Write-Host "`n=== folder '$fname' children ===" -ForegroundColor Cyan
    $kids = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/drives/$driveId/items/$fid/children" -Headers $h
    foreach ($k in $kids.value | Select-Object -First 2) {
        Write-Host "`n--- $($k.name) (id $($k.id)) ---" -ForegroundColor Yellow
        $perms = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/drives/$driveId/items/$($k.id)/permissions" -Headers $h
        foreach ($p in $perms.value) {
            $roles = $p.roles -join ','
            $who = if ($p.grantedToV2.user) { "USER:$($p.grantedToV2.user.displayName)($($p.grantedToV2.user.id))" }
            elseif ($p.grantedToV2.group) { "GROUP:$($p.grantedToV2.group.displayName)($($p.grantedToV2.group.id))" }
            elseif ($p.grantedToV2.siteGroup) { "SITEGROUP:$($p.grantedToV2.siteGroup.displayName)($($p.grantedToV2.siteGroup.id))" }
            else { $p.grantedToV2 | ConvertTo-Json -Compress }
            $src = if ($p.inheritedFrom) { 'INHERITED from ' + $p.inheritedFrom.path } else { 'DIRECT' }
            Write-Host "  [$src] $roles  ← $who"
        }
    }
}
