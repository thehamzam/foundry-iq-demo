#!/usr/bin/env pwsh
# Quick smoke test for the hosted Foundry LangGraph agent (demofs-dispute-langgraph).
# Loads config/demo.env, gets an ai.azure.com token via `az`, POSTs a prompt to the
# agent's OpenAI Responses endpoint, and prints the assistant text so we can eyeball
# citations and prose format.

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)

Get-Content config/demo.env | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

$t = az account get-access-token --resource 'https://ai.azure.com' --query accessToken -o tsv
if (-not $t) { throw 'Failed to acquire ai.azure.com token' }

$body = @{
    input = 'A cardholder reports two identical $49.99 grocery charges from the same coastal Florida merchant last night. What should the agent do, and what confidential guidance applies?'
} | ConvertTo-Json -Compress

$uri = "$env:FOUNDRY_PROJECT_ENDPOINT/agents/$env:FOUNDRY_HOSTED_AGENT_NAME/endpoint/protocols/openai/responses?api-version=v1"
Write-Host "POST $uri" -ForegroundColor Cyan

try {
    $r = Invoke-WebRequest -Method POST -Uri $uri -Headers @{ Authorization = "Bearer $t"; 'Content-Type' = 'application/json' } -Body $body -TimeoutSec 240
    $j = $r.Content | ConvertFrom-Json
    $out = ($j.output | Where-Object type -eq 'message' | ForEach-Object { $_.content } | Where-Object type -eq 'output_text' | ForEach-Object { $_.text }) -join "`n"
    Write-Host "`n===== HOSTED FOUNDRY AGENT RESPONSE =====" -ForegroundColor Green
    Write-Host $out
    Write-Host "===========================`n" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Response) {
        $s = $_.Exception.Response.GetResponseStream()
        $sr = New-Object System.IO.StreamReader($s)
        Write-Host $sr.ReadToEnd()
    }
    exit 1
}
