#requires -Version 7.4
[CmdletBinding()]
param(
  [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$failures = [System.Collections.Generic.List[object]]::new()
$passedGates = 0

function Add-Failure {
  param(
    [Parameter(Mandatory)][string]$Rule,
    [Parameter(Mandatory)][string]$Path,
    [int]$Line = 0
  )

  $failures.Add([pscustomobject]@{
      Rule = $Rule
      Path = $Path
      Line = $Line
    })
}

function Complete-Gate {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][int]$StartingFailureCount
  )

  if ($failures.Count -eq $StartingFailureCount) {
    $script:passedGates++
    Write-Host "PASS: $Name"
  }
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
    ForEach-Object { $_.Replace('\', '/') } |
    Sort-Object -Unique)
}

function Get-TextLines {
  param([Parameter(Mandatory)][string]$Path)
  return @((Get-Content -LiteralPath (Join-Path $RepositoryRoot $Path) -Raw) -split "`r?`n")
}

function Test-IsPublicTextPath {
  param([Parameter(Mandatory)][string]$Path)

  $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  $leaf = [IO.Path]::GetFileName($Path)
  return (
    $extension -in $script:textExtensions -or
    $leaf -in $script:textNames -or
    $Path -in $script:allowedEnvironmentFiles
  )
}

function Test-IsSafeExamplePath {
  param([Parameter(Mandatory)][string]$Path)
  return $Path -match '(?i)(?:^|/)(?:[^/]+\.)?(?:example|sample|template)(?:\.|/|$)'
}

function Test-IsGeneratedArtifactPath {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$PublicFileSet
  )

  if ($Path -match $script:generatedFilePattern) {
    return $true
  }

  if ($Path -match '(?i)\.json$') {
    $bicepSibling = [IO.Path]::ChangeExtension($Path, '.bicep').Replace('\', '/')
    if ($PublicFileSet.Contains($bicepSibling)) {
      return $true
    }
  }

  return $false
}

function Get-MarkdownAnchors {
  param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

  $anchors = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $headingCounts = @{}
  foreach ($line in $Lines) {
    foreach ($match in [regex]::Matches($line, '(?i)<(?:a|h[1-6])\b[^>]*\b(?:id|name)\s*=\s*["''](?<id>[^"'']+)["''][^>]*>')) {
      [void]$anchors.Add([Uri]::UnescapeDataString($match.Groups['id'].Value))
    }
    foreach ($match in [regex]::Matches($line, '\{#(?<id>[A-Za-z][A-Za-z0-9_.:-]*)\}')) {
      [void]$anchors.Add($match.Groups['id'].Value)
    }

    $headingMatch = [regex]::Match($line, '^\s{0,3}#{1,6}\s+(?<heading>.+?)\s*#*\s*$')
    if (-not $headingMatch.Success) {
      continue
    }

    $heading = $headingMatch.Groups['heading'].Value
    $heading = [regex]::Replace($heading, '\s*\{#[A-Za-z][A-Za-z0-9_.:-]*\}\s*$', '')
    $heading = [regex]::Replace($heading, '<[^>]+>', '')
    $heading = [regex]::Replace($heading, '!?\[(?<label>[^\]]+)\]\([^)]+\)', '${label}')
    $heading = $heading -replace '[*_~`]', ''
    $slug = $heading.ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^\p{L}\p{Nd}\s_-]', '')
    $slug = [regex]::Replace($slug, '\s+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
      continue
    }

    $count = if ($headingCounts.ContainsKey($slug)) { [int]$headingCounts[$slug] } else { 0 }
    $anchor = if ($count -eq 0) { $slug } else { "$slug-$count" }
    $headingCounts[$slug] = $count + 1
    [void]$anchors.Add($anchor)
  }

  return $anchors
}

function Test-MarkdownFragmentExists {
  param(
    [Parameter(Mandatory)][object[]]$Anchors,
    [Parameter(Mandatory)][string]$Fragment
  )

  if ($Fragment.StartsWith('user-content-', [StringComparison]::OrdinalIgnoreCase)) {
    $Fragment = $Fragment.Substring('user-content-'.Length)
  }
  return $Anchors -contains $Fragment
}

function Resolve-MarkdownTargetPath {
  param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][AllowEmptyString()][string]$TargetPath,
    [Parameter(Mandatory)][string]$RootPath
  )

  if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    return Join-Path $RootPath $SourcePath
  }
  $baseDirectory = Split-Path (Join-Path $RootPath $SourcePath) -Parent
  return [IO.Path]::GetFullPath((Join-Path $baseDirectory $TargetPath))
}

