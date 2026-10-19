#!/usr/bin/env pwsh
# Decode the search.azure.com token that each AZURE_CONFIG_DIR would issue,
# to verify port 2024 REALLY talks as admin and port 2025 REALLY talks as frontline.
$ErrorActionPreference = 'Continue'

function Decode-Jwt($t) {
    if (-not $t) { return $null }
    $b = $t.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($b.Length % 4) { $b += '=' }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json
}

foreach ($dir in @('/root/.azure-admin', '/root/.azure-frontline')) {
    Write-Host "`n=== $dir ===" -ForegroundColor Cyan
    $tok = wsl -d Ubuntu-24.04 -u root -- bash -c "AZURE_CONFIG_DIR=$dir az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv 2>/dev/null"
    if (-not $tok) { Write-Host "  (no token)" -ForegroundColor Red; continue }
    $p = Decode-Jwt $tok
    Write-Host "  aud:    $($p.aud)"
    Write-Host "  upn:    $($p.upn)"
    Write-Host "  oid:    $($p.oid)"
    Write-Host "  groups: $(($p.groups | Sort-Object) -join ',')"
}
