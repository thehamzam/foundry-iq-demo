#!/usr/bin/env pwsh
<##
.SYNOPSIS
  Uploads explicitly selected files to the private Blob container without replacing existing blobs.

.DESCRIPTION
  Uses the Bicep-managed upload UAMI, VNet and delegated ACI subnet. The source
  files are staged into a short-lived base64 tar.gz payload and uploaded by a
  one-shot Azure Container Instance using Entra authentication. Existing blob
  destinations are rejected before any upload. Packages under the current
  user's TEMP root require an explicitly supplied SHA-256 or positive length.

.EXAMPLE
  ./scripts/maintenance/upload-private-blob-additive.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -ResourceGroup 'rg-demofs-demo' -StorageAccount 'stdemofs' `
    -StorageContainer 'knowledge' -Location 'eastus' `
    -PackagePath './custom-skill/custom-skill-2026-09-15.zip' `
    -PackageDestination 'packages/custom-skill-2026-09-15.zip'

.EXAMPLE
  ./scripts/maintenance/upload-private-blob-additive.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -ResourceGroup 'rg-demofs-demo' -StorageAccount 'stdemofs' `
    -StorageContainer 'knowledge' -Location 'eastus' `
    -DocumentPaths @('./sample-data/documents/PROC-CHUNKLAB-101-synthetic-duplicate-intake.md', './sample-data/documents/RUN-CHUNKLAB-202-synthetic-fraud-escalation.md') `
    -DocumentDestinations @('PROC-CHUNKLAB-101-synthetic-duplicate-intake.md', 'RUN-CHUNKLAB-202-synthetic-fraud-escalation.md')
#>

[CmdletBinding(DefaultParameterSetName = 'Package')]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ResourceGroup,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$StorageAccount,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$StorageContainer,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Location,

  [string]$UamiName = 'uami-demofs-upload',
  [string]$VnetName = 'vnet-demofs-demo',
  [string]$AciSubnetName = 'snet-aci',
  [string]$AciName = 'aci-demofs-upload-additive',

  [Parameter(Mandatory = $true, ParameterSetName = 'Package')]
  [ValidateNotNullOrEmpty()]
  [string]$PackagePath,

  [Parameter(Mandatory = $true, ParameterSetName = 'Package')]
  [ValidateNotNullOrEmpty()]
  [string]$PackageDestination,

  [Parameter(Mandatory = $false, ParameterSetName = 'Package')]
  [ValidatePattern('^[0-9a-fA-F]{64}$')]
  [string]$PackageSha256,

  [Parameter(Mandatory = $false, ParameterSetName = 'Package')]
  [ValidateRange(1, [long]::MaxValue)]
  [long]$PackageLength,

  [Parameter(Mandatory = $true, ParameterSetName = 'Documents')]
  [ValidateNotNullOrEmpty()]
  [string[]]$DocumentPaths,

  [Parameter(Mandatory = $true, ParameterSetName = 'Documents')]
  [ValidateNotNullOrEmpty()]
  [string[]]$DocumentDestinations
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resourceRoot = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers"

function Invoke-AzJson {
  param([Parameter(Mandatory = $true)][string[]]$Arguments, [string]$FailureMessage = 'Azure CLI operation failed.')
  $result = & az @Arguments --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
  return ($result | ConvertFrom-Json)
}

function Get-UploadPrerequisite {
  param([Parameter(Mandatory = $true)][string]$ResourceId, [Parameter(Mandatory = $true)][string]$ApiVersion)
  $resource = Invoke-AzJson @('rest', '--method', 'GET', '--uri', "https://management.azure.com${ResourceId}?api-version=$ApiVersion") "Cannot read prerequisite $ResourceId."
  if ($resource.id -ne $ResourceId) { throw "Unexpected prerequisite resource ID for $ResourceId." }
  return $resource
}

function Resolve-ApprovedFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ApprovedRoot,
    [Parameter(Mandatory = $true)][string]$Mode
  )
  $file = Get-Item -LiteralPath $Path -ErrorAction Stop
  if ($file.PSIsContainer) { throw "Source must be a file: $Path" }
  $root = (Resolve-Path -LiteralPath $ApprovedRoot).Path.TrimEnd('\') + '\'
  if (-not $file.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Source is outside the approved $Mode root: $Path"
  }
  if ($Mode -eq 'Document' -and $file.Extension -ne '.md') { throw "Document mode accepts Markdown files only: $Path" }
  if ($file.Name -ieq 'evaluation-queries.json') { throw 'evaluation-queries.json is not an uploadable source.' }
  return $file
}