function Get-MarkdownLinkFailures {
  param(
    [Parameter(Mandatory)][string]$RootPath,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
    [Parameter(Mandatory)][hashtable]$AnchorCache
  )

  $findings = [System.Collections.Generic.List[object]]::new()
  $rootPrefix = $RootPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  $inlineLinkPattern = '!?\[[^\]]+\]\((?<target><[^>]+>|[^)\s]+)(?:\s+["''][^"'']*["''])?\)'
  $referenceLinkPattern = '^\s*\[[^\]]+\]:\s*(?<target><[^>]+>|\S+)'
  for ($index = 0; $index -lt $Lines.Count; $index++) {
    $matches = @([regex]::Matches($Lines[$index], $inlineLinkPattern))
    $referenceMatch = [regex]::Match($Lines[$index], $referenceLinkPattern)
    if ($referenceMatch.Success) {
      $matches += $referenceMatch
    }
    foreach ($match in $matches) {
      $target = $match.Groups['target'].Value.Trim('<', '>')
      if ($target -match '^(?:https?|mailto):') {
        continue
      }
      $targetParts = $target -split '#', 2
      $targetPath = [Uri]::UnescapeDataString(($targetParts[0] -split '\?', 2)[0])
      $fragment = if ($targetParts.Count -eq 2) {
        [Uri]::UnescapeDataString($targetParts[1])
      } else {
        ''
      }
      if ([IO.Path]::IsPathRooted($targetPath)) {
        $findings.Add([pscustomobject]@{
            Rule = 'Markdown local link is not relative'
            Path = $SourcePath
            Line = $index + 1
          })
        continue
      }
      $resolvedTarget = Resolve-MarkdownTargetPath `
        -SourcePath $SourcePath `
        -TargetPath $targetPath `
        -RootPath $RootPath
      if (-not $resolvedTarget.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $resolvedTarget)) {
        $findings.Add([pscustomobject]@{
            Rule = 'Markdown relative link does not resolve inside the repository'
            Path = $SourcePath
            Line = $index + 1
          })
        continue
      }

      if (-not [string]::IsNullOrWhiteSpace($fragment) -and
        [IO.Path]::GetExtension($resolvedTarget) -ieq '.md') {
        if (-not $AnchorCache.ContainsKey($resolvedTarget)) {
          $targetLines = @((Get-Content -LiteralPath $resolvedTarget -Raw) -split "`r?`n")
          $AnchorCache[$resolvedTarget] = @(Get-MarkdownAnchors -Lines $targetLines)
        }
        if (-not (Test-MarkdownFragmentExists -Anchors $AnchorCache[$resolvedTarget] -Fragment $fragment)) {
          $findings.Add([pscustomobject]@{
              Rule = 'Markdown local link fragment does not match a heading or explicit ID'
              Path = $SourcePath
              Line = $index + 1
            })
        }
      }
    }
  }

  return $findings
}

function Test-DeclaredDependencyRestore {
  param([Parameter(Mandatory)][string]$Workflow)

  $pipInstalls = @([regex]::Matches(
      $Workflow,
      '(?im)^[ \t]*python[ \t]+-m[ \t]+pip[ \t]+install[ \t]+[^\r\n]*\r?$'
    ))
  return (
    $pipInstalls.Count -eq 1 -and
    $pipInstalls[0].Value -match '--requirement\s+\./langgraph-agent-local/requirements\.txt\s*$'
  )
}

function Test-CheckoutCredentialsDisabled {
  param([Parameter(Mandatory)][string]$Workflow)

  $checkoutStep = [regex]::Match(
    $Workflow,
    '(?ms)^\s{6}- name:\s*Check out repository\s*\r?\n(?<body>.*?)(?=^\s{6}- name:|\z)'
  )
  if (-not $checkoutStep.Success) {
    return $false
  }

  $body = $checkoutStep.Groups['body'].Value
  $persistSettings = @([regex]::Matches($body, '(?im)^\s*persist-credentials\s*:\s*(?<value>\S+)\s*$'))
  return (
    $body -match '(?im)^\s*uses:\s*actions/checkout@[0-9a-f]{40}\s*$' -and
    $body -match '(?im)^\s*with:\s*$' -and
    $persistSettings.Count -eq 1 -and
    $persistSettings[0].Groups['value'].Value -ceq 'false'
  )
}

function Test-DependencyValidationOrder {
  param([Parameter(Mandatory)][string]$Workflow)

  $selfTestIndex = $Workflow.IndexOf(
    'Test-DependencyManifest.ps1 -SelfTest',
    [StringComparison]::Ordinal
  )
  $validationIndex = $Workflow.IndexOf(
    'Test-DependencyManifest.ps1 -ManifestPath ./langgraph-agent-local/requirements.txt',
    [StringComparison]::Ordinal
  )
  $bicepInstallIndex = $Workflow.IndexOf('az bicep install', [StringComparison]::Ordinal)
  $pipInstallIndex = $Workflow.IndexOf('python -m pip install', [StringComparison]::Ordinal)

  return (
    $selfTestIndex -ge 0 -and
    $validationIndex -gt $selfTestIndex -and
    $bicepInstallIndex -gt $validationIndex -and
    $pipInstallIndex -gt $validationIndex
  )
}

function Test-IsBoundedRequirement {
  param([Parameter(Mandatory)][string]$Requirement)
  return $Requirement -match '^[A-Za-z0-9_.-]+(?:\[[A-Za-z0-9_,.-]+\])?(?:==[^,;\s]+|>=[^,;\s]+,<[^,;\s]+)$'
}

function Test-IsSafePlaceholderValue {
  param([Parameter(Mandatory)][string]$Value)

  return $Value -match (
    '^(?i:your-placeholder-token|replace-me|example-only|not-a-real-secret|' +
    '<[A-Z][A-Z0-9_-]*>)$'
  )
}

function Test-IsSensitiveBicepName {
  param([Parameter(Mandatory)][string]$Name)

  $normalizedName = [regex]::Replace($Name, '[^A-Za-z0-9]', '').ToLowerInvariant()
  return $normalizedName -match (
    '(?:clientsecret|password|apikey|accesstoken|authtoken|secretkey|' +
    'privatekey|credential|secret|token)$'
  )
}

function Test-IsSafeSecureBicepDefault {
  param(
    [Parameter(Mandatory)][string]$Type,
    [Parameter(Mandatory)][string]$Value
  )

  $normalizedValue = [regex]::Replace($Value, '//.*$', '').Trim()
  if ($Type -ieq 'string' -and $normalizedValue -match '^(?:''''|"")$') {
    return $true
  }
  if ($Type -ieq 'object' -and $normalizedValue -match '^\{\s*\}$') {
    return $true
  }
  return $false
}

function Get-SecretFindings {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Text
  )

  $findings = [System.Collections.Generic.List[object]]::new()
  foreach ($secretPattern in $script:secretPatterns) {
    foreach ($match in [regex]::Matches($Text, $secretPattern.Pattern)) {
      $findings.Add([pscustomobject]@{ Name = $secretPattern.Name; Match = $match })
    }
  }

  if ($Path -match '(?i)\.bicep(?:param)?$') {
    $secureParameterPattern = (
      '(?im)^[ \t]*@secure\(\)[ \t]*\r?\n' +
      '(?:(?:[ \t]*@[^\r\n]+|[ \t]*//[^\r\n]*|[ \t]*)\r?\n)*' +
      '[ \t]*param[ \t]+(?<name>[A-Za-z_][A-Za-z0-9_]*)[ \t]+' +
      '(?<type>string|object)(?<nullable>\?)?[ \t]*' +
      '(?:=[ \t]*(?<value>[^\r\n]*))?'
    )
    $secureParameterMatches = @([regex]::Matches($Text, $secureParameterPattern))
    foreach ($match in $secureParameterMatches) {
      if (-not $match.Groups['value'].Success) {
        continue
      }
      if (Test-IsSafeSecureBicepDefault `
          -Type $match.Groups['type'].Value `
          -Value $match.Groups['value'].Value) {
        continue
      }
      $findings.Add([pscustomobject]@{ Name = 'Bicep secure parameter default'; Match = $match })
    }

    $typedParameterPattern = (
      '(?im)^\s*param\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s+' +
      'string\s*=\s*[''"](?<value>[^''"\r\n]+)[''"]'
    )
    foreach ($match in [regex]::Matches($Text, $typedParameterPattern)) {
      $isSecureParameter = $false
      foreach ($secureMatch in $secureParameterMatches) {
        if ($match.Index -ge $secureMatch.Index -and
            $match.Index -lt ($secureMatch.Index + $secureMatch.Length)) {
          $isSecureParameter = $true
          break
        }
      }
      if ($isSecureParameter) {
        continue
      }

      $name = $match.Groups['name'].Value
      $value = $match.Groups['value'].Value
      if (-not (Test-IsSensitiveBicepName -Name $name)) {
        continue
      }
      if ((Test-IsSafeExamplePath -Path $Path) -and (Test-IsSafePlaceholderValue -Value $value)) {
        continue
      }
      $findings.Add([pscustomobject]@{ Name = 'Bicep typed parameter credential literal'; Match = $match })
    }

    $literalPattern = '(?im)\b(?<name>[A-Za-z_][A-Za-z0-9_-]*)\b\s*[:=]\s*[''"](?<value>[^''"\r\n]+)[''"]'
    foreach ($match in [regex]::Matches($Text, $literalPattern)) {
      if (-not (Test-IsSensitiveBicepName -Name $match.Groups['name'].Value)) {
        continue
      }
      $value = $match.Groups['value'].Value
      if ((Test-IsSafeExamplePath -Path $Path) -and (Test-IsSafePlaceholderValue -Value $value)) {
        continue
      }
      $findings.Add([pscustomobject]@{ Name = 'Bicep credential literal'; Match = $match })
    }
  }

  return $findings
}

function Assert-SelfTest {
  param(
    [Parameter(Mandatory)][bool]$Condition,
    [Parameter(Mandatory)][string]$Name
  )

  if (-not $Condition) {
    throw "Repository hygiene self-test failed: $Name"
  }
  $script:selfTestCount++
}

function Assert-BicepFixtureBuilds {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Source
  )

  $bicepExecutableName = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
  $bicepPath = Join-Path $HOME ".azure\bin\$bicepExecutableName"
  if (-not (Test-Path -LiteralPath $bicepPath -PathType Leaf)) {
    throw "Pinned Bicep executable was not found at $bicepPath."
  }

  $fixtureId = [guid]::NewGuid().ToString('N')
  $fixturePath = Join-Path ([IO.Path]::GetTempPath()) "public-repository-$fixtureId.bicep"
  $outputPath = Join-Path ([IO.Path]::GetTempPath()) "public-repository-$fixtureId.json"
  try {
    [IO.File]::WriteAllText($fixturePath, $Source, [Text.UTF8Encoding]::new($false))
    & $bicepPath build $fixturePath --outfile $outputPath *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "Repository hygiene Bicep fixture failed to compile: $Name"
    }
    $script:bicepFixtureBuildCount++
  } finally {
    Remove-Item -LiteralPath $fixturePath, $outputPath -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-RuleSelfTests {
  $script:selfTestCount = 0
  $script:bicepFixtureBuildCount = 0
  $files = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  [void]$files.Add('infra/main.bicep')
  [void]$files.Add('infra/resources.bicep')

  Assert-SelfTest (Test-IsGeneratedArtifactPath -Path 'infra/main.json' -PublicFileSet $files) 'main Bicep output is rejected'
  Assert-SelfTest (Test-IsGeneratedArtifactPath -Path 'infra/resources.json' -PublicFileSet $files) 'sibling Bicep JSON output is rejected'
  Assert-SelfTest (-not (Test-IsGeneratedArtifactPath -Path 'infra/tests/fixtures/source.json' -PublicFileSet $files)) 'intentional JSON fixture is allowed'
  foreach ($packagePath in @(
      'release/package.tar.gz'
      'release/package.tgz'
      'release/package.7z'
      'release/package.whl'
      'release/package.nupkg'
    )) {
    Assert-SelfTest (Test-IsGeneratedArtifactPath -Path $packagePath -PublicFileSet $files) "$packagePath is rejected"
  }

  Assert-SelfTest (Test-IsPublicTextPath -Path 'langgraph-agent-hosted-foundry/.agentignore') 'tracked .agentignore is scanned as text'
  $fineGrainedToken = 'github_' + 'pat_' + ('A' * 70)
  Assert-SelfTest (@(Get-SecretFindings -Path 'langgraph-agent-hosted-foundry/.agentignore' -Text $fineGrainedToken).Count -eq 1) 'fine-grained GitHub token is rejected'
  Assert-SelfTest (@(Get-SecretFindings -Path 'infra/main.bicep' -Text "clientSecret: 'actual-secret-value'").Count -eq 1) 'Bicep clientSecret literal is rejected'
  Assert-SelfTest (@(Get-SecretFindings -Path 'infra/main.bicep' -Text "clientSecret: 'your-placeholder-token'").Count -eq 1) 'placeholder is rejected in arbitrary Bicep source'
  Assert-SelfTest (@(Get-SecretFindings -Path 'infra/example/template.bicep' -Text "clientSecret: 'your-placeholder-token'").Count -eq 0) 'documented placeholder is allowed in a safe template'
  Assert-SelfTest (@(Get-SecretFindings -Path 'infra/main.bicep' -Text "param clientSecret string = 'actual-secret-value'").Count -eq 1) 'typed Bicep clientSecret literal is rejected'
  Assert-SelfTest (@(Get-SecretFindings -Path 'infra/main.bicep' -Text "param servicePassword string = 'actual-secret-value'").Count -eq 1) 'equivalent sensitive Bicep parameter name is rejected'
  Assert-SelfTest (@(Get-SecretFindings -Path 'infra/main.bicep' -Text "param clientSecret string = '<CLIENT_SECRET>'").Count -eq 1) 'typed placeholder is rejected in arbitrary Bicep source'
  Assert-SelfTest (@(Get-SecretFindings -Path 'infra/example/template.bicep' -Text "param clientSecret string = '<CLIENT_SECRET>'").Count -eq 0) 'typed placeholder is allowed in a safe template'

  $bicepSecretFixtures = @(
    @{
      Name = 'secure string without a default'
      Source = "@secure()`nparam credential string"
      ExpectedFindings = 0
    }
    @{
      Name = 'secure string with a sensitive name and literal default'
      Source = "@secure()`nparam credential string = 'actual-secret-value'"
      ExpectedFindings = 1
    }
    @{
      Name = 'secure string with a non-sensitive name and literal default'
      Source = "@secure()`nparam displayName string = 'actual-secret-value'"
      ExpectedFindings = 1
    }
    @{
      Name = 'secure string with a generated default'
      Source = "@secure()`nparam generatedValue string = newGuid()"
      ExpectedFindings = 1
    }
    @{
      Name = 'secure object with a literal default'
      Source = "@secure()`nparam configuration object = {`n  label: 'actual-secret-value'`n}"
      ExpectedFindings = 1
    }
    @{
      Name = 'secure string with an empty default'
      Source = "@secure()`nparam credential string = ''"
      ExpectedFindings = 0
    }
    @{
      Name = 'secure object with an empty default'
      Source = "@secure()`nparam configuration object = {}"
      ExpectedFindings = 0
    }
  )
  foreach ($fixture in $bicepSecretFixtures) {
    Assert-BicepFixtureBuilds -Name $fixture.Name -Source $fixture.Source
  }
  foreach ($fixture in $bicepSecretFixtures) {
    $findingCount = @(Get-SecretFindings -Path 'infra/main.bicep' -Text $fixture.Source).Count
    Assert-SelfTest ($findingCount -eq $fixture.ExpectedFindings) $fixture.Name
  }

  $brandingFixtures = @(
    'Navy-Federal Credit Union' # hygiene-self-test-fixture
    'navy federal credit union' # hygiene-self-test-fixture
    'NAVY...FEDERAL   CREDIT-UNION' # hygiene-self-test-fixture
    'N-F-C-U' # hygiene-self-test-fixture
  )
  foreach ($brandingFixture in $brandingFixtures) {
    Assert-SelfTest ($brandingFixture -match $script:customerPattern) "branding variant '$brandingFixture' is rejected"
  }
  Assert-SelfTest ('naval credit cooperative' -notmatch $script:customerPattern) 'unrelated organization text is allowed'

  $sameFileLines = @(
    '# Same-file source'
    ''
    '[Jump](#install-run)'
    ''
    '## Install & Run'
    '## Duplicate'
    '## Duplicate'
    '<a id="explicit-id"></a>'
    '### Custom heading {#custom-id}'
  )
  $anchors = Get-MarkdownAnchors -Lines $sameFileLines
  foreach ($anchor in @('install-run', 'duplicate', 'duplicate-1', 'explicit-id', 'custom-id')) {
    Assert-SelfTest ($anchors.Contains($anchor)) "Markdown anchor '$anchor' is recognized"
  }
  $crossFileSourceLines = @(
    '# Cross-file source'
    ''
    '[Details](target.md#detailed-steps)'
  )
  $crossFileTargetLines = @(
    '# Cross-file target'
    ''
    '## Detailed steps'
    ''
  )
  $brokenAnchorLines = @(
    '# Broken-anchor source'
    ''
    '[Broken](#broken-anchor)'
  )
  $markdownFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "public-repository-markdown-$([guid]::NewGuid().ToString('N'))"
  try {
    $markdownFixtureDocs = Join-Path $markdownFixtureRoot 'docs'
    [void](New-Item -ItemType Directory -Path $markdownFixtureDocs -Force)
    [IO.File]::WriteAllLines(
      (Join-Path $markdownFixtureRoot 'same-file.md'),
      [string[]]$sameFileLines,
      [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllLines(
      (Join-Path $markdownFixtureDocs 'cross-file.md'),
      [string[]]$crossFileSourceLines,
      [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllLines(
      (Join-Path $markdownFixtureDocs 'target.md'),
      [string[]]$crossFileTargetLines,
      [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllLines(
      (Join-Path $markdownFixtureRoot 'broken.md'),
      [string[]]$brokenAnchorLines,
      [Text.UTF8Encoding]::new($false)
    )

    $markdownFixtureAnchorCache = @{}
    $sameFileFindings = @(Get-MarkdownLinkFailures `
        -RootPath $markdownFixtureRoot `
        -SourcePath 'same-file.md' `
        -Lines $sameFileLines `
        -AnchorCache $markdownFixtureAnchorCache)
    Assert-SelfTest ($sameFileFindings.Count -eq 0) 'same-file Markdown fragment link with blank lines is accepted by the repository probe'
    $crossFileFindings = @(Get-MarkdownLinkFailures `
        -RootPath $markdownFixtureRoot `
        -SourcePath 'docs/cross-file.md' `
        -Lines $crossFileSourceLines `
        -AnchorCache $markdownFixtureAnchorCache)
    Assert-SelfTest ($crossFileFindings.Count -eq 0) 'cross-file Markdown fragment link with blank lines is accepted by the repository probe'
    $brokenAnchorFindings = @(Get-MarkdownLinkFailures `
        -RootPath $markdownFixtureRoot `
        -SourcePath 'broken.md' `
        -Lines $brokenAnchorLines `
        -AnchorCache $markdownFixtureAnchorCache)
    Assert-SelfTest (
      $brokenAnchorFindings.Count -eq 1 -and
      $brokenAnchorFindings[0].Rule -eq 'Markdown local link fragment does not match a heading or explicit ID' -and
      $brokenAnchorFindings[0].Path -eq 'broken.md' -and
      $brokenAnchorFindings[0].Line -eq 3
    ) 'broken Markdown fragment link is detected by the repository probe'
  } finally {
    Remove-Item -LiteralPath $markdownFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  $nullMarkdownContentRejected = $false
  try {
    [void](Get-MarkdownAnchors -Lines $null)
  } catch {
    $nullMarkdownContentRejected = $true
  }
  Assert-SelfTest $nullMarkdownContentRejected 'null Markdown content is rejected'

  $validRestore = @'
steps:
  - run: |
      python -m pip install --disable-pip-version-check --requirement ./langgraph-agent-local/requirements.txt
'@
  $invalidRestore = @'
steps:
  - run: |
      python -m pip install httpx
'@
  Assert-SelfTest (Test-DeclaredDependencyRestore -Workflow $validRestore) 'declared dependency restore is accepted'
  Assert-SelfTest (-not (Test-DeclaredDependencyRestore -Workflow $invalidRestore)) 'ad hoc dependency install is rejected'
  Assert-SelfTest (Test-IsBoundedRequirement -Requirement 'httpx==0.28.1') 'exact dependency pin is accepted'
  Assert-SelfTest (Test-IsBoundedRequirement -Requirement 'azure-search-documents>=12.0.0,<13.0.0') 'two-sided dependency bound is accepted'
  Assert-SelfTest (-not (Test-IsBoundedRequirement -Requirement 'httpx>=0.28.0')) 'unbounded dependency range is rejected'

  $validWorkflow = @'
      - name: Check out repository
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          persist-credentials: false
      - name: Validate dependencies
        run: |
          pwsh -File ./scripts/ci/Test-DependencyManifest.ps1 -SelfTest
          pwsh -File ./scripts/ci/Test-DependencyManifest.ps1 -ManifestPath ./langgraph-agent-local/requirements.txt
      - name: Install Bicep
        run: az bicep install
      - name: Restore dependencies
        run: python -m pip install
'@
  Assert-SelfTest (Test-CheckoutCredentialsDisabled -Workflow $validWorkflow) 'checkout credential persistence is explicitly disabled'
  Assert-SelfTest (-not (Test-CheckoutCredentialsDisabled -Workflow ($validWorkflow -replace '(?m)^\s*persist-credentials: false\s*\r?\n', ''))) 'missing checkout credential setting is rejected'
  Assert-SelfTest (-not (Test-CheckoutCredentialsDisabled -Workflow ($validWorkflow -replace 'persist-credentials: false', 'persist-credentials: true'))) 'enabled checkout credential persistence is rejected'
  Assert-SelfTest (Test-DependencyValidationOrder -Workflow $validWorkflow) 'dependency validation precedes all installs'
  $invalidWorkflowOrder = $validWorkflow -replace (
    '(?ms)(\s+- name: Validate dependencies.*?)(?=\s+- name: Install Bicep)',
    ''
  )
  $invalidWorkflowOrder += @'
      - name: Late validation
        run: |
          pwsh -File ./scripts/ci/Test-DependencyManifest.ps1 -SelfTest
          pwsh -File ./scripts/ci/Test-DependencyManifest.ps1 -ManifestPath ./langgraph-agent-local/requirements.txt
'@
  Assert-SelfTest (-not (Test-DependencyValidationOrder -Workflow $invalidWorkflowOrder)) 'dependency validation after install is rejected'

  Write-Host "PASS: $bicepFixtureBuildCount Bicep fixtures compiled before $selfTestCount repository hygiene negative/self-test probes."
}

$allowedEnvironmentFiles = @(
  '.env.example'
  'langgraph-agent-local/.env.example'
)
$textExtensions = @(
  '.bicep', '.bicepparam', '.cfg', '.ini', '.json', '.md', '.ps1', '.psm1',
  '.py', '.sh', '.toml', '.txt', '.yaml', '.yml'
)
$textNames = @('.agentignore', '.gitignore', 'LICENSE')
$generatedFilePattern = (
  '(?i)(?:\.bicep\.json|\.bicepparam\.json|\.arm\.json|\.parameters\.json|' +
  '\.whatif|\.what-if\.json|\.log|\.trace|\.py[co]|\.zip|\.dll|\.exe|\.pdb|' +
  '\.tar\.gz|\.tgz|\.7z|\.whl|\.nupkg)$|' +
  '^infra/(?:out|generated)/|^infra/custom-search-pipeline\.json$'
)
$customerPattern = '(?i)\bN[\W_]*F[\W_]*C[\W_]*U\b|Navy[\s\p{P}_]*Federal(?:[\s\p{P}_]*Credit[\s\p{P}_]*Union)?|REDMOND\\[A-Za-z0-9._-]+'
$secretPatterns = @(
  @{ Name = 'private key material'; Pattern = ('-----BEGIN ' + '(?:RSA |EC |OPENSSH )?PRIVATE KEY-----') }
  @{ Name = 'JWT'; Pattern = '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b' }
  @{ Name = 'AWS access key'; Pattern = '\bAKIA[0-9A-Z]{16}\b' }
  @{ Name = 'GitHub token'; Pattern = '\bgh[pousr]_[A-Za-z0-9]{30,}\b' }
  @{ Name = 'GitHub fine-grained token'; Pattern = '\bgithub_pat_[A-Za-z0-9_]{60,}\b' }
  @{ Name = 'Google API key'; Pattern = '\bAIza[0-9A-Za-z_-]{30,}\b' }
  @{ Name = 'OpenAI-style key'; Pattern = '\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b' }
  @{ Name = 'credential-bearing connection string'; Pattern = '(?i)(?:Server|Host)=[^;\r\n]+;[^\r\n]*(?:Password|Pwd)=[^;<\r\n]+' }
  @{ Name = 'storage account key'; Pattern = '(?i)\bAccountKey=[A-Za-z0-9+/=]{40,}' }
  @{
    Name = 'assigned credential'
    Pattern = '(?im)^\s*(?:export\s+|\$env:)?[A-Z][A-Z0-9_]*(?:PASSWORD|TOKEN|SECRET|API_KEY|ACCESS_KEY)\s*=\s*[''"]?(?!<|\$\{|replace|example|fake|synthetic|redacted|\*{3,})[A-Za-z0-9+/=_.-]{16,}'
  }
)

if ($SelfTest) {
  Invoke-RuleSelfTests
  return
}

$publicFiles = Get-PublicFiles
if ($publicFiles.Count -eq 0) {
  throw 'No public repository files were found.'
}
$publicFileSet = [System.Collections.Generic.HashSet[string]]::new(
  [string[]]$publicFiles,
  [StringComparer]::OrdinalIgnoreCase
)

$before = $failures.Count
$forbiddenPathPattern = (
  '(^|/)(?:\.squad|\.copilot|\.azure|\.azd|\.tmp-deploy|\.vscode|\.idea|config|' +
  'deployment-output|what-if|captures|responses|logs|__pycache__|\.pytest_cache|' +
  '\.mypy_cache|\.pyright|\.ruff_cache|\.hypothesis|\.tox|\.nox|\.venv|venv|env|' +
  'build|dist|htmlcov|video-test)(?:/|$)'
)
$forbiddenSquadPattern = (
  '^\.github/(?:agents/squad\.agent\.md|copilot-instructions\.md|skills/|' +
  'workflows/(?:squad-.*\.ya?ml|sync-squad-labels\.ya?ml))'
)
foreach ($path in $publicFiles) {
  if ($path -match '(^|/)\.env(?:\..+)?$' -and $path -notin $allowedEnvironmentFiles) {
    Add-Failure -Rule 'Non-example environment file is public' -Path $path
  }
  if ($path -match $forbiddenPathPattern -or $path -match $forbiddenSquadPattern) {
    Add-Failure -Rule 'Private or local-only path is public' -Path $path
  }
  if (Test-IsGeneratedArtifactPath -Path $path -PublicFileSet $publicFileSet) {
    Add-Failure -Rule 'Generated, compiled, captured, cached, or log artifact is public' -Path $path
  }
}
Complete-Gate -Name 'public paths exclude private state, environment files, caches, captures, logs, and compiled artifacts' -StartingFailureCount $before

$before = $failures.Count
$expectedSampleDataFiles = @(
  'sample-data/documents/COMP-CHUNKLAB-303-synthetic-network-rules.md'
  'sample-data/documents/PROC-CHUNKLAB-101-synthetic-duplicate-intake.md'
  'sample-data/documents/RUN-CHUNKLAB-202-synthetic-fraud-escalation.md'
  'sample-data/evaluation-queries.json'
)
$actualSampleDataFiles = @($publicFiles | Where-Object { $_ -like 'sample-data/*' })
foreach ($path in $expectedSampleDataFiles) {
  if ($path -notin $actualSampleDataFiles) {
    Add-Failure -Rule 'Required customer-facing sample-data file is missing' -Path $path
  }
}
foreach ($path in $actualSampleDataFiles) {
  if ($path -notin $expectedSampleDataFiles) {
    Add-Failure -Rule 'Unexpected file exists outside the sample-data allowlist' -Path $path
  }
}
$retiredTopLevelPaths = @(
  ('retrieval' + '-api')
  ('test-data' + '-blob-only')
  'shared'
)
$retiredDuplicatePages = @(
  'docs/deploy/prerequisites.md'
  'docs/deploy/powershell.md'
  'docs/deploy/verify.md'
  'docs/operations/cleanup.md'
  'scripts/README.md'
)
foreach ($path in $publicFiles) {
  if (($path -split '/', 2)[0] -in $retiredTopLevelPaths) {
    Add-Failure -Rule 'Retired public surface is present' -Path $path
  }
  if ($path -in $retiredDuplicatePages) {
    Add-Failure -Rule 'Deleted duplicate documentation page is present' -Path $path
  }
}
$retiredPageReferencePattern = '(?:' + (($retiredDuplicatePages | ForEach-Object {
        [regex]::Escape($_)
      }) -join '|') + ')'
foreach ($path in @($publicFiles | Where-Object {
      $_ -ne 'scripts/ci/Test-PublicRepository.ps1' -and (Test-IsPublicTextPath -Path $_)
    })) {
  $lines = @(Get-TextLines -Path $path)
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match $retiredPageReferencePattern) {
      Add-Failure -Rule 'Deleted duplicate documentation page is still referenced' -Path $path -Line ($index + 1)
    }
  }
}
Complete-Gate -Name 'customer-facing sample-data layout matches the supported file allowlist and retired duplicate documentation pages stay absent and unreferenced' -StartingFailureCount $before

$before = $failures.Count
$gitignore = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.gitignore') -Raw
foreach ($requiredIgnore in @(
    '**/.env'
    '**/.env.*'
    '*.bicep.json'
    '*.bicepparam.json'
    '*.arm.json'
    'infra/main.json'
    'infra/out/'
    'infra/generated/'
    '*.tar.gz'
    '*.tgz'
    '*.7z'
    '*.whl'
    '*.nupkg'
    '*.log'
    'captures/'
    'responses/'
    '.pytest_cache/'
    '.venv/'
    '.squad/'
    '.github/workflows/squad-*.yml'
  )) {
  if (-not $gitignore.Contains($requiredIgnore)) {
    Add-Failure -Rule "Generated-artifact ignore policy is missing '$requiredIgnore'" -Path '.gitignore'
  }
}
$contributing = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'CONTRIBUTING.md') -Raw
if ($contributing -notmatch '(?i)do not commit generated Bicep or ARM output') {
  Add-Failure -Rule 'Contributing guide does not state the generated-artifact policy' -Path 'CONTRIBUTING.md'
}
Complete-Gate -Name 'generated-artifact policy is explicit and enforced by ignore rules' -StartingFailureCount $before

$textFiles = @($publicFiles | Where-Object { Test-IsPublicTextPath -Path $_ })

$before = $failures.Count
$personalPathPattern = '(?i)[A-Z]:\\Users\\[A-Za-z0-9._-]+|/Users/[A-Za-z0-9._-]+|/home/(?!runner(?:/|$))[A-Za-z0-9._-]+'
foreach ($path in $textFiles) {
  $lines = @(Get-TextLines -Path $path)
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($path -eq 'scripts/ci/Test-PublicRepository.ps1' -and
      $lines[$index] -match '# hygiene-self-test-fixture\s*$') {
      continue
    }
    if ($lines[$index] -match $customerPattern) {
      Add-Failure -Rule 'Customer branding appears in public text' -Path $path -Line ($index + 1)
    }
    if ($lines[$index] -match $personalPathPattern) {
      Add-Failure -Rule 'Personal or machine-specific path appears in public text' -Path $path -Line ($index + 1)
    }
  }
}
Complete-Gate -Name 'public text is customer-neutral and contains no personal machine paths' -StartingFailureCount $before

$before = $failures.Count
$knownPublicIdentifiers = [System.Collections.Generic.HashSet[string]]::new(
  [string[]]@(
    '00000000-0000-0000-0000-000000000000'
    '00000003-0000-0000-c000-000000000000'
    '00000003-0000-0ff1-ce00-000000000000'
    '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
    '1407120a-92aa-4202-b7e9-c0e197c71c8f'
    '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
    '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
    '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
    'a97b65f3-24c7-4388-baec-2e87135dc908'
    'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
    'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  ),
  [StringComparer]::OrdinalIgnoreCase
)
$syntheticIdentifierFiles = @(
  'infra/tests/Quickstart.TestFixture.ps1'
  'infra/tests/Test-QuickstartMutation.ps1'
  'infra/tests/fixtures/tenant-parity.synthetic.json'
)
$guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
foreach ($path in $textFiles) {
  $lines = @(Get-TextLines -Path $path)
  for ($index = 0; $index -lt $lines.Count; $index++) {
    foreach ($match in [regex]::Matches($lines[$index], $guidPattern)) {
      if ($path -notin $syntheticIdentifierFiles -and -not $knownPublicIdentifiers.Contains($match.Value)) {
        Add-Failure -Rule 'Non-allowlisted GUID-shaped identifier appears in public text' -Path $path -Line ($index + 1)
      }
    }
  }
}
Complete-Gate -Name 'GUID-shaped identifiers are limited to public platform IDs and explicit synthetic fixtures' -StartingFailureCount $before

$before = $failures.Count
$markdownFiles = @($publicFiles | Where-Object { $_ -like '*.md' })
$markdownAnchorCache = @{}
foreach ($path in $markdownFiles) {
  $lines = @(Get-TextLines -Path $path)
  foreach ($finding in @(Get-MarkdownLinkFailures `
        -RootPath $RepositoryRoot `
        -SourcePath $path `
        -Lines $lines `
        -AnchorCache $markdownAnchorCache)) {
    Add-Failure -Rule $finding.Rule -Path $finding.Path -Line $finding.Line
  }
}
Complete-Gate -Name "$($markdownFiles.Count) Markdown files contain only resolving local relative links and fragments" -StartingFailureCount $before

$before = $failures.Count
$requiredSchemaFiles = @(
  'infra/main.bicep'
  'scripts/quickstart/Quickstart.Common.psm1'
  'scripts/quickstart/deploy.ps1'
  'infra/tests/Quickstart.TestFixture.ps1'
  'infra/tests/Test-PublicQuickstartContract.ps1'
  'infra/README.md'
  'docs/architecture.md'
  'docs/deploy/bicep.md'
  'docs/quickstart.md'
)
foreach ($path in $requiredSchemaFiles) {
  $text = Get-Content -LiteralPath (Join-Path $RepositoryRoot $path) -Raw
  if ($text -notmatch '\b3\.1\.0\b') {
    Add-Failure -Rule 'Quickstart schema 3.1.0 is missing from a contract surface' -Path $path
  }
}
$schemaAnchorPattern = '(?i)contractSchemaVersion|SupportedContractSchema|quickstart(?:Contract)?\.schemaVersion|quickstart contract schema'
foreach ($path in $textFiles) {
  $lines = @(Get-TextLines -Path $path)
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match $schemaAnchorPattern) {
      $versions = @([regex]::Matches($lines[$index], '\b\d+\.\d+\.\d+\b') | ForEach-Object Value)
      if ($versions.Count -eq 0) {
        continue
      }
      if ($path -eq 'scripts/quickstart/Quickstart.Common.psm1' -and $lines[$index] -match 'SupportedContractSchemas') {
        if (($versions -join ',') -cne '3.0.0,3.1.0') {
          Add-Failure -Rule 'Quickstart backward-compatible schema list differs from 3.0.0,3.1.0' -Path $path -Line ($index + 1)
        }
        continue
      }
      foreach ($version in $versions) {
        if ($version -ne '3.1.0') {
          Add-Failure -Rule 'Quickstart contract schema version differs from 3.1.0' -Path $path -Line ($index + 1)
        }
      }
    }
  }
}
Complete-Gate -Name 'quickstart contract surfaces consistently use schema 3.1.0 with guarded 3.0.0 resume compatibility' -StartingFailureCount $before

$before = $failures.Count
$wrapperRequirements = [ordered]@{
  'README.md' = 'wrapper is the only supported public deployment path'
  'infra/README.md' = 'Raw direct deployment is unsupported.'
  'docs/deploy/bicep.md' = ('Do not use a raw `az deployment sub ' + 'create` command.')
  'docs/quickstart.md' = 'The only supported deployment entrypoint is'
}
foreach ($entry in $wrapperRequirements.GetEnumerator()) {
  $text = Get-Content -LiteralPath (Join-Path $RepositoryRoot $entry.Key) -Raw
  if (-not $text.Contains($entry.Value)) {
    Add-Failure -Rule 'Wrapper-only deployment wording is missing or changed' -Path $entry.Key
  }
}
foreach ($path in @($publicFiles | Where-Object { $_ -like '*.ps1' })) {
  $lines = @(Get-TextLines -Path $path)
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match '(?i)\baz\s+deployment\s+(?:sub|group)\s+create\b' -and
      $path -ne 'scripts/quickstart/deploy.ps1') {
      Add-Failure -Rule 'Deployment command exists outside the guarded public wrapper' -Path $path -Line ($index + 1)
    }
  }
}
$negativeDeploymentReferences = @(
  'docs/deploy/bicep.md'
  'docs/quickstart.md'
)
foreach ($path in $markdownFiles) {
  $lines = @(Get-TextLines -Path $path)
  for ($index = 0; $index -lt $lines.Count; $index++) {
    $isNegativeDeploymentReference = (
      $path -in $negativeDeploymentReferences -and
      (
        $lines[$index] -match '(?i)\bdo not\b' -or
        ($index -gt 0 -and $lines[$index - 1] -match '(?i)\bdo not\s*$')
      )
    )
    if ($lines[$index] -match '(?i)\baz\s+deployment\s+(?:sub|group)\s+create\b' -and
      -not $isNegativeDeploymentReference) {
      Add-Failure -Rule 'Documentation exposes a raw deployment command instead of the guarded wrapper' -Path $path -Line ($index + 1)
    }
  }
}
Complete-Gate -Name 'deployment commands and documentation preserve the guarded wrapper-only boundary' -StartingFailureCount $before

