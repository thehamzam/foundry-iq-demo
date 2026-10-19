#requires -Version 7.4
[CmdletBinding()]
param(
  [string]$ManifestPath = (
    Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) `
      'langgraph-agent-local\requirements.txt'
  ),
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$approvedRequirements = [ordered]@{
  'langgraph' = $true
  'langchain' = $true
  'langchain-openai' = $true
  'langchain-core' = $true
  'langchain-azure-ai[tools]' = $true
  'langchain-mcp-adapters' = $true
  'azure-identity' = $true
  'azure-search-documents' = $true
  'openai' = $true
  'httpx' = $true
  'python-dotenv' = $true
}
$versionPattern = '[0-9]+(?:\.[0-9]+){1,3}'
$requirementPattern = (
  '^(?<identity>[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*' +
  '(?:\[[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*' +
  '(?:,[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*)*\])?)' +
  "(?:==(?<exact>$versionPattern)|>=(?<lower>$versionPattern),<(?<upper>$versionPattern))$"
)

function Get-NormalizedRequirementIdentity {
  param([Parameter(Mandatory)][string]$Identity)

  $parts = $Identity -split '\[', 2
  $name = $parts[0].ToLowerInvariant().Replace('_', '-').Replace('.', '-')
  if ($parts.Count -eq 1) {
    return $name
  }
  return "$name[$($parts[1].ToLowerInvariant())"
}

function Test-DependencyManifestLines {
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [string[]]$Lines
  )

  $errors = [System.Collections.Generic.List[string]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

  for ($index = 0; $index -lt $Lines.Count; $index++) {
    $line = $Lines[$index].Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
      continue
    }

    $match = [regex]::Match($line, $requirementPattern)
    if (-not $match.Success) {
      $errors.Add(
        "Line $($index + 1) must be an exact pin or a two-sided version bound with no options, URLs, paths, editables, VCS references, includes, or directives."
      )
      continue
    }

    $identity = Get-NormalizedRequirementIdentity -Identity $match.Groups['identity'].Value
    if (-not $approvedRequirements.Contains($identity)) {
      $errors.Add("Line $($index + 1) uses an unapproved package name.")
      continue
    }
    if (-not $seen.Add($identity)) {
      $errors.Add("Line $($index + 1) duplicates an approved package.")
      continue
    }

    if ($match.Groups['lower'].Success) {
      $lower = [version]$match.Groups['lower'].Value
      $upper = [version]$match.Groups['upper'].Value
      if ($lower -ge $upper) {
        $errors.Add("Line $($index + 1) has a version bound whose lower limit is not below its upper limit.")
      }
    }
  }

  foreach ($identity in $approvedRequirements.Keys) {
    if (-not $seen.Contains($identity)) {
      $errors.Add("Required approved package '$identity' is missing.")
    }
  }

  return [pscustomobject]@{
    IsValid = $errors.Count -eq 0
    Errors = @($errors)
  }
}

function Invoke-SelfTests {
  $probeCount = 0
  $validLines = @(
    '# Approved direct dependencies'
    'langgraph==1.2.11'
    'langchain==1.3.15'
    'langchain-openai==1.5.1'
    'langchain-core==1.5.5'
    'langchain-azure-ai[tools]==1.2.8'
    'langchain-mcp-adapters==0.3.2'
    'azure-identity==1.25.3'
    'azure-search-documents>=12.0.0,<13.0.0'
    'openai==2.54.0'
    'httpx==0.28.1'
    'python-dotenv==1.2.2'
    ''
  )

  $validResult = Test-DependencyManifestLines -Lines $validLines
  if (-not $validResult.IsValid) {
    throw 'Dependency manifest self-test failed: the approved positive fixture was rejected.'
  }
  $probeCount++

  $invalidLines = [ordered]@{
    'requirement include' = '-r other-requirements.txt'
    'long requirement include' = '--requirement other-requirements.txt'
    'editable dependency' = '-e ../package'
    'index URL' = '--index-url https://packages.invalid/simple'
    'extra index URL' = '--extra-index-url https://packages.invalid/simple'
    'VCS reference' = 'httpx @ git+https://example.invalid/repository.git'
    'direct URL' = 'https://example.invalid/httpx.whl'
    'local relative path' = '../httpx'
    'local wheel path' = '.\httpx.whl'
    'bare option' = '--pre'
    'unbounded version' = 'httpx>=0.28.0'
    'environment marker' = 'httpx==0.28.1; python_version>="3.11"'
    'unapproved package' = 'requests==2.32.5'
  }
  foreach ($entry in $invalidLines.GetEnumerator()) {
    $result = Test-DependencyManifestLines -Lines @($validLines + $entry.Value)
    if ($result.IsValid) {
      throw "Dependency manifest self-test failed: $($entry.Key) was accepted."
    }
    $probeCount++
  }

  $reversedBoundsResult = Test-DependencyManifestLines -Lines @(
    $validLines | ForEach-Object {
      if ($_ -eq 'httpx==0.28.1') { 'httpx>=1.0.0,<0.28.1' } else { $_ }
    }
  )
  if (
    $reversedBoundsResult.IsValid -or
    @($reversedBoundsResult.Errors | Where-Object { $_ -match 'lower limit' }).Count -ne 1
  ) {
    throw 'Dependency manifest self-test failed: reversed bounds were not rejected for their ordering.'
  }
  $probeCount++

  $missingResult = Test-DependencyManifestLines -Lines @(
    $validLines | Where-Object { $_ -ne 'httpx==0.28.1' }
  )
  if ($missingResult.IsValid) {
    throw 'Dependency manifest self-test failed: a missing approved package was accepted.'
  }
  $probeCount++

  Write-Host "PASS: $probeCount dependency manifest positive/negative probes."
}

if ($SelfTest) {
  Invoke-SelfTests
  return
}

$resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifestLines = @((Get-Content -LiteralPath $resolvedManifestPath -Raw) -split "`r?`n")
$validation = Test-DependencyManifestLines -Lines $manifestLines
if (-not $validation.IsValid) {
  foreach ($validationError in $validation.Errors) {
    Write-Error -ErrorAction Continue "FAIL: $validationError"
  }
  throw "$($validation.Errors.Count) dependency manifest validation failure(s) found."
}

Write-Host "PASS: Dependency manifest contains only $($approvedRequirements.Count) approved, exact or bounded direct dependencies."
