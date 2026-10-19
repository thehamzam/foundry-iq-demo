#!/usr/bin/env pwsh
# Decode both search.azure.com and ai.azure.com tokens and compare their
# `groups` claims.
$ErrorActionPreference = 'Continue'
function Decode-Jwt($t) {
    $parts = $t.Split('.')
    $b = $parts[1].Replace('-', '+').Replace('_', '/')
    while ($b.Length % 4) { $b += '=' }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json
}

foreach ($res in @('https://search.azure.com', 'https://ai.azure.com', 'https://graph.microsoft.com')) {
    $tok = az account get-access-token --resource $res --query accessToken -o tsv 2>$null
    if (-not $tok) { Write-Host "$res  (no token)" -ForegroundColor Yellow; continue }
    $p = Decode-Jwt $tok
    Write-Host "`n=== $res ===" -ForegroundColor Cyan
    Write-Host "  upn:       $($p.upn)"
    Write-Host "  aud:       $($p.aud)"
    Write-Host "  appid:     $($p.appid)   (04b0... = Azure CLI)"
    Write-Host "  groups:    $(($p.groups | Sort-Object) -join ',')"
    Write-Host "  hasgroups: $($p.hasgroups)"
    Write-Host "  wids:      $(($p.wids | Sort-Object) -join ',')"
}
