Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SupportedContractSchemas = @('3.0.0', '3.1.0')
$script:SearchAudience = 'https://search.azure.com/'
$script:ManagementAudience = 'https://management.azure.com/'

function Protect-QuickstartText {
  [CmdletBinding()]
  param(
    [AllowNull()][string]$Text,
    [AllowEmptyCollection()][string[]]$SensitiveValues = @()
  )

  if ([string]::IsNullOrEmpty($Text)) {
    return $Text
  }

  $redacted = $Text
  foreach ($sensitiveValue in $SensitiveValues) {
    if (-not [string]::IsNullOrEmpty($sensitiveValue)) {
      $redacted = $redacted.Replace($sensitiveValue, '<redacted>')
    }
  }
  $redacted = $redacted -replace '(?i)(Authorization\s*:\s*Bearer\s+)[^\s,;]+', '$1<redacted>'
  $redacted = $redacted -replace '(?i)(access[_-]?token|client[_-]?secret|password|account[_-]?key)(["'']?\s*[:=]\s*["'']?)[^"''\s,;]+', '$1$2<redacted>'
  $redacted = $redacted -replace 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '<redacted-jwt>'
  return $redacted
}

function Get-QuickstartUri {
  param(
    [Parameter(Mandatory)]
    [string]$Value,
    [Parameter(Mandatory)]
    [string]$Label
  )

  $uri = $null
  if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
    throw "$Label must be an absolute HTTPS URI."
  }
  return $uri
}

function Get-QuickstartPropertyNames {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return @()
  }
  return @($Value.PSObject.Properties.Name | Sort-Object)
}

function Test-QuickstartExactValues {
  param(
    [AllowNull()]$Actual,
    [AllowNull()]$Expected
  )

  $actualValues = @($Actual | ForEach-Object { [string]$_ })
  $expectedValues = @($Expected | ForEach-Object { [string]$_ })
  if ($actualValues.Count -ne $expectedValues.Count) {
    return $false
  }
  for ($index = 0; $index -lt $actualValues.Count; $index++) {
    if ($actualValues[$index] -cne $expectedValues[$index]) {
      return $false
    }
  }
  return $true
}

function Assert-QuickstartExactProperties {
  param(
    [AllowNull()]$Value,
    [Parameter(Mandatory)]
    [string[]]$Expected,
    [Parameter(Mandatory)]
    [string]$Label
  )

  $actual = @(Get-QuickstartPropertyNames -Value $Value)
  $sortedExpected = @($Expected | Sort-Object)
  if (-not (Test-QuickstartExactValues -Actual $actual -Expected $sortedExpected)) {
    throw "$Label contains unsupported properties."
  }
}

function Get-QuickstartOperationRule {
  param([Parameter(Mandatory)][string]$Id)

  $rules = @{
    'search-index' = @{
      Order = 10
      DependsOn = @()
      PathPrefix = '/indexes/'
      ApiProfile = 'search'
    }
    'search-data-source' = @{
      Order = 20
      DependsOn = @('search-index')
      PathPrefix = '/datasources/'
      ApiProfile = 'search'
    }
    'search-skillset' = @{
      Order = 30
      DependsOn = @('search-index')
      PathPrefix = '/skillsets/'
      ApiProfile = 'search'
    }
    'search-indexer' = @{
      Order = 40
      DependsOn = @('search-data-source', 'search-skillset')
      PathPrefix = '/indexers/'
      ApiProfile = 'search'
    }
    'foundry-knowledge-source' = @{
      Order = 50
      DependsOn = @('search-index')
      PathPrefix = '/knowledgeSources/'
      ApiProfile = 'foundryIq'
    }
    'foundry-knowledge-base' = @{
      Order = 60
      DependsOn = @('foundry-knowledge-source')
      PathPrefix = '/knowledgeBases/'
      ApiProfile = 'foundryIq'
    }
  }

  if (-not $rules.ContainsKey($Id)) {
    throw "Unsupported data-plane operation ID '$Id'."
  }
  return $rules[$Id]
}

function Get-QuickstartOperation {
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)][string]$Id
  )

  $matches = @($Contract.dataPlane.operations | Where-Object { [string]$_.id -ceq $Id })
  if ($matches.Count -ne 1) {
    throw "Contract must contain exactly one '$Id' operation."
  }
  return $matches[0]
}

function Assert-QuickstartSearchUri {
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)][string]$Value,
    [Parameter(Mandatory)][string]$ExpectedPath,
    [Parameter(Mandatory)][string]$ExpectedApiVersion,
    [Parameter(Mandatory)][string]$Label
  )

  $target = Get-QuickstartUri -Value $Value -Label $Label
  $ownedSearch = Get-QuickstartUri -Value ([string]$Contract.resources.search.endpoint) -Label 'Owned Search endpoint'
  if ($target.Host -cne $ownedSearch.Host) {
    throw "$Label targets a host outside the owned Search endpoint."
  }
  if ($target.AbsolutePath -cne $ExpectedPath) {
    throw "$Label uses an unsupported path."
  }
  if ($target.Query -cne "?api-version=$ExpectedApiVersion") {
    throw "$Label uses an unsupported query or API version."
  }
}

