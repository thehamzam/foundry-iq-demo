#!/usr/bin/env pwsh
# Dump the full local-agent response for an explicitly synthetic ChunkingLab scenario.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [uri]$RuntimeUri,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AssistantId
)

$ErrorActionPreference = 'Stop'
if ($RuntimeUri.Scheme -notin @('http', 'https') -or $RuntimeUri.Query -or $RuntimeUri.Fragment) {
    throw 'RuntimeUri must be an HTTP(S) base URI without a query or fragment.'
}
$base = $RuntimeUri.AbsoluteUri.TrimEnd('/')
$prompt = 'Using only the explicitly synthetic ChunkingLab sources, summarize the duplicate-intake drill in PROC-CHUNKLAB-101 and cite the source.'
$th = Invoke-RestMethod -Method POST -Uri "$base/threads" -Body '{}' -ContentType 'application/json'
if ([string]::IsNullOrWhiteSpace($th.thread_id)) { throw 'Runtime did not return a thread ID.' }
$body = @{
    assistant_id = $AssistantId
    input        = @{ messages = @(@{ role = 'user'; content = $prompt }) }
} | ConvertTo-Json -Depth 8

$r = Invoke-RestMethod -Method POST -Uri "$base/threads/$($th.thread_id)/runs/wait" -Body $body -ContentType 'application/json' -TimeoutSec 240
$ai = $r.messages | Where-Object type -eq 'ai' | Select-Object -Last 1
if (-not $ai) { throw 'Runtime response did not contain an AI message.' }
$text = if ($ai.content -is [array]) { ($ai.content | ForEach-Object { $_.text }) -join "`n" } else { $ai.content }
if ([string]::IsNullOrWhiteSpace($text)) { throw 'Runtime AI message was empty.' }
Write-Host "===== FULL RESPONSE ====="
Write-Host $text
