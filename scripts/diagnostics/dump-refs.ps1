#!/usr/bin/env pwsh
# Read the last KB probe response and print every reference URL.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$raw = Get-Content (Join-Path $RepoRoot 'tmp-kb-raw.json') -Raw | ConvertFrom-Json
$refs = $raw.result.content | Where-Object type -eq 'text' | Where-Object { $_.text.StartsWith('{') } | ForEach-Object { $_.text | ConvertFrom-Json }
Write-Host "=== KB refs — full paths ===" -ForegroundColor Cyan
foreach ($r in $refs) {
    $url = if ($r.uri) { $r.uri } elseif ($r.sourceData.doc_url) { $r.sourceData.doc_url } else { $r.sourceData.blob_url }
    Write-Host "  ref_id=$($r.ref_id)"
    Write-Host "    $url"
}
