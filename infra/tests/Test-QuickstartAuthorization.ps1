#requires -Version 7.4
[CmdletBinding()]
param(
  [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Passed = 0
$module = Import-Module (Join-Path $RepositoryRoot 'scripts\quickstart\Quickstart.Common.psm1') -Force -PassThru
. (Join-Path $PSScriptRoot 'Quickstart.TestFixture.ps1')

function Assert-Authorization {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
  $script:Passed++
  Write-Host "PASS: $Message"
}

$acquiredToken = 'quickstart-fake-token-9f4c2b7e-do-not-leak'
$contract = New-TestQuickstartContract
$evidence = & $module {
  param($Token, $Contract)

  $script:OfflineAcquiredToken = $Token
  $script:OfflineTransportMode = 'Success'
  $script:CapturedAuthorization = $null
  $script:InterceptedRequests = 0
  $script:TokenRequests = 0

  function Get-QuickstartAccessToken {
    param([string]$Audience)
    $script:TokenRequests++
    return $script:OfflineAcquiredToken
  }

  function Invoke-WebRequest {
    [CmdletBinding()]
    param(
      [string]$Method,
      [string]$Uri,
      [hashtable]$Headers,
      [switch]$SkipHttpErrorCheck,
      [string]$StatusCodeVariable,
      [string]$ContentType,
      [string]$Body
    )

    $script:InterceptedRequests++
    $script:CapturedAuthorization = if ($null -eq $Headers) { $null } else { [string]$Headers.Authorization }
    if ($script:OfflineTransportMode -ceq 'Failure') {
      throw "transport failed; raw=$($script:OfflineAcquiredToken); Authorization: Bearer $($script:OfflineAcquiredToken)"
    }

    Set-Variable -Name $StatusCodeVariable -Value 200 -Scope 1
    return [pscustomobject]@{
      Content = '{}'
      Headers = @{ 'x-ms-request-id' = $script:OfflineAcquiredToken }
    }
  }

  $result = Invoke-QuickstartHttp `
    -OperationId 'offline-success' `
    -Method 'GET' `
    -Uri 'https://offline.invalid/intercepted' `
    -Audience 'https://search.azure.com/' `
    -Body $null `
    -AcceptedStatusCodes @(200)

  $authenticatedAuthorization = $script:CapturedAuthorization
  $tokenRequestsBeforeAnonymous = $script:TokenRequests
  Invoke-QuickstartHttp `
    -OperationId 'offline-anonymous-health' `
    -Method 'GET' `
    -Uri 'https://offline.invalid/health' `
    -Audience '' `
    -Body $null `
    -AcceptedStatusCodes @(200) | Out-Null
  $anonymousAuthorization = $script:CapturedAuthorization
  $tokenRequestsAfterAnonymous = $script:TokenRequests

  $report = Invoke-QuickstartOperations -Contract $Contract 6>&1 | Out-String
  $redactedLog = Protect-QuickstartText `
    -Text "log raw=$($script:OfflineAcquiredToken)" `
    -SensitiveValues @($script:OfflineAcquiredToken)

  $script:OfflineTransportMode = 'Failure'
  $errorMessage = ''
  try {
    Invoke-QuickstartHttp `
      -OperationId 'offline-failure' `
      -Method 'GET' `
      -Uri 'https://offline.invalid/intercepted' `
      -Audience 'https://search.azure.com/' `
      -Body $null `
      -AcceptedStatusCodes @(200)
  } catch {
    $errorMessage = $_.Exception.Message
  }

  [pscustomobject]@{
    AuthenticatedAuthorization = $authenticatedAuthorization
    AnonymousAuthorization = $anonymousAuthorization
    TokenRequestsBeforeAnonymous = $tokenRequestsBeforeAnonymous
    TokenRequestsAfterAnonymous = $tokenRequestsAfterAnonymous
    CorrelationId = $result.CorrelationId
    Report = $report
    RedactedLog = $redactedLog
    ErrorMessage = $errorMessage
    InterceptedRequests = $script:InterceptedRequests
  }
} $acquiredToken $contract

$maskOnlyAuthorization = '*' * 6
Assert-Authorization ($evidence.AuthenticatedAuthorization -cne $maskOnlyAuthorization) 'Outgoing Authorization header is not a literal mask'

Assert-Authorization ($evidence.AuthenticatedAuthorization -ceq "Bearer $acquiredToken") 'Outgoing Authorization header uses the Bearer scheme and acquired token'
Assert-Authorization ([string]::IsNullOrEmpty([string]$evidence.AnonymousAuthorization)) 'Anonymous health transport omits the Authorization header'
Assert-Authorization ($evidence.TokenRequestsAfterAnonymous -eq $evidence.TokenRequestsBeforeAnonymous) 'Anonymous health transport does not acquire an access token'
Assert-Authorization ($evidence.InterceptedRequests -gt 2) 'Local interceptor handled every HTTP request'
Assert-Authorization (-not $evidence.CorrelationId.Contains($acquiredToken)) 'Returned correlation metadata redacts the acquired token'
Assert-Authorization ($evidence.CorrelationId.Contains('<redacted>')) 'Returned correlation metadata uses a redaction marker'
Assert-Authorization (-not $evidence.Report.Contains($acquiredToken)) 'Operation reporting does not expose the acquired token'
Assert-Authorization ($evidence.Report.Contains('<redacted>')) 'Operation reporting uses a redaction marker'
Assert-Authorization (-not $evidence.RedactedLog.Contains($acquiredToken)) 'Log redaction does not expose the acquired token'
Assert-Authorization ($evidence.RedactedLog.Contains('<redacted>')) 'Log redaction uses a redaction marker'
Assert-Authorization (-not $evidence.ErrorMessage.Contains($acquiredToken)) 'Transport errors do not expose the acquired token'
Assert-Authorization ($evidence.ErrorMessage.Contains('<redacted>')) 'Transport errors retain useful redaction markers'

Write-Host "$script:Passed quickstart authorization checks passed; all HTTP requests were intercepted locally and no network operation occurred."