function Resolve-ApprovedPackage {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ApprovedRoot,
    [string]$PackageSha256,
    [long]$PackageLength
  )
  $file = Get-Item -LiteralPath $Path -ErrorAction Stop
  if ($file.PSIsContainer) { throw "Source must be a file: $Path" }
  if ($file.Extension -ne '.zip') { throw 'PackagePath must be a ZIP file.' }

  $approvedRootPath = (Resolve-Path -LiteralPath $ApprovedRoot).Path.TrimEnd('\') + '\'
  $tempRootPaths = @([System.IO.Path]::GetTempPath(), $env:TEMP) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { (Resolve-Path -LiteralPath $_).Path.TrimEnd('\') + '\' } |
    Select-Object -Unique
  $isCustomSkillPackage = $file.FullName.StartsWith($approvedRootPath, [StringComparison]::OrdinalIgnoreCase)
  $isTempPackage = @($tempRootPaths | Where-Object { $file.FullName.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
  if (-not $isCustomSkillPackage -and -not $isTempPackage) {
    throw "Source is outside the approved custom-skill or current user's TEMP root: $Path"
  }
  if ($isCustomSkillPackage -and $file.Name -notmatch '^custom-skill(?:[-_].*)?\.zip$') {
    throw 'PackagePath must be the intended custom-skill ZIP (custom-skill*.zip).'
  }
  $hasPackageSha256 = $PSBoundParameters.ContainsKey('PackageSha256') -and -not [string]::IsNullOrWhiteSpace($PackageSha256)
  $hasPackageLength = $PSBoundParameters.ContainsKey('PackageLength') -and $PackageLength -gt 0
  if ($isTempPackage -and -not ($hasPackageSha256 -or $hasPackageLength)) {
    throw 'TEMP packages require at least one integrity constraint: non-empty PackageSha256 or positive PackageLength.'
  }
  if ($hasPackageLength -and $file.Length -ne $PackageLength) { throw 'Package length does not match PackageLength.' }
  if ($hasPackageSha256) {
    $actualHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if ($actualHash -ne $PackageSha256) { throw 'Package SHA-256 does not match PackageSha256.' }
  }
  return $file
}

function Assert-SafeBlobPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('/') -or $Path.Contains('\') -or $Path -match '(^|/)\.\.(/|$)' -or $Path -match '(^|/)\.(/|$)' -or $Path.Contains(':')) {
    throw "Unsafe destination blob path: $Path"
  }
  if ($Path -match '[\x00-\x1f]') { throw "Unsafe destination blob path: $Path" }
}

function ConvertTo-SingleQuotedBashLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)
  return "'" + $Value.Replace("'", "'\\''") + "'"
}

$storageId = "$resourceRoot/Microsoft.Storage/storageAccounts/$StorageAccount"
$uamiId = "$resourceRoot/Microsoft.ManagedIdentity/userAssignedIdentities/$UamiName"
$aciSubnetId = "$resourceRoot/Microsoft.Network/virtualNetworks/$VnetName/subnets/$AciSubnetName"
$privateEndpointId = "$resourceRoot/Microsoft.Network/privateEndpoints/pe-$StorageAccount-blob"
$zoneId = "$resourceRoot/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"

$selected = [System.Collections.Generic.List[object]]::new()
if ($PSCmdlet.ParameterSetName -eq 'Package') {
  $packageArguments = @{
    Path = $PackagePath
    ApprovedRoot = Join-Path $RepoRoot 'custom-skill'
  }
  if ($PSBoundParameters.ContainsKey('PackageSha256')) { $packageArguments.PackageSha256 = $PackageSha256 }
  if ($PSBoundParameters.ContainsKey('PackageLength')) { $packageArguments.PackageLength = $PackageLength }
  $packageFile = Resolve-ApprovedPackage @packageArguments
  Assert-SafeBlobPath $PackageDestination
  $selected.Add([pscustomobject]@{ File = $packageFile; Destination = $PackageDestination; Kind = 'package' })
} else {
  if ($DocumentPaths.Count -ne $DocumentDestinations.Count) { throw 'DocumentPaths and DocumentDestinations must have the same number of entries.' }
  $documentsRoot = Join-Path $RepoRoot 'sample-data\documents'
  for ($index = 0; $index -lt $DocumentPaths.Count; $index++) {
    $document = Resolve-ApprovedFile -Path $DocumentPaths[$index] -ApprovedRoot $documentsRoot -Mode 'document'
    Assert-SafeBlobPath $DocumentDestinations[$index]
    $selected.Add([pscustomobject]@{ File = $document; Destination = $DocumentDestinations[$index]; Kind = 'document' })
  }
}
if ($selected.Count -eq 0) { throw 'Select at least one explicit source file.' }
if (@($selected.Destination | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw 'Duplicate destination blob paths are not allowed.' }

Write-Host "→ Validating private upload prerequisites for $($selected.Count) selected file(s)" -ForegroundColor Cyan
az account set --subscription $SubscriptionId --output none
if ($LASTEXITCODE -ne 0) { throw 'Cannot select the requested subscription.' }
$storage = Get-UploadPrerequisite $storageId '2023-05-01'
if ($storage.properties.publicNetworkAccess -ne 'Disabled' -or $storage.properties.allowSharedKeyAccess -eq $true) { throw 'Storage must disable public network access and shared-key auth.' }
$uami = Get-UploadPrerequisite $uamiId '2023-01-31'
if (-not $uami.properties.principalId -or -not $uami.properties.clientId) { throw 'Upload UAMI is incomplete.' }
$assignments = @(Invoke-AzJson @('role', 'assignment', 'list', '--scope', $storageId) 'Cannot read upload RBAC.')
$uploadRole = @($assignments | Where-Object {
  $_.principalId -eq $uami.properties.principalId -and $_.principalType -eq 'ServicePrincipal' -and
  $_.scope -eq $storageId -and $_.roleDefinitionId.Split('/')[-1] -eq 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' -and [string]::IsNullOrEmpty($_.condition)
})
if ($uploadRole.Count -eq 0) { throw 'Missing storage-scoped Upload MI Blob Data Contributor.' }
$container = Get-UploadPrerequisite "$storageId/blobServices/default/containers/$StorageContainer" '2023-05-01'
if ($container.properties.publicAccess -ne 'None') { throw 'Blob container must have public access disabled.' }
$subnet = Get-UploadPrerequisite $aciSubnetId '2024-05-01'
if (-not ($subnet.properties.delegations | Where-Object { $_.properties.serviceName -eq 'Microsoft.ContainerInstance/containerGroups' })) { throw 'ACI subnet delegation is missing.' }
$privateEndpoint = Get-UploadPrerequisite $privateEndpointId '2024-05-01'
if (-not ($privateEndpoint.properties.privateLinkServiceConnections | Where-Object { $_.properties.privateLinkServiceId -eq $storageId -and 'blob' -in $_.properties.groupIds -and $_.properties.privateLinkServiceConnectionState.status -eq 'Approved' })) { throw 'Approved Blob private endpoint is missing.' }
$zoneGroup = Get-UploadPrerequisite "$privateEndpointId/privateDnsZoneGroups/default" '2024-05-01'
$dnsLink = Get-UploadPrerequisite "$zoneId/virtualNetworkLinks/link-vnet-demofs-demo" '2020-06-01'
if (-not ($zoneGroup.properties.privateDnsZoneConfigs | Where-Object { $_.properties.privateDnsZoneId -eq $zoneId }) -or $dnsLink.properties.virtualNetwork.id -ne "$resourceRoot/Microsoft.Network/virtualNetworks/$VnetName") { throw 'Private Blob DNS is not linked to the upload VNet.' }
$regState = az provider show -n Microsoft.ContainerInstance --query registrationState -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or $regState -ne 'Registered') { throw 'Microsoft.ContainerInstance must be registered.' }

$stageRoot = Join-Path $env:TEMP "demofs-additive-$([guid]::NewGuid().ToString('N'))"
$tarPath = "$stageRoot.tar.gz"
$yamlPath = "$stageRoot.yaml"
$aciCreated = $false
try {
  New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
  $manifest = [System.Collections.Generic.List[object]]::new()
  foreach ($item in $selected) {
    $stageName = "file-$($manifest.Count)$($item.File.Extension)"
    Copy-Item -LiteralPath $item.File.FullName -Destination (Join-Path $stageRoot $stageName)
    $manifest.Add([pscustomobject]@{ Stage = $stageName; Destination = $item.Destination })
  }
  ConvertTo-Json -InputObject @($manifest.ToArray()) -Compress | Set-Content -LiteralPath (Join-Path $stageRoot 'manifest.json') -Encoding ascii
  tar -czf $tarPath -C $stageRoot .
  $tarB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($tarPath))

  $manifestJson = $manifest | ConvertTo-Json -Compress
  $bashLines = @(
    'set -euo pipefail',
    'mkdir -p /data',
    'python3 -c ''import base64,io,os,tarfile; tarfile.open(fileobj=io.BytesIO(base64.b64decode(os.environ["PAYLOAD_B64"]))).extractall("/data")''',
    'az login --identity --username "$UAMI_CLIENT_ID" --output none',
    'python3 - <<''PY''',
    'import json, os, subprocess',
    'manifest = json.load(open("/data/manifest.json"))',
    'for item in manifest:',
    '    exists = subprocess.run(["az", "storage", "blob", "exists", "--account-name", os.environ["STORAGE_ACCOUNT"], "--container-name", os.environ["CONTAINER"], "--name", item["Destination"], "--auth-mode", "login", "--query", "exists", "-o", "tsv"], check=True, stdout=subprocess.PIPE, text=True).stdout.strip()',
    '    if exists == "true": raise RuntimeError("destination already exists: " + item["Destination"])',
    'PY',
    'python3 - <<''PY''',
    'import json, os, subprocess',
    'manifest = json.load(open("/data/manifest.json"))',
    'for item in manifest:',
    '    subprocess.run(["az", "storage", "blob", "upload", "--account-name", os.environ["STORAGE_ACCOUNT"], "--container-name", os.environ["CONTAINER"], "--name", item["Destination"], "--file", "/data/" + item["Stage"], "--auth-mode", "login", "--overwrite", "false", "--output", "none"], check=True)',
    'PY',
    'echo additive upload complete'
  )
  $indented = ($bashLines | ForEach-Object { '            ' + $_ }) -join "`n"
  $aciYaml = @"
apiVersion: '2021-10-01'
location: $Location
name: $AciName
identity:
  type: UserAssigned
  userAssignedIdentities:
    ${uamiId}: {}
properties:
  osType: Linux
  restartPolicy: Never
  subnetIds:
    - id: $aciSubnetId
  containers:
    - name: uploader
      properties:
        image: mcr.microsoft.com/azure-cli:2.67.0
        command:
          - /bin/bash
          - -c
          - |-
$indented
        resources:
          requests: { cpu: 1.0, memoryInGB: 1.0 }
        environmentVariables:
          - name: STORAGE_ACCOUNT
            value: $StorageAccount
          - name: CONTAINER
            value: $StorageContainer
          - name: UAMI_CLIENT_ID
            value: $($uami.properties.clientId)
          - name: PAYLOAD_B64
            secureValue: $tarB64
tags: {}
type: Microsoft.ContainerInstance/containerGroups
"@
  Set-Content -LiteralPath $yamlPath -Value $aciYaml -Encoding utf8
  Write-Host "→ Launching private ACI $AciName in $AciSubnetName" -ForegroundColor Cyan
  az container create --resource-group $ResourceGroup --file $yamlPath --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'ACI creation failed.' }
  $aciCreated = $true
  $maxWaitSec = 600
  for ($waited = 0; $waited -lt $maxWaitSec; $waited += 5) {
    $state = az container show --name $AciName --resource-group $ResourceGroup --query 'containers[0].instanceView.currentState.state' -o tsv --only-show-errors 2>$null
    if ($state -eq 'Terminated') { break }
    Start-Sleep -Seconds 5
  }
  $exitCode = az container show --name $AciName --resource-group $ResourceGroup --query 'containers[0].instanceView.currentState.exitCode' -o tsv --only-show-errors
  Write-Host "→ ACI completed with exit code $exitCode" -ForegroundColor Cyan
  az container logs --name $AciName --resource-group $ResourceGroup --only-show-errors
  if ($exitCode -ne '0') { throw "Additive upload failed with exit code $exitCode." }
  Write-Host '✓ Selected blobs uploaded additively; existing destinations were not overwritten.' -ForegroundColor Green
} finally {
  if ($aciCreated) { az container delete --name $AciName --resource-group $ResourceGroup --yes --output none --only-show-errors }
  Remove-Item -LiteralPath $stageRoot, $tarPath, $yamlPath -Force -Recurse -ErrorAction SilentlyContinue
}