function Assert-QuickstartOperation {
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)]$Operation
  )

  Assert-QuickstartExactProperties -Value $Operation -Expected @(
    'acceptedStatusCodes'
    'apiVersion'
    'audience'
    'body'
    'canonicalization'
    'dependsOn'
    'id'
    'method'
    'order'
    'retry'
    'serviceKind'
    'uri'
    'verificationUri'
  ) -Label "Operation '$($Operation.id)'"

  $id = [string]$Operation.id
  $rule = Get-QuickstartOperationRule -Id $id
  if ([int]$Operation.order -ne [int]$rule.Order -or
      -not (Test-QuickstartExactValues -Actual $Operation.dependsOn -Expected $rule.DependsOn)) {
    throw "Operation '$id' has an unsupported order or dependency set."
  }
  if ([string]$Operation.serviceKind -cne 'search-management' -or
      [string]$Operation.method -cne 'PUT' -or
      [string]$Operation.audience -cne $script:SearchAudience) {
    throw "Operation '$id' has an unsupported kind, method, or audience."
  }
  if ($null -eq $Operation.body -or
      [string]::IsNullOrWhiteSpace([string]$Operation.body.name) -or
      [string]$Operation.body.name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,127}$') {
    throw "Operation '$id' has an invalid named resource body."
  }

  $apiVersion = [string]$Contract.dataPlane.apiProfile.($rule.ApiProfile)
  if ([string]$Operation.apiVersion -cne $apiVersion) {
    throw "Operation '$id' uses an API version outside its exact profile."
  }
  $expectedPath = "$($rule.PathPrefix)$([string]$Operation.body.name)"
  Assert-QuickstartSearchUri -Contract $Contract -Value ([string]$Operation.uri) -ExpectedPath $expectedPath -ExpectedApiVersion $apiVersion -Label "Operation '$id' URI"
  Assert-QuickstartSearchUri -Contract $Contract -Value ([string]$Operation.verificationUri) -ExpectedPath $expectedPath -ExpectedApiVersion $apiVersion -Label "Operation '$id' verification URI"

  if (-not (Test-QuickstartExactValues -Actual $Operation.acceptedStatusCodes -Expected @(200, 201, 204))) {
    throw "Operation '$id' has unsupported accepted status codes."
  }
  Assert-QuickstartExactProperties -Value $Operation.retry -Expected @(
    'initialDelaySeconds'
    'maxAttempts'
    'maxDelaySeconds'
    'statusCodes'
  ) -Label "Operation '$id' retry policy"
  $retry = $Operation.retry
  if ([int]$retry.maxAttempts -lt 1 -or [int]$retry.maxAttempts -gt 8 -or
      [int]$retry.initialDelaySeconds -lt 1 -or [int]$retry.initialDelaySeconds -gt 30 -or
      [int]$retry.maxDelaySeconds -lt [int]$retry.initialDelaySeconds -or [int]$retry.maxDelaySeconds -gt 60) {
    throw "Operation '$id' has an invalid bounded retry policy."
  }
  $retryStatuses = @($retry.statusCodes | ForEach-Object { [int]$_ })
  if (@($retryStatuses | Where-Object { $_ -notin @(408, 409, 429, 500, 502, 503, 504) }).Count) {
    throw "Operation '$id' retries a non-transient status."
  }
}

function Assert-QuickstartRetrievalBody {
  param([Parameter(Mandatory)]$Body)

  Assert-QuickstartExactProperties -Value $Body -Expected @(
    'messages'
    'retrievalReasoningEffort'
  ) -Label 'Knowledge retrieval body'
  $messages = @($Body.messages)
  if ($messages.Count -ne 1) {
    throw 'Knowledge retrieval body must contain exactly one message.'
  }
  Assert-QuickstartExactProperties -Value $messages[0] -Expected @('content', 'role') -Label 'Knowledge retrieval message'
  $content = @($messages[0].content)
  if ([string]$messages[0].role -cne 'user' -or $content.Count -ne 1) {
    throw 'Knowledge retrieval body must contain one user text item.'
  }
  Assert-QuickstartExactProperties -Value $content[0] -Expected @('text', 'type') -Label 'Knowledge retrieval content'
  if ([string]$content[0].type -cne 'text' -or [string]::IsNullOrWhiteSpace([string]$content[0].text)) {
    throw 'Knowledge retrieval body must contain one non-empty user text item.'
  }
  Assert-QuickstartExactProperties -Value $Body.retrievalReasoningEffort -Expected @('kind') -Label 'Knowledge retrieval reasoning'
  if ([string]$Body.retrievalReasoningEffort.kind -cne 'low') {
    throw 'Knowledge retrieval reasoning must use the allowlisted bounded profile.'
  }
}