$before = $failures.Count
foreach ($path in $textFiles) {
  $text = Get-Content -LiteralPath (Join-Path $RepositoryRoot $path) -Raw
  foreach ($finding in @(Get-SecretFindings -Path $path -Text $text)) {
    $line = ($text.Substring(0, $finding.Match.Index) -split "`n").Count
    Add-Failure -Rule "High-confidence secret pattern: $($finding.Name)" -Path $path -Line $line
  }
}
Complete-Gate -Name 'high-confidence secret scan found no credential material' -StartingFailureCount $before

$before = $failures.Count
$workflowPath = '.github/workflows/ci.yml'
$workflow = Get-Content -LiteralPath (Join-Path $RepositoryRoot $workflowPath) -Raw
$checkoutSha = '11bd71901bbe5b1630ceea73d27597364c9af683'
$requiredWorkflowPatterns = [ordered]@{
  'pull_request trigger' = '(?m)^\s{2}pull_request:\s*$'
  'push trigger' = '(?m)^\s{2}push:\s*$'
  'main branch trigger' = '(?m)^\s{6}- main\s*$'
  'least permissions' = '(?m)^permissions:\s*\r?\n\s{2}contents:\s+read\s*$'
  'concurrency cancellation' = '(?m)^\s{2}cancel-in-progress:\s+true\s*$'
  'Windows runner' = '(?m)^\s{4}runs-on:\s+windows-latest\s*$'
  'pinned Bicep install' = 'az bicep install --version v0\.47\.16'
  'dependency manifest validator self-test' = 'scripts/ci/Test-DependencyManifest\.ps1 -SelfTest'
  'dependency manifest validation' = 'scripts/ci/Test-DependencyManifest\.ps1 -ManifestPath \./langgraph-agent-local/requirements\.txt'
  'declared dependency restore' = 'python -m pip install --disable-pip-version-check --requirement \./langgraph-agent-local/requirements\.txt'
  'offline orchestrator' = 'scripts/ci/Invoke-PublicCI\.ps1'
}
foreach ($entry in $requiredWorkflowPatterns.GetEnumerator()) {
  if ($workflow -notmatch $entry.Value) {
    Add-Failure -Rule "Workflow is missing $($entry.Key)" -Path $workflowPath
  }
}
$uses = @([regex]::Matches($workflow, '(?im)^\s*uses:\s*(?<reference>[^\s#]+)'))
if ($uses.Count -ne 1 -or $uses[0].Groups['reference'].Value -cne "actions/checkout@$checkoutSha") {
  Add-Failure -Rule 'Workflow must use exactly one immutable SHA-pinned actions/checkout action' -Path $workflowPath
}
if (-not (Test-CheckoutCredentialsDisabled -Workflow $workflow)) {
  Add-Failure -Rule 'Workflow checkout must explicitly set persist-credentials to false' -Path $workflowPath
}
foreach ($use in $uses) {
  if ($use.Groups['reference'].Value -notmatch '@[0-9a-f]{40}$') {
    Add-Failure -Rule 'Workflow contains a mutable action reference' -Path $workflowPath
  }
}
if ($workflow -match '(?i)\$\{\{\s*secrets\.' -or $workflow -match '(?im)^\s*[A-Za-z-]+:\s*write\s*$') {
  Add-Failure -Rule 'Workflow requests secrets or write permissions' -Path $workflowPath
}
if ($workflow -match '(?i)azure/login@|\baz\s+login\b|\baz\s+deployment\b|scripts[/\\]quickstart[/\\]deploy\.ps1|Connect-AzAccount') {
  Add-Failure -Rule 'Workflow contains cloud login or deployment behavior' -Path $workflowPath
}
if ($workflow -match '(?im)(?:curl(?:\.exe)?|wget(?:\.exe)?|Invoke-WebRequest|Invoke-RestMethod)\b[^\r\n]*\|') {
  Add-Failure -Rule 'Workflow contains a shell download pipe' -Path $workflowPath
}
if (-not (Test-DeclaredDependencyRestore -Workflow $workflow)) {
  Add-Failure -Rule 'Workflow must restore only the declared local-agent requirements manifest' -Path $workflowPath
}
if (-not (Test-DependencyValidationOrder -Workflow $workflow)) {
  Add-Failure -Rule 'Workflow must validate and probe the dependency manifest before any install or restore' -Path $workflowPath
}

