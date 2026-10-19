[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$targetScript = Join-Path $repoRoot 'scripts/maintenance/04-rewire-toolbox.ps1'
$checks = @{ Passed = 0 }
$fixture = @{
  AZURE_SUBSCRIPTION_ID = 'synthetic-sub'
  AZURE_RESOURCE_GROUP = 'synthetic-rg'
  AZURE_SEARCH_SERVICE = 'synthetic-search'
  AZURE_SEARCH_ENDPOINT = 'https://synthetic-search.search.windows.net'
  FOUNDRY_ACCOUNT_NAME = 'synthetic-account'
  FOUNDRY_PROJECT_NAME = 'synthetic-project'
  FOUNDRY_PROJECT_ENDPOINT = 'https://synthetic.invalid/api/projects/synthetic-project'
  FOUNDRY_TOOLBOX_NAME = 'synthetic-toolbox'
  FOUNDRY_KB_NAME = 'synthetic-kb'
  AISEARCH_CONNECTION_NAME = 'synthetic-bootstrap'
}
$searchId = '/subscriptions/synthetic-sub/resourceGroups/synthetic-rg/providers/Microsoft.Search/searchServices/synthetic-search'
$projectId = '/subscriptions/synthetic-sub/resourceGroups/synthetic-rg/providers/Microsoft.CognitiveServices/accounts/synthetic-account/projects/synthetic-project'
$savedEnvironment = @{}
foreach ($key in $fixture.Keys) { $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key) }
$savedExitCode = $global:LASTEXITCODE
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolbox-recovery-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$validConfigPath = Join-Path $tempRoot 'valid.env'
$partialConfigPath = Join-Path $tempRoot 'partial.env'
$malformedConfigPath = Join-Path $tempRoot 'malformed.env'
$missingConfigPath = Join-Path $tempRoot 'missing.env'
[IO.File]::WriteAllLines(
  $validConfigPath,
  @($fixture.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" })
)
[IO.File]::WriteAllLines(
  $partialConfigPath,
  @($fixture.GetEnumerator() | Where-Object Key -ne 'FOUNDRY_KB_NAME' | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" })
)
[IO.File]::WriteAllLines(
  $malformedConfigPath,
  @('AZURE_SUBSCRIPTION_ID=must-not-be-applied', 'not-valid-config')
)
foreach ($key in $fixture.Keys) { [Environment]::SetEnvironmentVariable($key, $fixture[$key], 'Process') }
$calls = [System.Collections.Generic.List[string]]::new()
$state = @{}

function Assert-Recovery {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    $state.MockError = $Message
    throw $Message
  }
  $checks.Passed++
  Write-Host "PASS: $Message"
}

function Set-Content {
  param([string]$Path, [string]$Value, [string]$Encoding)
  $calls.Add('yaml')
  $state.Yaml = $Value
}

function az {
  $command = $args -join ' '
  $global:LASTEXITCODE = 0
  switch -Regex ($command) {
    '^account set --subscription synthetic-sub --output none$' { $calls.Add('subscription'); return }
    '^search service show ' { $calls.Add('search'); return $searchId }
    '^rest --method GET .*--query \{id:id,identity:identity\}' {
      $calls.Add('identity')
      return (@{ id = $projectId; identity = @{ principalId = 'synthetic-mi' } } | ConvertTo-Json -Depth 5)
    }
    '^role assignment list ' {
      $calls.Add('rbac')
      return (ConvertTo-Json -InputObject @(@{
        principalId = 'synthetic-mi'; principalType = 'ServicePrincipal'; scope = $searchId
        roleDefinitionId = '/roleDefinitions/1407120a-92aa-4202-b7e9-c0e197c71c8f'; condition = $null
      }))
    }
    '^rest --method GET .*connections/synthetic-bootstrap\?' {
      $calls.Add('bootstrap')
      return (@{
        category = 'CognitiveSearch'; authType = 'AAD'; target = $fixture.AZURE_SEARCH_ENDPOINT
        isSharedToAll = $false; metadata = @{ ResourceId = $searchId; ApiType = 'Azure' }
      } | ConvertTo-Json -Depth 5)
    }
    '^account get-access-token --resource https://ai.azure.com --query accessToken -o tsv$' {
      $calls.Add('token'); return 'synthetic-token'
    }
    default {
      $state.MockError = "Unexpected az command in offline test: $command"
      throw $state.MockError
    }
  }
}

function azd {
  $command = $args -join ' '
  $operation = switch -Regex ($command) {
    '^ai project set https://synthetic.invalid/api/projects/synthetic-project$' { 'project'; break }
    '^ai toolbox list --output json$' { 'list-toolbox'; break }
    '^ai connection list --output json$' { 'list-connection'; break }
    '^ai toolbox delete synthetic-toolbox --force$' { 'delete-toolbox'; break }
    '^ai connection delete dispute-kb-mcp-conn --force$' { 'delete-connection'; break }
    '^ai connection create dispute-kb-mcp-conn ' { 'create-connection'; break }
    '^ai toolbox create synthetic-toolbox ' { 'create-toolbox'; break }
    default {
      $state.MockError = "Unexpected azd command in offline test: $command"
      throw $state.MockError
    }
  }
  $calls.Add($operation)
  $global:LASTEXITCODE = 0
  if ($state.FailAt -eq $operation -and -not $state.FailAfterMutation) {
    $global:LASTEXITCODE = 1
    Write-Error -Message $state.Stderr -ErrorAction Continue
    if ($state.Stdout) { Write-Output $state.Stdout }
    return
  }
  switch ($operation) {
    list-toolbox {
      if ($state.ContainsKey('ToolboxJson')) { return $state.ToolboxJson }
      $items = @(@{ name = 'unrelated-toolbox' })
      if ($state.Toolbox) { $items += @{ name = 'synthetic-toolbox' } }
      return (@{ toolboxes = $items } | ConvertTo-Json -Depth 5)
    }
    list-connection {
      if ($state.ContainsKey('ConnectionJson')) { return $state.ConnectionJson }
      $items = @(@{ name = 'synthetic-bootstrap' })
      if ($state.Connection) { $items += @{ name = 'dispute-kb-mcp-conn' } }
      return (ConvertTo-Json -InputObject $items)
    }
    delete-toolbox {
      if (-not $state.Toolbox) { throw 'Mock refuses deletion of absent toolbox.' }
      $state.Toolbox = $false
    }
    delete-connection {
      if (-not $state.Connection) { throw 'Mock refuses deletion of absent connection.' }
      $state.Connection = $false
    }
    create-connection {
      if ($state.Connection) { throw 'Mock refuses creation over existing connection.' }
      Assert-Recovery ($command -eq 'ai connection create dispute-kb-mcp-conn --kind remote-tool --target https://synthetic-search.search.windows.net/knowledgebases/synthetic-kb/mcp?api-version=2026-08-01-preview --auth-type user-entra-token --audience https://search.azure.com --no-prompt') 'Connection retains exact target and caller-token audience'
      $state.Connection = $true
    }
    create-toolbox {
      if ($state.Toolbox -or -not $state.Connection) { throw 'Mock refuses invalid creation order.' }
      Assert-Recovery ($command -match '--from-file .+ --no-prompt$') 'Toolbox creation retains file and noninteractive arguments'
      Assert-Recovery ($state.Yaml -match 'type: mcp' -and $state.Yaml -match 'server_label: demofs_kb' -and $state.Yaml -match 'project_connection_id: dispute-kb-mcp-conn' -and $state.Yaml -match 'require_approval: never') 'Tool configuration remains unchanged'
      $state.Toolbox = $true
    }
  }
  if ($state.FailAt -eq $operation -and $state.FailAfterMutation) {
    $global:LASTEXITCODE = 1
    Write-Error -Message 'HTTP 503 after the service accepted the mutation' -ErrorAction Continue
  }
}

function Invoke-WebRequest {
  param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$Body)
  $message = $Body | ConvertFrom-Json
  $calls.Add("http-$($message.method)")
  if ($Uri -ne "$($fixture.FOUNDRY_PROJECT_ENDPOINT)/toolboxes/synthetic-toolbox/mcp?api-version=v1" -or
    $Method -ne 'POST' -or $Headers.Authorization -ne 'Bearer synthetic-token') {
    $state.MockError = 'Unexpected verification request.'
    throw $state.MockError
  }
  return @{ Headers = @{}; Content = '{"result":{"tools":[{"name":"knowledge_base_retrieve","description":"Synthetic retrieve"}]}}' }
}