function Assert-QuickstartVerificationCheck {
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)]$Check
  )

  $id = [string]$Check.id
  $searchEndpoint = Get-QuickstartUri -Value ([string]$Contract.resources.search.endpoint) -Label 'Owned Search endpoint'
  $functionEndpoint = Get-QuickstartUri -Value ([string]$Contract.resources.function.endpoint) -Label 'Owned Function endpoint'
  $functionAudience = if ([string]$Contract.schemaVersion -ceq '3.1.0') {
    [string]$Contract.resources.function.authAudience
  } else {
    'api://AzureADTokenExchange'
  }
  $searchApiVersion = [string]$Contract.dataPlane.apiProfile.search
  $foundryApiVersion = [string]$Contract.dataPlane.apiProfile.foundryIq

  switch ($id) {
    'function-health' {
      Assert-QuickstartExactProperties -Value $Check -Expected @(
        'acceptedStatusCodes'
        'audience'
        'id'
        'kind'
        'method'
        'order'
        'uri'
      ) -Label "Verification check '$id'"
      $target = Get-QuickstartUri -Value ([string]$Check.uri) -Label "Verification check '$id' URI"
      $healthAudience = [string]$Check.audience
      if ([int]$Check.order -ne 10 -or [string]$Check.kind -cne 'health' -or
          [string]$Check.method -cne 'GET' -or ($healthAudience -cne '' -and $healthAudience -cne $functionAudience) -or
          $target.Host -cne $functionEndpoint.Host -or $target.AbsolutePath -cne '/api/health' -or
          -not [string]::IsNullOrEmpty($target.Query)) {
        throw "Verification check '$id' has an unsupported kind, method, path, host, or audience."
      }
    }
    'indexer-status' {
      Assert-QuickstartExactProperties -Value $Check -Expected @(
        'acceptedStatusCodes'
        'audience'
        'failureStatuses'
        'id'
        'kind'
        'method'
        'order'
        'poll'
        'successStatus'
        'uri'
      ) -Label "Verification check '$id'"
      $indexer = Get-QuickstartOperation -Contract $Contract -Id 'search-indexer'
      $expectedPath = "/indexers/$([string]$indexer.body.name)/status"
      if ([int]$Check.order -ne 20 -or [string]$Check.kind -cne 'indexer-status' -or
          [string]$Check.method -cne 'GET' -or [string]$Check.audience -cne $script:SearchAudience) {
        throw "Verification check '$id' has an unsupported kind, method, or audience."
      }
      Assert-QuickstartSearchUri -Contract $Contract -Value ([string]$Check.uri) -ExpectedPath $expectedPath -ExpectedApiVersion $searchApiVersion -Label "Verification check '$id' URI"
      Assert-QuickstartExactProperties -Value $Check.poll -Expected @('intervalSeconds', 'maxAttempts') -Label "Verification check '$id' poll policy"
      if ([int]$Check.poll.maxAttempts -lt 1 -or [int]$Check.poll.maxAttempts -gt 60 -or
          [int]$Check.poll.intervalSeconds -lt 1 -or [int]$Check.poll.intervalSeconds -gt 30) {
        throw "Verification check '$id' has an invalid bounded poll policy."
      }
      if ([string]$Check.successStatus -cne 'success' -or
          -not (Test-QuickstartExactValues -Actual $Check.failureStatuses -Expected @('transientFailure', 'persistentFailure'))) {
        throw "Verification check '$id' has unsupported terminal states."
      }
    }
    'document-count' {
      Assert-QuickstartExactProperties -Value $Check -Expected @(
        'acceptedStatusCodes'
        'audience'
        'id'
        'kind'
        'method'
        'minimum'
        'order'
        'uri'
      ) -Label "Verification check '$id'"
      $index = Get-QuickstartOperation -Contract $Contract -Id 'search-index'
      $expectedPath = "/indexes/$([string]$index.body.name)/docs/`$count"
      if ([int]$Check.order -ne 30 -or [string]$Check.kind -cne 'count' -or
          [string]$Check.method -cne 'GET' -or [string]$Check.audience -cne $script:SearchAudience -or
          [int]$Check.minimum -lt 1) {
        throw "Verification check '$id' has an unsupported kind, method, audience, or minimum."
      }
      Assert-QuickstartSearchUri -Contract $Contract -Value ([string]$Check.uri) -ExpectedPath $expectedPath -ExpectedApiVersion $searchApiVersion -Label "Verification check '$id' URI"
    }
    'knowledge-retrieval' {
      Assert-QuickstartExactProperties -Value $Check -Expected @(
        'acceptedStatusCodes'
        'audience'
        'body'
        'citationCollectionField'
        'id'
        'kind'
        'method'
        'order'
        'resultCollectionField'
        'sourceIdField'
        'uri'
      ) -Label "Verification check '$id'"
      $knowledgeBase = Get-QuickstartOperation -Contract $Contract -Id 'foundry-knowledge-base'
      $expectedPath = "/knowledgebases/$([string]$knowledgeBase.body.name)/retrieve"
      if ([int]$Check.order -ne 40 -or [string]$Check.kind -cne 'retrieval' -or
          [string]$Check.method -cne 'POST' -or [string]$Check.audience -cne $script:SearchAudience -or
          [string]$Check.resultCollectionField -cne 'response' -or
          [string]$Check.citationCollectionField -cne 'references' -or
          [string]$Check.sourceIdField -cne 'id') {
        throw "Verification check '$id' has an unsupported kind, method, response contract, or audience."
      }
      Assert-QuickstartSearchUri -Contract $Contract -Value ([string]$Check.uri) -ExpectedPath $expectedPath -ExpectedApiVersion $foundryApiVersion -Label "Verification check '$id' URI"
      Assert-QuickstartRetrievalBody -Body $Check.body
    }
    default {
      throw "Unsupported verification check ID '$id'."
    }
  }

  if (-not (Test-QuickstartExactValues -Actual $Check.acceptedStatusCodes -Expected @(200))) {
    throw "Verification check '$id' has unsupported accepted status codes."
  }
}

