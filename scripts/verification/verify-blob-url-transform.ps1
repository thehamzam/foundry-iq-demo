#!/usr/bin/env pwsh
# Ask an explicitly synthetic Blob-backed question and verify citation URL transformation.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [uri[]]$RuntimeUris,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AssistantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BlobHost,

    [Parameter(Mandatory = $true)]
    [uri]$PortalUrlPrefix
)

$ErrorActionPreference = 'Stop'
if ([uri]::CheckHostName($BlobHost) -eq [UriHostNameType]::Unknown -or $BlobHost.Contains('/') -or $BlobHost.Contains(':')) {
    throw 'BlobHost must be a DNS host name without a scheme, port, or path.'
}
if ($PortalUrlPrefix.Scheme -ne 'https' -or $PortalUrlPrefix.Query -or $PortalUrlPrefix.Fragment) {
    throw 'PortalUrlPrefix must be an HTTPS URI without a query or fragment.'
}
$portalPrefix = $PortalUrlPrefix.AbsoluteUri
$prompt = 'Using only the explicitly synthetic ChunkingLab sources, summarize the escalation drill in RUN-CHUNKLAB-202 and cite the source document.'

foreach ($runtime in $RuntimeUris) {
    if ($runtime.Scheme -notin @('http', 'https') -or $runtime.Query -or $runtime.Fragment) {
        throw "Runtime URI must be an HTTP(S) base URI without a query or fragment: $runtime"
    }
    $base = $runtime.AbsoluteUri.TrimEnd('/')
    Write-Host "`n=== Local agent runtime $base ===" -ForegroundColor Magenta

    $th = Invoke-RestMethod -Method POST -Uri "$base/threads" -Body '{}' -ContentType 'application/json'
    if ([string]::IsNullOrWhiteSpace($th.thread_id)) { throw "Runtime did not return a thread ID: $base" }
    $body = @{
        assistant_id = $AssistantId
        input        = @{ messages = @(@{ role = 'user'; content = $prompt }) }
    } | ConvertTo-Json -Depth 8

    $r = Invoke-RestMethod -Method POST -Uri "$base/threads/$($th.thread_id)/runs/wait" -Body $body -ContentType 'application/json' -TimeoutSec 240
    $ai = $r.messages | Where-Object type -eq 'ai' | Select-Object -Last 1
    if (-not $ai) { throw "Runtime response did not contain an AI message: $base" }
    $text = if ($ai.content -is [array]) { ($ai.content | ForEach-Object { $_.text }) -join "`n" } else { $ai.content }
    if ([string]::IsNullOrWhiteSpace($text)) { throw "Runtime AI message was empty: $base" }
    $urls = @([regex]::Matches($text, 'https?://[^\s\)\]]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($urls.Count -eq 0) { throw "Runtime response did not contain a citation URL: $base" }
    $rawBlobUrls = @($urls | Where-Object { ([uri]$_).Host -ieq $BlobHost })
    if ($rawBlobUrls.Count -gt 0) { throw "Runtime response exposed $($rawBlobUrls.Count) raw Blob URL(s): $base" }
    $portalUrls = @($urls | Where-Object { $_.StartsWith($portalPrefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($portalUrls.Count -eq 0) { throw "Runtime response did not contain the required portal URL prefix: $base" }
    Write-Host "PASS: $($portalUrls.Count) transformed portal citation URL(s); no raw Blob host URLs." -ForegroundColor Green
}
