#requires -Version 7.4
[CmdletBinding()]
param(
  [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path

$dependencyValidator = Join-Path $RepositoryRoot 'scripts\ci\Test-DependencyManifest.ps1'
$dependencyManifest = Join-Path $RepositoryRoot 'langgraph-agent-local\requirements.txt'
& pwsh -NoProfile -File $dependencyValidator -SelfTest
if ($LASTEXITCODE -ne 0) {
  throw 'Dependency manifest positive/negative probes failed.'
}
& pwsh -NoProfile -File $dependencyValidator -ManifestPath $dependencyManifest
if ($LASTEXITCODE -ne 0) {
  throw 'Declared Python dependency manifest validation failed.'
}

function Get-PublicFiles {
  $files = @(& git -C $RepositoryRoot ls-files --cached --others --exclude-standard)
  if ($LASTEXITCODE -ne 0) {
    throw 'Unable to enumerate public repository files with git.'
  }
  return @($files |
    Where-Object {
      -not [string]::IsNullOrWhiteSpace($_) -and
      (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_) -PathType Leaf)
    } |
    Sort-Object -Unique)
}

function Invoke-Bicep {
  param(
    [Parameter(Mandatory)][ValidateSet('build', 'build-params')][string]$Operation,
    [Parameter(Mandatory)][string]$Path,
    [string]$OutputPath
  )

  $arguments = @('bicep', $Operation, '--file', $Path)
  if ($OutputPath) {
    $arguments += @('--outfile', $OutputPath)
  } else {
    $arguments += '--stdout'
  }

  & az @arguments 1>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Bicep $Operation failed for $Path."
  }
}

$bicepVersion = az bicep version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $bicepVersion -notmatch '\b0\.47\.16\b') {
  throw 'Public CI requires the preinstalled Bicep CLI version 0.47.16.'
}

$publicFiles = Get-PublicFiles
$bicepFiles = @($publicFiles | Where-Object { $_ -like 'infra/*.bicep' })
$parameterFiles = @($publicFiles | Where-Object { $_ -like 'infra/*.bicepparam' })
$powerShellFiles = @($publicFiles | Where-Object { $_ -match '\.ps(m1|1)$' })

foreach ($relativePath in $bicepFiles) {
  Invoke-Bicep -Operation build -Path (Join-Path $RepositoryRoot $relativePath)
}

$fixturePath = Join-Path $RepositoryRoot 'infra\tests\fixtures\tenant-parity.synthetic.json'
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -AsHashtable
if ($fixture.synthetic -ne $true) {
  throw 'Tenant parity parameter compilation requires the explicitly synthetic fixture.'
}
$syntheticGrants = @($fixture.evidence.assignments | ForEach-Object {
    @{
      principalId = $_.principalId
      resourceId = $_.resourceId
      appRoleId = $_.appRoleId
    }
  })

$savedTenantId = [Environment]::GetEnvironmentVariable('AZURE_TENANT_ID', 'Process')
$savedGrants = [Environment]::GetEnvironmentVariable('TENANT_APP_ROLE_GRANTS_JSON', 'Process')
try {
  [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', [string]$fixture.evidence.tenantId, 'Process')
  [Environment]::SetEnvironmentVariable(
    'TENANT_APP_ROLE_GRANTS_JSON',
    ($syntheticGrants | ConvertTo-Json -Depth 4 -Compress),
    'Process'
  )
  foreach ($relativePath in $parameterFiles) {
    Invoke-Bicep -Operation build-params -Path (Join-Path $RepositoryRoot $relativePath)
  }
} finally {
  [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $savedTenantId, 'Process')
  [Environment]::SetEnvironmentVariable('TENANT_APP_ROLE_GRANTS_JSON', $savedGrants, 'Process')
}

$parseErrorCount = 0
foreach ($relativePath in $powerShellFiles) {
  $tokens = $null
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepositoryRoot $relativePath),
    [ref]$tokens,
    [ref]$parseErrors
  )
  foreach ($parseError in @($parseErrors)) {
    $parseErrorCount++
    Write-Error -ErrorAction Continue "${relativePath}:$($parseError.Extent.StartLineNumber): $($parseError.Message)"
  }
}
if ($parseErrorCount -ne 0) {
  throw "$parseErrorCount PowerShell AST parse error(s) found."
}
Write-Host "PASS: $($powerShellFiles.Count) public PowerShell files parse without errors."