function Test-QuickstartContract {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Contract)

  Assert-QuickstartExactProperties -Value $Contract -Expected @(
    'cleanup'
    'dataPlane'
    'deployment'
    'resources'
    'schemaVersion'
    'verification'
  ) -Label 'Quickstart contract'
  $schemaVersion = [string]$Contract.schemaVersion
  if ($schemaVersion -cnotin $script:SupportedContractSchemas) {
    throw "Unsupported quickstart contract schema '$schemaVersion'."
  }
  if ($schemaVersion -ceq '3.1.0') {
    $functionAuthProperties = @(Get-QuickstartPropertyNames -Value $Contract.resources.function)
    if ('authClientId' -cnotin $functionAuthProperties) {
      throw 'Function authentication client ID must be a canonical GUID.'
    }
    if ('authAudience' -cnotin $functionAuthProperties) {
      throw 'Function authentication audience must exactly match its client ID.'
    }
    $functionAuthClientId = [string]$Contract.resources.function.authClientId
    $parsedFunctionAuthClientId = [guid]::Empty
    if (-not [guid]::TryParseExact($functionAuthClientId, 'D', [ref]$parsedFunctionAuthClientId) -or
        $functionAuthClientId -cne $parsedFunctionAuthClientId.ToString('D')) {
      throw 'Function authentication client ID must be a canonical GUID.'
    }
    if ([string]$Contract.resources.function.authAudience -cne "api://$functionAuthClientId") {
      throw 'Function authentication audience must exactly match its client ID.'
    }
  }

  $deployment = $Contract.deployment
  Assert-QuickstartExactProperties -Value $deployment -Expected @(
    'deploymentId'
    'deploymentName'
    'environment'
    'location'
    'ownershipTags'
    'provenanceId'
    'resourceGroupId'
    'resourceGroupName'
    'subscriptionId'
  ) -Label 'Quickstart deployment'
  $parsedDeploymentId = [guid]::Empty
  if (-not [guid]::TryParseExact([string]$deployment.deploymentId, 'D', [ref]$parsedDeploymentId)) {
    throw 'Quickstart deployment ID must be a canonical GUID.'
  }
  $deploymentId = $parsedDeploymentId.ToString('D')
  $environment = [string]$deployment.environment
  if ($environment -cnotmatch '^[a-z][a-z0-9-]{2,23}$') {
    throw 'Quickstart environment is not canonical.'
  }
  $expectedDeploymentName = "quickstart-$deploymentId"
  $expectedGroupName = "rg-$environment-$deploymentId"
  $expectedGroupId = "/subscriptions/$([string]$deployment.subscriptionId)/resourceGroups/$expectedGroupName"
  if ([string]$deployment.deploymentId -cne $deploymentId -or
      [string]$deployment.deploymentName -cne $expectedDeploymentName -or
      [string]$deployment.resourceGroupName -cne $expectedGroupName -or
      [string]$deployment.resourceGroupId -cne $expectedGroupId -or
      [string]::IsNullOrWhiteSpace([string]$deployment.provenanceId)) {
    throw 'Quickstart deployment naming or provenance is not canonical.'
  }

  $expectedOwnership = [ordered]@{
    'quickstart.owner' = 'financial-services-knowledge-quickstart'
    'quickstart.schemaVersion' = $schemaVersion
    'quickstart.deploymentId' = $deploymentId
    'quickstart.deploymentName' = $expectedDeploymentName
    'quickstart.provenanceId' = [string]$deployment.provenanceId
    'quickstart.protected' = 'false'
  }
  Assert-QuickstartExactProperties -Value $deployment.ownershipTags -Expected @($expectedOwnership.Keys) -Label 'Quickstart ownership tags'
  foreach ($entry in $expectedOwnership.GetEnumerator()) {
    if ([string]$deployment.ownershipTags.($entry.Key) -cne [string]$entry.Value) {
      throw "Quickstart ownership tag '$($entry.Key)' is not canonical."
    }
  }

  Assert-QuickstartExactProperties -Value $Contract.cleanup -Expected @(
    'deploymentId'
    'deploymentName'
    'expectedSubscriptionId'
    'protectionTagName'
    'protectionTagValue'
    'provenanceId'
    'requiredOwnershipTags'
    'resourceGroupId'
    'resourceGroupName'
  ) -Label 'Quickstart cleanup contract'
  if ([string]$Contract.cleanup.resourceGroupId -cne [string]$deployment.resourceGroupId -or
      [string]$Contract.cleanup.resourceGroupName -cne [string]$deployment.resourceGroupName -or
      [string]$Contract.cleanup.deploymentId -cne $deploymentId -or
      [string]$Contract.cleanup.deploymentName -cne $expectedDeploymentName -or
      [string]$Contract.cleanup.expectedSubscriptionId -cne [string]$deployment.subscriptionId -or
      [string]$Contract.cleanup.provenanceId -cne [string]$deployment.provenanceId -or
      [string]$Contract.cleanup.protectionTagName -cne 'quickstart.protected' -or
      [string]$Contract.cleanup.protectionTagValue -cne 'true') {
    throw 'Quickstart cleanup scope does not match canonical deployment ownership.'
  }
  $deploymentTags = ConvertTo-QuickstartCanonicalJson -Value $deployment.ownershipTags
  $cleanupTags = ConvertTo-QuickstartCanonicalJson -Value $Contract.cleanup.requiredOwnershipTags
  if ($deploymentTags -cne $cleanupTags) {
    throw 'Quickstart cleanup ownership evidence does not match deployment provenance.'
  }

  Assert-QuickstartExactProperties -Value $Contract.dataPlane -Expected @('apiProfile', 'operations') -Label 'Quickstart data plane'
  Assert-QuickstartExactProperties -Value $Contract.dataPlane.apiProfile -Expected @('foundryIq', 'search') -Label 'Quickstart API profile'
  $operations = @($Contract.dataPlane.operations)
  if ($operations.Count -ne 6) {
    throw 'Quickstart contract must contain exactly six data-plane operations.'
  }
  $expectedOperationIds = @(
    'search-index'
    'search-data-source'
    'search-skillset'
    'search-indexer'
    'foundry-knowledge-source'
    'foundry-knowledge-base'
  )
  for ($index = 0; $index -lt $operations.Count; $index++) {
    if ([string]$operations[$index].id -cne $expectedOperationIds[$index]) {
      throw 'Quickstart data-plane operation order is not canonical.'
    }
    Assert-QuickstartOperation -Contract $Contract -Operation $operations[$index]
  }

  Assert-QuickstartExactProperties -Value $Contract.verification -Expected @('checks') -Label 'Quickstart verification'
  $checks = @($Contract.verification.checks)
  $expectedCheckIds = @('function-health', 'indexer-status', 'document-count', 'knowledge-retrieval')
  if ($checks.Count -ne $expectedCheckIds.Count) {
    throw 'Quickstart contract must contain exactly four verification checks.'
  }
  for ($index = 0; $index -lt $checks.Count; $index++) {
    if ([string]$checks[$index].id -cne $expectedCheckIds[$index]) {
      throw 'Quickstart verification order is not canonical.'
    }
    if ($null -ne $checks[$index].PSObject.Properties['isReadOnly']) {
      throw "Verification check '$($checks[$index].id)' uses the prohibited mutable isReadOnly marker."
    }
    Assert-QuickstartVerificationCheck -Contract $Contract -Check $checks[$index]
  }
  return $true
}

