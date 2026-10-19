#!/usr/bin/env pwsh
# Decode the current admin's search.azure.com JWT to see what group / role
# claims the KB permission trimmer will actually see.
$ErrorActionPreference = 'Continue'
$t = az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv
$parts = $t.Split('.')
function Decode-B64Url($s) {
    $s = $s.Replace('-', '+').Replace('_', '/')
    while ($s.Length % 4) { $s += '=' }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}
$header = Decode-B64Url $parts[0]
$payload = Decode-B64Url $parts[1]
Write-Host "=== header ===" -ForegroundColor Cyan
$header | ConvertFrom-Json | ConvertTo-Json
Write-Host "`n=== payload ===" -ForegroundColor Cyan
$p = $payload | ConvertFrom-Json
$p | ConvertTo-Json -Depth 5
Write-Host "`n=== summary ===" -ForegroundColor Yellow
Write-Host "aud:       $($p.aud)"
Write-Host "oid:       $($p.oid)"
Write-Host "upn:       $($p.upn)"
Write-Host "roles:     $($p.roles -join ',')"
Write-Host "groups:    $($p.groups -join ',')"
Write-Host "hasgroups: $($p.hasgroups)"
Write-Host "wids:      $($p.wids -join ',')"