$localAgentRequirementsPath = 'langgraph-agent-local/requirements.txt'
$localAgentRequirements = Get-Content -LiteralPath (Join-Path $RepositoryRoot $localAgentRequirementsPath) -Raw
foreach ($requiredDependency in @(
    '(?m)^httpx==0\.28\.1\s*$'
    '(?m)^azure-search-documents>=12\.0\.0,<13\.0\.0\s*$'
  )) {
  if ($localAgentRequirements -notmatch $requiredDependency) {
    Add-Failure -Rule 'Local-agent dependency manifest lost an explicit compatible constraint' -Path $localAgentRequirementsPath
  }
}
foreach ($requirement in @($localAgentRequirements -split "`r?`n")) {
  $requirement = $requirement.Trim()
  if ([string]::IsNullOrWhiteSpace($requirement) -or $requirement.StartsWith('#')) {
    continue
  }
  if (-not (Test-IsBoundedRequirement -Requirement $requirement)) {
    Add-Failure -Rule 'Local-agent direct dependency is not exact or explicitly bounded' -Path $localAgentRequirementsPath
  }
}

$orchestratorPath = 'scripts/ci/Invoke-PublicCI.ps1'
$orchestrator = Get-Content -LiteralPath (Join-Path $RepositoryRoot $orchestratorPath) -Raw
foreach ($requiredGate in @(
    'Test-PublicQuickstartContract.ps1'
    'Test-QuickstartMutation.ps1'
    'Test-QuickstartAuthorization.ps1'
    'Test-InfraParity.ps1'
    'Test-OperationalScriptBoundary.ps1'
    'Test-TenantParity.ps1'
    'TestToolboxRecovery.ps1'
    'python -m unittest'
    'langgraph-agent-local/tests'
    'Test-DependencyManifest.ps1'
    '-SelfTest'
    'Test-PublicRepository.ps1'
  )) {
  if (-not $orchestrator.Contains($requiredGate)) {
    Add-Failure -Rule "Offline CI orchestration is missing '$requiredGate'" -Path $orchestratorPath
  }
}
Complete-Gate -Name 'workflow is least-privilege, immutable, credential-free, non-deploying, and structurally complete' -StartingFailureCount $before

if ($failures.Count -ne 0) {
  foreach ($failure in $failures) {
    $location = if ($failure.Line -gt 0) { "$($failure.Path):$($failure.Line)" } else { $failure.Path }
    Write-Error -ErrorAction Continue "FAIL [$($failure.Rule)] $location"
  }
  throw "$($failures.Count) public repository hygiene failure(s) found."
}

Write-Host "$passedGates repository hygiene gates passed across $($publicFiles.Count) public files; no secret values were printed."