function Read-QuickstartContract {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Quickstart contract was not found: $Path"
  }
  try {
    $contract = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
  } catch {
    throw "Quickstart contract is not valid JSON: $(Protect-QuickstartText $_.Exception.Message)"
  }
  Test-QuickstartContract -Contract $contract | Out-Null
  return $contract
}

function Invoke-QuickstartAzJson {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [Parameter(Mandatory)][string]$Phase
  )

  if ('--only-show-errors' -notin $Arguments) {
    $Arguments += '--only-show-errors'
  }
  $output = & az @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "$Phase failed: $(Protect-QuickstartText ($output -join [Environment]::NewLine))"
  }
  if ($null -eq $output -or [string]::IsNullOrWhiteSpace(($output -join ''))) {
    return $null
  }
  try {
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
  } catch {
    throw "$Phase returned invalid JSON: $(Protect-QuickstartText $_.Exception.Message)"
  }
}

function Get-QuickstartDeploymentContract {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$DeploymentName
  )

  $contract = Invoke-QuickstartAzJson -Arguments @(
    'deployment', 'sub', 'show',
    '--subscription', $SubscriptionId,
    '--name', $DeploymentName,
    '--query', 'properties.outputs.quickstartContract.value',
    '--output', 'json'
  ) -Phase 'Canonical subscription deployment contract read'
  if ($null -eq $contract) {
    throw 'Canonical subscription deployment output is missing.'
  }
  Test-QuickstartContract -Contract $contract | Out-Null
  return $contract
}