$bicepExecutableName = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
$bicepPath = Join-Path $HOME ".azure\bin\$bicepExecutableName"
if (-not (Test-Path -LiteralPath $bicepPath -PathType Leaf)) {
  throw "Pinned Bicep executable was not found at $bicepPath."
}

$compiledTemplatePath = Join-Path ([IO.Path]::GetTempPath()) "public-main-$([guid]::NewGuid().ToString('N')).json"
try {
  Invoke-Bicep `
    -Operation build `
    -Path (Join-Path $RepositoryRoot 'infra\main.bicep') `
    -OutputPath $compiledTemplatePath

  $powerShellSuites = @(
    @{ Path = 'infra\tests\Test-PublicQuickstartContract.ps1'; Arguments = @('-RepositoryRoot', $RepositoryRoot, '-CompiledTemplatePath', $compiledTemplatePath) }
    @{ Path = 'infra\tests\Test-QuickstartMutation.ps1'; Arguments = @('-RepositoryRoot', $RepositoryRoot) }
    @{ Path = 'infra\tests\Test-QuickstartAuthorization.ps1'; Arguments = @('-RepositoryRoot', $RepositoryRoot) }
    @{ Path = 'infra\tests\Test-InfraParity.ps1'; Arguments = @('-RepositoryRoot', $RepositoryRoot, '-CompiledTemplatePath', $compiledTemplatePath) }
    @{ Path = 'infra\tests\Test-OperationalScriptBoundary.ps1'; Arguments = @() }
    @{ Path = 'infra\tests\Test-TenantParity.ps1'; Arguments = @('-BicepPath', $bicepPath, '-RunMutationTests') }
    @{ Path = 'infra\tests\TestToolboxRecovery.ps1'; Arguments = @() }
  )

  foreach ($suite in $powerShellSuites) {
    $suitePath = Join-Path $RepositoryRoot $suite.Path
    & pwsh -NoProfile -File $suitePath @($suite.Arguments)
    if ($LASTEXITCODE -ne 0) {
      throw "Offline test failed: $($suite.Path)"
    }
  }

  Push-Location $RepositoryRoot
  try {
    & python -m unittest discover -s langgraph-agent-local/tests -p 'test_*.py' -v
    if ($LASTEXITCODE -ne 0) {
      throw 'Local-agent unit tests failed.'
    }

    & python -m unittest discover -s custom-skill/tests -p 'test_*.py' -v
    if ($LASTEXITCODE -ne 0) {
      throw 'Custom-skill unit tests failed.'
    }
  } finally {
    Pop-Location
  }

  $hygieneScript = Join-Path $RepositoryRoot 'scripts\ci\Test-PublicRepository.ps1'
  & pwsh -NoProfile -File $hygieneScript -RepositoryRoot $RepositoryRoot -SelfTest
  if ($LASTEXITCODE -ne 0) {
    throw 'Public repository hygiene self-tests failed.'
  }

  & pwsh -NoProfile -File $hygieneScript -RepositoryRoot $RepositoryRoot
  if ($LASTEXITCODE -ne 0) {
    throw 'Public repository hygiene checks failed.'
  }
} finally {
  if (Test-Path -LiteralPath $compiledTemplatePath) {
    Remove-Item -LiteralPath $compiledTemplatePath -Force
  }
}

$summary = (
  "Public CI passed: {0} Bicep files, {1} parameter files, {2} PowerShell files, " +
  "7 PowerShell test suites, 21 local-agent tests, custom-skill unit tests, " +
  "repository hygiene self-tests, and repository hygiene."
) -f $bicepFiles.Count, $parameterFiles.Count, $powerShellFiles.Count
Write-Host $summary
