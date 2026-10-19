#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Upload a single local synthetic doc to the blob knowledge container so the
  Foundry IQ blob knowledge source picks it up on its next refresh cycle
  (default: PT5M).

  Use during the freshness demo — read the doc aloud, upload with this, then
  wait ~1 min and ask the agent a question that requires the new content.

.EXAMPLE
  ./scripts/maintenance/upload-blob-doc.ps1 -Path sample-data/documents/PROC-CHUNKLAB-101-synthetic-duplicate-intake.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

if (-not (Test-Path $Path)) { throw "Path not found: $Path" }
$file = Get-Item $Path
$documentsRoot = (Resolve-Path 'sample-data/documents').Path.TrimEnd('\') + '\'
if (-not $file.FullName.StartsWith($documentsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "File must live under sample-data/documents/. Got: $($file.FullName)"
}
$relPath = $file.FullName.Substring($documentsRoot.Length).Replace('\', '/')

$acct = $env:AZURE_STORAGE_ACCOUNT
$container = $env:AZURE_STORAGE_CONTAINER
$uri = "https://$acct.blob.core.windows.net/$container/$relPath"

# Grab a fresh storage token via the caller's Entra identity (works over the
# private endpoint only — run this from a machine with line-of-sight to the
# storage account, or upload via scripts/maintenance/03b-upload-corpus.ps1).
$storageToken = az account get-access-token --resource 'https://storage.azure.com' --query accessToken -o tsv
if (-not $storageToken) { throw 'failed to acquire storage token' }

$headers = @{
    Authorization    = "Bearer $storageToken"
    'x-ms-version'   = '2023-11-03'
    'x-ms-blob-type' = 'BlockBlob'
    'Content-Type'   = 'text/markdown; charset=utf-8'
}

Write-Host "→ PUT $uri" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Method PUT -Uri $uri -Headers $headers -InFile $file.FullName -UseBasicParsing | Out-Null
    Write-Host "  uploaded ($([Math]::Round($file.Length / 1KB, 1)) KB)" -ForegroundColor Green
}
catch {
    Write-Host "  ERR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Response) {
        $s = $_.Exception.Response.GetResponseStream()
        (New-Object System.IO.StreamReader($s)).ReadToEnd()
    }
    return
}

Write-Host "`n→ Foundry IQ blob knowledge source refresh interval is 5 min (PT5M)."
Write-Host "  Watch progress: pwsh -File scripts/diagnostics/inspect-kb-state.ps1"
Write-Host "  Then re-ask the agent — it should cite the new document."