function ConvertTo-QuickstartCanonicalJson {
  [CmdletBinding()]
  param(
    [AllowNull()]$Value,
    [string[]]$RemoveFields = @()
  )

  $copy = if ($null -eq $Value) {
    $null
  } else {
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -AsHashtable
  }
  if ($copy -is [System.Collections.IDictionary]) {
    foreach ($field in $RemoveFields) {
      $copy.Remove($field) | Out-Null
    }
  }

  function Convert-CanonicalValue($InputValue) {
    if ($InputValue -is [System.Collections.IDictionary]) {
      $ordered = [ordered]@{}
      foreach ($key in @($InputValue.Keys | Sort-Object)) {
        $ordered[$key] = Convert-CanonicalValue $InputValue[$key]
      }
      return $ordered
    }
    if ($InputValue -is [array]) {
      return ,@($InputValue | ForEach-Object { Convert-CanonicalValue $_ })
    }
    return $InputValue
  }

  return (Convert-CanonicalValue $copy) | ConvertTo-Json -Depth 100 -Compress
}

function Assert-QuickstartContractBinding {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$LocalContract,
    [Parameter(Mandatory)]$DeploymentContract
  )

  Test-QuickstartContract -Contract $LocalContract | Out-Null
  Test-QuickstartContract -Contract $DeploymentContract | Out-Null
  if ((ConvertTo-QuickstartCanonicalJson -Value $LocalContract) -cne
      (ConvertTo-QuickstartCanonicalJson -Value $DeploymentContract)) {
    throw 'Persisted local contract does not match the complete canonical subscription deployment output.'
  }
  return $true
}

function Get-QuickstartAccessToken {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Audience
  )

  if ($Audience -cne $script:SearchAudience -and
      $Audience -cne $script:ManagementAudience -and
      $Audience -cnotmatch '^api://[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
    throw 'Token acquisition audience is not allowlisted.'
  }

  $token = & az account get-access-token --resource $Audience --query accessToken --output tsv 2>&1
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($token -join ''))) {
    throw "Token acquisition failed for an allowlisted audience: $(Protect-QuickstartText ($token -join [Environment]::NewLine))"
  }
  return ($token -join '').Trim()
}

function Invoke-QuickstartHttp {
  param(
    [Parameter(Mandatory)][string]$OperationId,
    [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT')][string]$Method,
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Audience,
    [AllowNull()]$Body,
    [Parameter(Mandatory)][int[]]$AcceptedStatusCodes,
    [int]$MaxAttempts = 1,
    [int]$InitialDelaySeconds = 1,
    [int]$MaxDelaySeconds = 1,
    [int[]]$RetryStatusCodes = @()
  )

  $token = if ([string]::IsNullOrEmpty($Audience)) { $null } else { Get-QuickstartAccessToken -Audience $Audience }
  $headers = if ($null -eq $token) { $null } else { @{ Authorization = "Bearer $token" } }
  $delay = $InitialDelaySeconds
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      $parameters = @{
        Method = $Method
        Uri = $Uri
        SkipHttpErrorCheck = $true
      }
      if ($null -ne $headers) {
        $parameters.Headers = $headers
      }
      $supportsStatusCodeVariable = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('StatusCodeVariable')
      if ($supportsStatusCodeVariable) {
        $parameters.StatusCodeVariable = 'statusCode'
      }
      if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 100 -Compress
      }
      $response = Invoke-WebRequest @parameters
      if (-not $supportsStatusCodeVariable) {
        $statusCode = [int]$response.StatusCode
      }
      if ($statusCode -in $AcceptedStatusCodes) {
        $responseBody = $null
        if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
          try {
            $responseBody = $response.Content | ConvertFrom-Json -Depth 100
          } catch {
            $responseBody = $response.Content
          }
        }
        $correlationId = @(
          $response.Headers['x-ms-request-id']
          $response.Headers['request-id']
          $response.Headers['x-ms-correlation-request-id']
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
        $safeCorrelationId = Protect-QuickstartText -Text ([string]$correlationId) -SensitiveValues @($token)
        return [pscustomobject]@{
          OperationId = $OperationId
          StatusCode = [int]$statusCode
          CorrelationId = [string]$safeCorrelationId
          Body = $responseBody
        }
      }
      if ([int]$statusCode -notin $RetryStatusCodes -or $attempt -eq $MaxAttempts) {
        $responseDetail = if ([string]::IsNullOrWhiteSpace([string]$response.Content)) { '' } else { " Response: $([string]$response.Content)" }
        throw "Unexpected HTTP status $statusCode.$responseDetail"
      }
    } catch {
      $responseProperty = $_.Exception.PSObject.Properties['Response']
      $status = if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
        [int]$responseProperty.Value.StatusCode
      } else {
        0
      }
      if ($status -notin $RetryStatusCodes -or $attempt -eq $MaxAttempts) {
        $detail = ''
        if ($status -ne 0) {
          if ($null -ne $responseProperty -and $null -ne $responseProperty.Value.Content) {
            $detail = " Response: $([string]$responseProperty.Value.Content)"
          } elseif ($null -ne $response -and $null -ne $response.Content) {
            $detail = " Response: $([string]$response.Content)"
          }
        }
        throw "HTTP operation '$OperationId' failed: $(Protect-QuickstartText -Text $_.Exception.Message -SensitiveValues @($token))$(Protect-QuickstartText -Text $detail -SensitiveValues @($token))"
      }
    }
    Start-Sleep -Seconds $delay
    $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
  }
  throw "HTTP operation '$OperationId' exhausted its bounded retry policy."
}

