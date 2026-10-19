Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Approve-QuickstartStoragePrivateLink {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)][string]$SubscriptionId
  )

  $storageId = [string]$Contract.resources.corpus.storageAccountId
  $sharedLink = $Contract.resources.search.storageSharedPrivateLink
  if ([string]$sharedLink.storageAccountId -cne $storageId) {
    throw 'Search shared private link is not bound to the owned corpus storage account.'
  }

  $connection = $null
  for ($attempt = 1; $attempt -le 30; $attempt++) {
    $connections = @(
      Invoke-QuickstartAzJson -Arguments @(
        'network', 'private-endpoint-connection', 'list',
        '--subscription', $SubscriptionId,
        '--id', $storageId,
        '--output', 'json'
      ) -Phase 'Search private endpoint connection discovery'
    )
    $matches = @($connections | Where-Object {
        [string]$_.properties.privateLinkServiceConnectionState.description -ceq [string]$sharedLink.requestMessage
      })
    if ($matches.Count -gt 1) {
      throw 'More than one Storage private endpoint connection matches the quickstart Search request.'
    }
    if ($matches.Count -eq 1) {
      $connection = $matches[0]
      break
    }
    Start-Sleep -Seconds 10
  }
  if ($null -eq $connection) {
    throw 'The Storage-side private endpoint connection for Search was not created.'
  }

  $status = [string]$connection.properties.privateLinkServiceConnectionState.status
  if ($status -ceq 'Pending') {
    & az network private-endpoint-connection approve `
      --subscription $SubscriptionId `
      --id ([string]$connection.id) `
      --description ([string]$sharedLink.requestMessage) `
      --output none `
      --only-show-errors
    if ($LASTEXITCODE -ne 0) {
      throw 'Search private endpoint connection approval failed.'
    }
  } elseif ($status -cne 'Approved') {
    throw "Search private endpoint connection has unsupported status '$status'."
  }

  $sharedLinkUri = "https://management.azure.com$([string]$sharedLink.id)?api-version=$([string]$sharedLink.apiVersion)"
  for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
      $state = Invoke-QuickstartAzJson -Arguments @(
        'rest', '--method', 'GET', '--uri', $sharedLinkUri, '--output', 'json'
      ) -Phase 'Search shared private link readiness'
    } catch {
      if ($_.Exception.Message -notmatch '(?i)Too Many Requests|status\s*429') {
        throw
      }
      Start-Sleep -Seconds 10
      continue
    }
    if ([string]$state.properties.provisioningState -ceq 'Succeeded' -and
        [string]$state.properties.status -ceq 'Approved') {
      return
    }
    if ([string]$state.properties.provisioningState -in @('Failed', 'Incomplete') -or
        [string]$state.properties.status -in @('Rejected', 'Disconnected')) {
      throw "Search shared private link entered terminal state '$([string]$state.properties.provisioningState)/$([string]$state.properties.status)'."
    }
    Start-Sleep -Seconds 10
  }
  throw 'Search shared private link did not become ready within the bounded wait.'
}

function Test-QuickstartPrivateStorage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)][string]$SubscriptionId
  )

  $storage = Invoke-QuickstartAzJson -Arguments @(
    'storage', 'account', 'show',
    '--subscription', $SubscriptionId,
    '--ids', ([string]$Contract.resources.corpus.storageAccountId),
    '--output', 'json'
  ) -Phase 'Private Storage verification'
  if ([string]$storage.publicNetworkAccess -cne 'Disabled' -or $storage.allowSharedKeyAccess -ne $false) {
    throw 'Owned Storage must disable public network and shared-key access.'
  }

  $privateEndpointIds = @($Contract.resources.network.privateEndpointIds)
  if ($privateEndpointIds.Count -ne 4) {
    throw 'Private Storage contract must contain exactly four private endpoints.'
  }
  foreach ($privateEndpointId in $privateEndpointIds) {
    $endpoint = Invoke-QuickstartAzJson -Arguments @(
      'network', 'private-endpoint', 'show',
      '--subscription', $SubscriptionId,
      '--ids', ([string]$privateEndpointId),
      '--output', 'json'
    ) -Phase 'Storage private endpoint verification'
    $connections = @($endpoint.privateLinkServiceConnections)
    if ($connections.Count -ne 1 -or
        [string]$connections[0].privateLinkServiceConnectionState.status -cne 'Approved') {
      throw "Storage private endpoint '$privateEndpointId' is not approved."
    }
  }

  $privateDnsZoneIds = @($Contract.resources.network.privateDnsZoneIds)
  if ($privateDnsZoneIds.Count -ne 4) {
    throw 'Private Storage contract must contain exactly four private DNS zones.'
  }
  foreach ($zoneId in $privateDnsZoneIds) {
    $null = Invoke-QuickstartAzJson -Arguments @(
      'network', 'private-dns', 'zone', 'show',
      '--subscription', $SubscriptionId,
      '--ids', ([string]$zoneId),
      '--output', 'json'
    ) -Phase 'Storage private DNS verification'
  }

  $sharedLink = $Contract.resources.search.storageSharedPrivateLink
  $sharedLinkState = Invoke-QuickstartAzJson -Arguments @(
    'rest',
    '--method', 'GET',
    '--uri', "https://management.azure.com$([string]$sharedLink.id)?api-version=$([string]$sharedLink.apiVersion)",
    '--output', 'json'
  ) -Phase 'Search shared private link verification'
  if ([string]$sharedLinkState.properties.provisioningState -cne 'Succeeded' -or
      [string]$sharedLinkState.properties.status -cne 'Approved') {
    throw 'Search shared private link is not approved and ready.'
  }

  $functionIntegration = Invoke-QuickstartAzJson -Arguments @(
    'rest',
    '--method', 'GET',
    '--uri', "https://management.azure.com$([string]$Contract.resources.function.id)/networkConfig/virtualNetwork?api-version=2023-12-01",
    '--output', 'json'
  ) -Phase 'Function VNet integration verification'
  if ([string]$functionIntegration.properties.subnetResourceId -cne [string]$Contract.resources.function.integrationSubnetId) {
    throw 'Function VNet integration is not bound to the owned integration subnet.'
  }
}

function Invoke-QuickstartPrivateBlobUpload {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,20}$')][string]$UploadName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$SourceFiles,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Destinations,
    [Parameter(Mandatory)][string]$ContainerName,
    [switch]$BuildPythonFunctionPackage
  )

  if ($SourceFiles.Count -eq 0 -or (-not $BuildPythonFunctionPackage -and $SourceFiles.Count -ne $Destinations.Count)) {
    throw 'Private upload source and destination collections must be non-empty and have equal lengths unless a Function package is being built.'
  }
  if ($BuildPythonFunctionPackage -and $Destinations.Count -ne 1) {
    throw 'A private Function package build requires exactly one destination Blob.'
  }
  if (@($Destinations | Group-Object | Where-Object Count -gt 1).Count -ne 0) {
    throw 'Private upload destination paths must be unique.'
  }

  $stageRoot = Join-Path ([IO.Path]::GetTempPath()) "quickstart-upload-$([guid]::NewGuid().ToString('N'))"
  $archivePath = "$stageRoot.tar.gz"
  $yamlPath = "$stageRoot.yaml"
  $containerGroupName = "aci-$UploadName-$(([string]$Contract.deployment.deploymentId).Substring(0, 8))"
  $containerCreated = $false
  try {
    New-Item -ItemType Directory -Path $stageRoot | Out-Null
    $manifest = [System.Collections.Generic.List[object]]::new()
    $sourceNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $SourceFiles.Count; $index++) {
      $source = Get-Item -LiteralPath $SourceFiles[$index] -ErrorAction Stop
      if ($source.PSIsContainer) {
        throw "Private upload source must be a file: $($source.FullName)"
      }
      if ($BuildPythonFunctionPackage -and
          ($source.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or -not $sourceNames.Add($source.Name))) {
        throw "Function package source name is unsafe or duplicated: $($source.Name)"
      }
      $destination = if ($BuildPythonFunctionPackage) { $Destinations[0] } else { $Destinations[$index] }
      if ([string]::IsNullOrWhiteSpace($destination) -or
          $destination.StartsWith('/') -or
          $destination.Contains('\') -or
          $destination.Contains(':') -or
          $destination -match '(^|/)\.\.?(/|$)' -or
          $destination -match '[\x00-\x1f]') {
        throw "Private upload destination is unsafe: $destination"
      }
      $stageName = "file-$index$($source.Extension)"
      Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $stageRoot $stageName)
      $manifest.Add([ordered]@{
          stage = $stageName
          sourceName = $source.Name
          destination = $destination
        })
    }
    if ($BuildPythonFunctionPackage -and
        (-not $sourceNames.Contains('host.json') -or -not $sourceNames.Contains('requirements.txt'))) {
      throw 'A Function package build requires host.json and requirements.txt at the package root.'
    }
    ConvertTo-Json -InputObject ([object[]]$manifest) -Compress | Set-Content -LiteralPath (Join-Path $stageRoot 'manifest.json') -Encoding ascii
    & tar -czf $archivePath -C $stageRoot .
    if ($LASTEXITCODE -ne 0) {
      throw 'Private upload payload packaging failed.'
    }
    $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($archivePath))
    if ($payload.Length -gt 60000) {
      throw 'Private upload payload exceeds the reviewed ACI secure environment-variable limit.'
    }

    $resourceGroupName = [string]$Contract.deployment.resourceGroupName
    $storageAccountName = [string]$Contract.resources.corpus.storageAccountName
    $uploadIdentityId = [string]$Contract.resources.network.uploadIdentityId
    $uploadIdentityClientId = [string]$Contract.resources.network.uploadIdentityClientId
    $uploadSubnetId = [string]$Contract.resources.network.uploadSubnetId
    $location = [string]$Contract.deployment.location
    $deploymentId = [string]$Contract.deployment.deploymentId
    $scriptLines = @(
      'set -euo pipefail'
      'mkdir -p /data'
      'python3 -c ''import base64,io,os,tarfile; tarfile.open(fileobj=io.BytesIO(base64.b64decode(os.environ["PAYLOAD_B64"]))).extractall("/data", filter="data")'''
    )
    if ($BuildPythonFunctionPackage) {
      $scriptLines += @(
        'mkdir -p /data/package/.python_packages/lib/site-packages'
        'python3 - <<''PY'''
        'import json, os, shutil'
        'with open("/data/manifest.json", encoding="utf-8") as stream:'
        '    manifest = json.load(stream)'
        'for item in manifest:'
        '    shutil.copyfile("/data/" + item["stage"], "/data/package/" + item["sourceName"])'
        'PY'
        'python3 -m pip --version >/dev/null 2>&1 || tdnf install -y python3-pip'
        'python3 -m pip install --disable-pip-version-check --no-cache-dir --only-binary=:all: --target /data/package/.python_packages/lib/site-packages -r /data/package/requirements.txt'
        'PYTHONPATH=/data/package/.python_packages/lib/site-packages:/data/package python3 -c ''import function_app; assert len(function_app.app.get_functions()) == 2, "Function package must expose exactly two triggers"'''
        'python3 - <<''PY'''
        'import os, zipfile'
        'with zipfile.ZipFile("/data/function-package.zip", "w", zipfile.ZIP_DEFLATED) as archive:'
        '    for root, _, files in os.walk("/data/package"):'
        '        for name in files:'
        '            path = os.path.join(root, name)'
        '            archive.write(path, os.path.relpath(path, "/data/package"))'
        'PY'
        'az login --identity --username "$UAMI_CLIENT_ID" --output none'
        'az storage blob upload --account-name "$STORAGE_ACCOUNT" --container-name "$CONTAINER" --name "$FUNCTION_PACKAGE_DESTINATION" --file /data/function-package.zip --auth-mode login --overwrite true --output none'
      )
    } else {
      $scriptLines += @(
        'az login --identity --username "$UAMI_CLIENT_ID" --output none'
        'python3 - <<''PY'''
        'import json, os, subprocess'
        'with open("/data/manifest.json", encoding="utf-8") as stream:'
        '    manifest = json.load(stream)'
        'for item in manifest:'
        '    subprocess.run(["az", "storage", "blob", "upload", "--account-name", os.environ["STORAGE_ACCOUNT"], "--container-name", os.environ["CONTAINER"], "--name", item["destination"], "--file", "/data/" + item["stage"], "--auth-mode", "login", "--overwrite", "true", "--output", "none"], check=True)'
        'PY'
      )
    }
    $indentedScript = ($scriptLines | ForEach-Object { "            $_" }) -join [Environment]::NewLine
    $yaml = @"
apiVersion: '2021-10-01'
location: $location
name: $containerGroupName
identity:
  type: UserAssigned
  userAssignedIdentities:
    ${uploadIdentityId}: {}
properties:
  osType: Linux
  restartPolicy: Never
  subnetIds:
    - id: $uploadSubnetId
  containers:
    - name: uploader
      properties:
        image: mcr.microsoft.com/azure-cli:2.67.0
        command:
          - /bin/bash
          - -c
          - |-
$indentedScript
        resources:
          requests:
            cpu: 1.0
            memoryInGB: 1.0
        environmentVariables:
          - name: STORAGE_ACCOUNT
            value: $storageAccountName
          - name: CONTAINER
            value: $ContainerName
          - name: UAMI_CLIENT_ID
            value: $uploadIdentityClientId
          - name: FUNCTION_PACKAGE_DESTINATION
            value: $($Destinations[0])
          - name: PAYLOAD_B64
            secureValue: $payload
tags:
  quickstart.owner: financial-services-knowledge-quickstart
  quickstart.deploymentId: $deploymentId
type: Microsoft.ContainerInstance/containerGroups
"@
    Set-Content -LiteralPath $yamlPath -Value $yaml -Encoding utf8NoBOM

    & az container create `
      --subscription $SubscriptionId `
      --resource-group $resourceGroupName `
      --file $yamlPath `
      --output none `
      --only-show-errors
    if ($LASTEXITCODE -ne 0) {
      $exists = & az container exists --subscription $SubscriptionId --resource-group $resourceGroupName --name $containerGroupName --output tsv --only-show-errors
      $containerCreated = $LASTEXITCODE -eq 0 -and ($exists -join '').Trim() -eq 'true'
      throw "Private Blob upload container '$containerGroupName' could not be created."
    }
    $containerCreated = $true

    for ($waited = 0; $waited -lt 600; $waited += 5) {
      $state = & az container show `
        --subscription $SubscriptionId `
        --resource-group $resourceGroupName `
        --name $containerGroupName `
        --query 'containers[0].instanceView.currentState.state' `
        --output tsv `
        --only-show-errors
      if ($LASTEXITCODE -ne 0) {
        throw 'Private Blob upload status check failed.'
      }
      if (($state -join '').Trim() -eq 'Terminated') {
        break
      }
      Start-Sleep -Seconds 5
    }
    $exitCode = & az container show `
      --subscription $SubscriptionId `
      --resource-group $resourceGroupName `
      --name $containerGroupName `
      --query 'containers[0].instanceView.currentState.exitCode' `
      --output tsv `
      --only-show-errors
    if ($LASTEXITCODE -ne 0 -or ($exitCode -join '').Trim() -ne '0') {
      & az container logs --subscription $SubscriptionId --resource-group $resourceGroupName --name $containerGroupName --only-show-errors
      throw "Private Blob upload '$UploadName' failed."
    }
  } finally {
    if ($containerCreated) {
      & az container delete `
        --subscription $SubscriptionId `
        --resource-group ([string]$Contract.deployment.resourceGroupName) `
        --name $containerGroupName `
        --yes `
        --output none `
        --only-show-errors
    }
    Remove-Item -LiteralPath $stageRoot, $archivePath, $yamlPath -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Export-ModuleMember -Function @(
  'Approve-QuickstartStoragePrivateLink'
  'Invoke-QuickstartPrivateBlobUpload'
  'Test-QuickstartPrivateStorage'
)
