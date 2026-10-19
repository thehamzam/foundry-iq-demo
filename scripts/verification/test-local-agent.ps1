#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Invoke the local agent (dispute_agent) using its HTTP API,
  using the local agent API shape. Prints the assistant text so we can
  compare per-persona output against the hosted Foundry agent.

  Prereqs:
    - Local agent running at the caller-supplied RuntimeUri
    - Local agent authentication configured for the persona you want to test
#>
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

# 1. create a thread
$th = Invoke-RestMethod -Method POST -Uri "$base/threads" -Body '{}' -ContentType 'application/json'
$threadId = $th.thread_id
if ([string]::IsNullOrWhiteSpace($threadId)) { throw 'Runtime did not return a thread ID.' }
Write-Host "thread: $threadId" -ForegroundColor DarkGray

# 2. run — /wait blocks and returns the final state
$prompt = 'Using only the explicitly synthetic ChunkingLab sources, what intake steps does PROC-CHUNKLAB-101 prescribe for the duplicate-charge drill? Cite the source.'
$runBody = @{
    assistant_id = $AssistantId
    input        = @{ messages = @(@{ role = 'user'; content = $prompt }) }
} | ConvertTo-Json -Depth 8

Write-Host "→ /threads/{id}/runs/wait  (30-90 sec)" -ForegroundColor Cyan
$r = Invoke-RestMethod -Method POST -Uri "$base/threads/$threadId/runs/wait" -Body $runBody -ContentType 'application/json' -TimeoutSec 240

$msgs = $r.messages
$last = $msgs | Where-Object { $_.type -eq 'ai' -or $_.role -eq 'assistant' } | Select-Object -Last 1
if (-not $last) { $last = $msgs | Select-Object -Last 1 }
if (-not $last) { throw 'Runtime response did not contain a message.' }

Write-Host "`n===== Local agent response =====" -ForegroundColor Green
if ($last.content -is [array]) {
    $text = ($last.content | ForEach-Object { if ($_.text) { $_.text } else { "$_" } }) -join "`n"
}
else { $text = "$($last.content)" }
if ([string]::IsNullOrWhiteSpace($text)) { throw 'Runtime response message was empty.' }
Write-Host $text
Write-Host "===========================" -ForegroundColor Green