function Invoke-QuickstartOperations {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Contract)

  Test-QuickstartContract -Contract $Contract | Out-Null
  foreach ($operation in @($Contract.dataPlane.operations)) {
    $result = Invoke-QuickstartHttp `
      -OperationId ([string]$operation.id) `
      -Method ([string]$operation.method) `
      -Uri ([string]$operation.uri) `
      -Audience ([string]$operation.audience) `
      -Body $operation.body `
      -AcceptedStatusCodes @($operation.acceptedStatusCodes | ForEach-Object { [int]$_ }) `
      -MaxAttempts ([int]$operation.retry.maxAttempts) `
      -InitialDelaySeconds ([int]$operation.retry.initialDelaySeconds) `
      -MaxDelaySeconds ([int]$operation.retry.maxDelaySeconds) `
      -RetryStatusCodes @($operation.retry.statusCodes | ForEach-Object { [int]$_ })
    $correlation = if ([string]::IsNullOrWhiteSpace($result.CorrelationId)) { 'not-returned' } else { $result.CorrelationId }
    Write-Host "Applied operation '$($result.OperationId)' with status $($result.StatusCode), correlation '$correlation'."
  }
}

function Invoke-QuickstartDriftVerification {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Contract)

  Test-QuickstartContract -Contract $Contract | Out-Null
  foreach ($operation in @($Contract.dataPlane.operations)) {
    $result = Invoke-QuickstartHttp `
      -OperationId "drift-$($operation.id)" `
      -Method 'GET' `
      -Uri ([string]$operation.verificationUri) `
      -Audience ([string]$operation.audience) `
      -Body $null `
      -AcceptedStatusCodes @(200)
    if ($null -eq $result.Body) {
      throw "Data-plane verification '$($operation.id)' returned no object."
    }
    $removeFields = @($operation.canonicalization.removeFields | ForEach-Object { [string]$_ })
    $actual = ConvertTo-QuickstartCanonicalJson -Value $result.Body -RemoveFields $removeFields
    $expected = ConvertTo-QuickstartCanonicalJson -Value $operation.body -RemoveFields $removeFields
    if ($actual -cne $expected) {
      throw "Data-plane verification '$($operation.id)' detected contract drift."
    }
  }
}

function Assert-QuickstartOwnership {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)]$ResourceGroup
  )

  Test-QuickstartContract -Contract $Contract | Out-Null
  if ([string]$ResourceGroup.id -cne [string]$Contract.cleanup.resourceGroupId -or
      [string]$ResourceGroup.name -cne [string]$Contract.cleanup.resourceGroupName) {
    throw 'Resource group identity does not match the cleanup contract.'
  }
  if ($null -eq $ResourceGroup.PSObject.Properties['tags'] -or $null -eq $ResourceGroup.tags) {
    throw 'Resource group has no ownership tags.'
  }
  $protection = $ResourceGroup.tags.PSObject.Properties[[string]$Contract.cleanup.protectionTagName]
  if ($null -eq $protection) {
    throw 'Resource group cleanup protection evidence is missing.'
  }
  if ([string]$protection.Value -ieq [string]$Contract.cleanup.protectionTagValue) {
    throw 'Resource group has an explicit cleanup protection tag.'
  }
  if ([string]$protection.Value -cne 'false') {
    throw 'Resource group cleanup protection evidence is not canonical.'
  }
  foreach ($tag in $Contract.cleanup.requiredOwnershipTags.PSObject.Properties) {
    $actual = $ResourceGroup.tags.PSObject.Properties[$tag.Name]
    if ($null -eq $actual -or [string]$actual.Value -cne [string]$tag.Value) {
      throw "Resource group ownership tag '$($tag.Name)' does not match."
    }
  }
  if ([string]$ResourceGroup.tags.'quickstart.provenanceId' -cne [string]$Contract.cleanup.provenanceId) {
    throw 'Resource group provenance does not match the cleanup contract.'
  }
  return $true
}