function Invoke-Recovery {
  param(
    [switch]$WithoutApproval,
    [string]$ConfigPath
  )
  $calls.Clear()
  $state.Error = ''
  $state.MockError = ''
  $scriptArguments = @{ ReplaceToolbox = (-not $WithoutApproval) }
  if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    $scriptArguments.ConfigPath = $ConfigPath
  }
  try { & $targetScript @scriptArguments *> $null }
  catch { $state.Error = $_.Exception.Message }
  if ($state.MockError) { throw $state.MockError }
}

$preflight = @('subscription', 'search', 'identity', 'rbac', 'bootstrap', 'project', 'list-toolbox', 'list-connection')
$creation = @('create-connection', 'yaml', 'create-toolbox', 'token', 'http-initialize', 'http-notifications/initialized', 'http-tools/list')
try {
  Invoke-Recovery -WithoutApproval -ConfigPath $missingConfigPath
  Assert-Recovery ($state.Error -like 'No toolbox changes made*' -and $calls.Count -eq 0) 'Approval guard prevents all config, CLI and HTTP calls'

  Invoke-Recovery -ConfigPath $missingConfigPath
  Assert-Recovery ($state.Error -like 'ConfigPath does not reference an existing file*' -and $calls.Count -eq 0) 'Missing explicit config fails before any Azure, azd, or HTTP call'

  Invoke-Recovery -ConfigPath $malformedConfigPath
  Assert-Recovery ($state.Error -like 'Malformed configuration at line 2*' -and $calls.Count -eq 0 -and
    [Environment]::GetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', 'Process') -eq $fixture.AZURE_SUBSCRIPTION_ID) 'Malformed explicit config is rejected atomically before any mutation'

  Invoke-Recovery -ConfigPath $partialConfigPath
  Assert-Recovery ($state.Error -like 'Missing required non-secret configuration in ConfigPath: FOUNDRY_KB_NAME*' -and
    $calls.Count -eq 0) 'Explicit config cannot inherit missing required values from the process environment'

  [Environment]::SetEnvironmentVariable('FOUNDRY_KB_NAME', $null, 'Process')
  Invoke-Recovery
  Assert-Recovery ($state.Error -like 'Missing required non-secret configuration in process environment: FOUNDRY_KB_NAME*' -and
    $calls.Count -eq 0) 'Missing process environment configuration fails before any mutation'
  [Environment]::SetEnvironmentVariable('FOUNDRY_KB_NAME', $fixture.FOUNDRY_KB_NAME, 'Process')

  foreach ($key in $fixture.Keys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
  $state = @{ Toolbox = $false; Connection = $false }
  Invoke-Recovery -ConfigPath $validConfigPath
  Assert-Recovery ($state.Error -eq '' -and ($calls -join ',') -eq (($preflight + $creation) -join ',') -and
    [Environment]::GetEnvironmentVariable('FOUNDRY_KB_NAME', 'Process') -eq $fixture.FOUNDRY_KB_NAME) 'Explicit ConfigPath supports complete public setup'
  foreach ($key in $fixture.Keys) { [Environment]::SetEnvironmentVariable($key, $fixture[$key], 'Process') }

  foreach ($toolboxPresent in @($true, $false)) {
    foreach ($connectionPresent in @($true, $false)) {
      $state = @{ Toolbox = $toolboxPresent; Connection = $connectionPresent }
      Invoke-Recovery
      Assert-Recovery ($state.Error -eq '') "Replacement succeeds: toolbox=$toolboxPresent connection=$connectionPresent ($($state.Error))"
      $expected = $preflight.Clone()
      if ($toolboxPresent) { $expected += 'delete-toolbox' }
      if ($connectionPresent) { $expected += 'delete-connection' }
      $expected += $creation
      Assert-Recovery (($calls -join ',') -eq ($expected -join ',')) 'Both reads precede deletes; only present resources deleted; connection created first'
      Assert-Recovery ($state.Toolbox -and $state.Connection) 'Replacement leaves both resources present'
    }
  }

  foreach ($names in @(
    @('synthetic-toolbox-backup', 'dispute-kb-mcp-conn-backup'),
    @('synthetic-toolbo', 'dispute-kb-mcp-con')
  )) {
    $state = @{
      Toolbox = $false; Connection = $false
      ToolboxJson = ConvertTo-Json -Depth 5 -InputObject @{ toolboxes = @(@{ name = $names[0] }) }
      ConnectionJson = ConvertTo-Json -InputObject @(@{ name = $names[1] })
    }
    Invoke-Recovery
    Assert-Recovery ($state.Error -eq '' -and ($calls -join ',') -eq (($preflight + $creation) -join ',')) 'Only exact names authorize deletion; prefixes and suffixes do not match'
  }

  foreach ($operation in @('list-toolbox', 'list-connection')) {
    foreach ($ambiguousNames in @(
      @('SYNTHETIC-TOOLBOX', 'DISPUTE-KB-MCP-CONN'),
      @('synthetic-toolbox', 'dispute-kb-mcp-conn')
    )) {
      $state = @{ Toolbox = $true; Connection = $true }
      if ($operation -eq 'list-toolbox') {
        $state.ToolboxJson = ConvertTo-Json -Depth 5 -InputObject @{
          toolboxes = @(@{ name = 'synthetic-toolbox' }, @{ name = $ambiguousNames[0] })
        }
      } else {
        $state.ConnectionJson = ConvertTo-Json -InputObject @(
          @{ name = 'dispute-kb-mcp-conn' }, @{ name = $ambiguousNames[1] }
        )
      }
      Invoke-Recovery
      $lastRead = [array]::IndexOf($preflight, $operation)
      Assert-Recovery ($state.Error -like 'Ambiguous resource name*' -and
        ($calls -join ',') -eq ($preflight[0..$lastRead] -join ',') -and
        $state.Toolbox -and $state.Connection) 'Duplicate or case-ambiguous names fail closed before deletion'
    }
    $state = @{ Toolbox = $true; Connection = $true }
    if ($operation -eq 'list-toolbox') { $state.ToolboxJson = '{"toolboxes":[{"name":"SYNTHETIC-TOOLBOX"}]}' }
    else { $state.ConnectionJson = '[{"name":"DISPUTE-KB-MCP-CONN"}]' }
    Invoke-Recovery
    $lastRead = [array]::IndexOf($preflight, $operation)
    Assert-Recovery ($state.Error -like 'Ambiguous resource name*' -and
      ($calls -join ',') -eq ($preflight[0..$lastRead] -join ',')) 'Case-only resource name mismatch is not treated as absence'
  }

  foreach ($operation in @('list-toolbox', 'list-connection')) {
    foreach ($status in @(401, 403, 404, 429, 500, 503)) {
      $state = @{ Toolbox = $true; Connection = $true; FailAt = $operation
        Stderr = "HTTP $status authorization/service failure (resource not found text is not proof)"
        Stdout = $(if ($operation -eq 'list-toolbox') { '{"toolboxes":[]}' } else { 'null' }) }
      Invoke-Recovery
      Assert-Recovery ($state.Error -like 'Cannot list*') "$operation HTTP $status fails closed even with absence-shaped stdout"
      $lastRead = [array]::IndexOf($preflight, $operation)
      Assert-Recovery (($calls -join ',') -eq ($preflight[0..$lastRead] -join ',')) 'No calls after failed read'
      Assert-Recovery ($state.Toolbox -and $state.Connection) 'Failed preflight leaves both resources intact'
    }
  }

  foreach ($json in @('', 'garbage', '{}', '{"error":{"code":"403"}}', '{"toolboxes":null}', '{"toolboxes":[],"nextLink":"more"}', '{"toolboxes":[{}]}')) {
    $state = @{ Toolbox = $true; Connection = $true; ToolboxJson = $json }
    Invoke-Recovery
    Assert-Recovery ($state.Error -ne '' -and ($calls -join ',') -eq ($preflight[0..6] -join ',')) 'Malformed or incomplete toolbox listing stops before connection read or deletion'
  }
  foreach ($json in @('', 'garbage', '{}', '{"error":{"code":"403"}}', '{"value":[],"nextLink":"more"}', '[{}]', '[null]', '{"name":"dispute-kb-mcp-conn"}')) {
    $state = @{ Toolbox = $true; Connection = $true; ConnectionJson = $json }
    Invoke-Recovery
    Assert-Recovery ($state.Error -ne '' -and ($calls -join ',') -eq ($preflight -join ',')) 'Malformed or incomplete connection listing stops before any deletion'
  }
  foreach ($emptyJson in @('[]', 'null')) {
    $state = @{ Toolbox = $false; Connection = $false; ToolboxJson = '{"toolboxes":[]}'; ConnectionJson = $emptyJson }
    Invoke-Recovery
    Assert-Recovery ($state.Error -eq '' -and ($calls -join ',') -eq (($preflight + $creation) -join ',')) "Confirmed empty listing ($emptyJson) supports initial setup"
  }

  foreach ($operation in @('delete-toolbox', 'delete-connection', 'create-connection', 'create-toolbox')) {
    $state = @{ Toolbox = $true; Connection = $true; FailAt = $operation; Stderr = 'HTTP 503 synthetic failure' }
    Invoke-Recovery
    $fullSequence = $preflight + @('delete-toolbox', 'delete-connection') + $creation
    $failureIndex = [array]::IndexOf($fullSequence, $operation)
    Assert-Recovery ($state.Error -like '*failed*' -and ($calls -join ',') -eq ($fullSequence[0..$failureIndex] -join ',')) "$operation failure stops every subsequent call"
    $expectedRetry = $preflight.Clone()
    if ($state.Toolbox) { $expectedRetry += 'delete-toolbox' }
    if ($state.Connection) { $expectedRetry += 'delete-connection' }
    $expectedRetry += $creation
    Invoke-Recovery -WithoutApproval
    Assert-Recovery ($state.Error -like 'No toolbox changes made*' -and $calls.Count -eq 0) 'Partial-failure retry still requires explicit approval'
    $state.FailAt = ''
    Invoke-Recovery
    Assert-Recovery ($state.Error -eq '' -and $state.Toolbox -and $state.Connection) "Approved retry recovers from $operation failure"
    Assert-Recovery (($calls -join ',') -eq ($expectedRetry -join ',')) 'Retry re-reads state and deletes only remaining resources'
  }
  foreach ($operation in @('create-connection', 'create-toolbox')) {
    $state = @{ Toolbox = $false; Connection = $false; FailAt = $operation; FailAfterMutation = $true }
    Invoke-Recovery
    $fullSequence = $preflight + $creation
    $failureIndex = [array]::IndexOf($fullSequence, $operation)
    Assert-Recovery ($state.Error -like '*creation failed*' -and
      ($calls -join ',') -eq ($fullSequence[0..$failureIndex] -join ',')) 'Failed creation response stops even when the artifact was persisted'
    $expectedRetry = $preflight.Clone()
    if ($state.Toolbox) { $expectedRetry += 'delete-toolbox' }
    if ($state.Connection) { $expectedRetry += 'delete-connection' }
    $expectedRetry += $creation
    $state.FailAt = ''
    Invoke-Recovery
    Assert-Recovery ($state.Error -eq '' -and $state.Toolbox -and $state.Connection -and
      ($calls -join ',') -eq ($expectedRetry -join ',')) 'Retry discovers and replaces artifacts persisted before a failed creation response'
  }
} finally {
  foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key]) }
  if ([IO.Directory]::Exists($tempRoot)) { [IO.Directory]::Delete($tempRoot, $true) }
  $global:LASTEXITCODE = $savedExitCode
}

Write-Host "$($checks.Passed) recovery checks passed; synthetic config and mocked CLI/HTTP only; no Azure calls."