function Test-QuickstartCollection {
  param([AllowNull()]$Value)

  return $null -ne $Value -and
    $Value -is [System.Collections.IEnumerable] -and
    $Value -isnot [string] -and
    $Value -isnot [System.Collections.IDictionary] -and
    $Value -isnot [pscustomobject]
}

function Assert-QuickstartVerificationResponse {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Check,
    [AllowNull()]$Body,
    [switch]$FinalAttempt
  )

  switch ([string]$Check.kind) {
    'health' {
      if ($null -eq $Body -or [string]$Body.status -cne 'ok') {
        throw "Verification check '$($Check.id)' did not return healthy status."
      }
      return $true
    }
    'count' {
      if ([int]$Body -lt [int]$Check.minimum) {
        throw "Verification check '$($Check.id)' returned fewer items than required."
      }
      return $true
    }
    'indexer-status' {
      $lastResult = if ($null -ne $Body) { $Body.PSObject.Properties['lastResult'] } else { $null }
      $status = if ($null -ne $lastResult -and $null -ne $lastResult.Value) {
        [string]$lastResult.Value.status
      } else {
        ''
      }
      if ($status -ceq [string]$Check.successStatus) {
        return $true
      }
      if ($status -cin @($Check.failureStatuses | ForEach-Object { [string]$_ })) {
        throw "Verification check '$($Check.id)' reached terminal failure '$status'."
      }
      if ($FinalAttempt) {
        $displayStatus = if ([string]::IsNullOrWhiteSpace($status)) { 'no-last-result' } else { $status }
        throw "Verification check '$($Check.id)' did not reach terminal success; last state was '$displayStatus'."
      }
      return $false
    }
    'retrieval' {
      if ($null -eq $Body) {
        throw "Verification check '$($Check.id)' returned no response."
      }
      $resultsProperty = $Body.PSObject.Properties[[string]$Check.resultCollectionField]
      $citationsProperty = $Body.PSObject.Properties[[string]$Check.citationCollectionField]
      if ($null -eq $resultsProperty -or -not (Test-QuickstartCollection -Value $resultsProperty.Value) -or
          @($resultsProperty.Value).Count -eq 0) {
        throw "Verification check '$($Check.id)' returned no retrieval results."
      }
      if ($null -eq $citationsProperty -or -not (Test-QuickstartCollection -Value $citationsProperty.Value) -or
          @($citationsProperty.Value).Count -eq 0) {
        throw "Verification check '$($Check.id)' returned no citations."
      }
      foreach ($citation in @($citationsProperty.Value)) {
        $source = $citation.PSObject.Properties[[string]$Check.sourceIdField]
        if ($null -eq $source -or [string]::IsNullOrWhiteSpace([string]$source.Value)) {
          throw "Verification check '$($Check.id)' returned a citation without a source identifier."
        }
      }
      return $true
    }
    default {
      throw "Verification check '$($Check.id)' has unsupported response semantics."
    }
  }
}

function Invoke-QuickstartVerification {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Contract)

  Test-QuickstartContract -Contract $Contract | Out-Null
  $results = @()
  foreach ($check in @($Contract.verification.checks)) {
    $maxAttempts = if ([string]$check.kind -ceq 'indexer-status') { [int]$check.poll.maxAttempts } else { 1 }
    $intervalSeconds = if ([string]$check.kind -ceq 'indexer-status') { [int]$check.poll.intervalSeconds } else { 0 }
    $passed = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
      $result = Invoke-QuickstartHttp `
        -OperationId ([string]$check.id) `
        -Method ([string]$check.method) `
        -Uri ([string]$check.uri) `
        -Audience ([string]$check.audience) `
        -Body $(if ($null -ne $check.PSObject.Properties['body']) { $check.body } else { $null }) `
        -AcceptedStatusCodes @($check.acceptedStatusCodes | ForEach-Object { [int]$_ })
      $passed = Assert-QuickstartVerificationResponse -Check $check -Body $result.Body -FinalAttempt:($attempt -eq $maxAttempts)
      if ($passed) {
        break
      }
      Start-Sleep -Seconds $intervalSeconds
    }
    if (-not $passed) {
      throw "Verification check '$($check.id)' did not pass."
    }
    $results += [pscustomobject]@{
      Id = [string]$check.id
      Status = 'Passed'
      StatusCode = $result.StatusCode
    }
  }
  return $results
}

Export-ModuleMember -Function @(
  'Assert-QuickstartContractBinding'
  'Assert-QuickstartOwnership'
  'Assert-QuickstartVerificationResponse'
  'ConvertTo-QuickstartCanonicalJson'
  'Get-QuickstartAccessToken'
  'Get-QuickstartDeploymentContract'
  'Invoke-QuickstartAzJson'
  'Invoke-QuickstartDriftVerification'
  'Invoke-QuickstartOperations'
  'Invoke-QuickstartVerification'
  'Protect-QuickstartText'
  'Read-QuickstartContract'
  'Test-QuickstartContract'
)
