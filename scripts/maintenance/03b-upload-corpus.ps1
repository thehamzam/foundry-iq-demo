#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Uploads the demo corpus to the private storage account via a one-shot Azure
  Container Instance running inside the Bicep-managed VNet.

.DESCRIPTION
  Idempotent — safe to re-run. Each run:
    - Validates the Bicep-owned upload identity, storage role and network resources
    - Packs sample-data/documents/ into a base64-encoded tar.gz env var
    - Launches an ACI in the VNet's ACI subnet, attached to the UAMI
    - The container decodes the tarball, az login --identity, uploads via AAD
    - Waits for the ACI to exit, prints its logs, then tears the ACI down

  Requirements:
    - Approved Bicep deployment completed (identity, RBAC, VNet, PE, DNS, container)
    - Contributor on the resource group

.EXAMPLE
  ./scripts/maintenance/03b-upload-corpus.ps1
#>

[CmdletBinding()]
param()

function Get-UploadPrerequisite {
  param([string]$ResourceId, [string]$ApiVersion)
  $resourceJson = az rest --method GET --uri "https://management.azure.com${ResourceId}?api-version=$ApiVersion" -o json --only-show-errors
  if ($LASTEXITCODE -ne 0) {
    throw "Cannot read infrastructure prerequisite $ResourceId. Check authorization and run the approved Bicep deployment."
  }
  $resource = $resourceJson | ConvertFrom-Json
  if ($resource.id -ne $ResourceId) { throw "Unexpected prerequisite resource ID. Expected $ResourceId; run the approved Bicep deployment." }
  return $resource
}

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# --- Load config/demo.env ---
Get-Content "$RepoRoot/config/demo.env" | ForEach-Object {
  if ($_ -match '^\s*#') { return }
  if ($_ -match '^\s*$') { return }
  $key, $value = $_ -split '=', 2
  Set-Item -Path "env:$($key.Trim())" -Value $value.Trim()
}

# --- Resource names ---
$uamiName      = 'uami-demofs-upload'
$aciName       = 'aci-demofs-upload'
$vnetName      = 'vnet-demofs-demo'
$aciSubnetName = 'snet-aci'
# The public corpus contains explicitly synthetic ChunkingLab documents only.
$corpusDir     = "$RepoRoot/sample-data/documents"

Write-Host "→ Setting subscription $env:AZURE_SUBSCRIPTION_ID" -ForegroundColor Cyan
az account set --subscription $env:AZURE_SUBSCRIPTION_ID --output none
if ($LASTEXITCODE -ne 0) { throw 'Cannot select the configured subscription.' }

$resourceRoot = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers"
$storageId = "$resourceRoot/Microsoft.Storage/storageAccounts/$($env:AZURE_STORAGE_ACCOUNT)"
$storage = Get-UploadPrerequisite $storageId '2023-05-01'
if ($storage.properties.publicNetworkAccess -ne 'Disabled') { throw 'Storage differs from the approved private-network baseline. Check Bicep prerequisites.' }
$uamiId = "$resourceRoot/Microsoft.ManagedIdentity/userAssignedIdentities/$uamiName"
$uami = Get-UploadPrerequisite $uamiId '2023-01-31'
$uamiPrincipalId = $uami.properties.principalId
$uamiClientId = $uami.properties.clientId
if (-not $uamiPrincipalId -or -not $uamiClientId) { throw 'Upload identity is incomplete. Run the approved Bicep deployment.' }
$assignmentsJson = az role assignment list --scope $storageId --all -o json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Cannot read upload RBAC. Check authorization; no changes were made.' }
$assignment = @($assignmentsJson | ConvertFrom-Json | Where-Object {
  $_.principalId -eq $uamiPrincipalId -and $_.principalType -eq 'ServicePrincipal' -and
  $_.scope -eq $storageId -and $_.roleDefinitionId.Split('/')[-1] -eq 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' -and
  [string]::IsNullOrEmpty($_.condition)
})
if ($assignment.Count -eq 0) { throw 'Missing storage-scoped Upload MI Blob Data Contributor. Run the approved Bicep deployment.' }
$container = Get-UploadPrerequisite "$storageId/blobServices/default/containers/$($env:AZURE_STORAGE_CONTAINER)" '2023-05-01'
if ($container.properties.publicAccess -ne 'None') { throw 'Container differs from the approved private-access baseline. Check Bicep prerequisites.' }
$aciSubnetId = "$resourceRoot/Microsoft.Network/virtualNetworks/$vnetName/subnets/$aciSubnetName"
$subnet = Get-UploadPrerequisite $aciSubnetId '2024-05-01'
if (-not ($subnet.properties.delegations | Where-Object { $_.properties.serviceName -eq 'Microsoft.ContainerInstance/containerGroups' })) {
  throw 'ACI subnet delegation is missing. Run the approved Bicep deployment.'
}
$privateEndpointId = "$resourceRoot/Microsoft.Network/privateEndpoints/pe-$($env:AZURE_STORAGE_ACCOUNT)-blob"
$privateEndpoint = Get-UploadPrerequisite $privateEndpointId '2024-05-01'
if (-not ($privateEndpoint.properties.privateLinkServiceConnections | Where-Object {
  $_.properties.privateLinkServiceId -eq $storageId -and 'blob' -in $_.properties.groupIds -and
  $_.properties.privateLinkServiceConnectionState.status -eq 'Approved'
})) { throw 'Storage Blob private endpoint is not approved for the expected storage account. Check Bicep prerequisites.' }
$zoneId = "$resourceRoot/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
$zoneGroup = Get-UploadPrerequisite "$privateEndpointId/privateDnsZoneGroups/default" '2024-05-01'
$dnsLink = Get-UploadPrerequisite "$zoneId/virtualNetworkLinks/link-vnet-demofs-demo" '2020-06-01'
if (-not ($zoneGroup.properties.privateDnsZoneConfigs | Where-Object { $_.properties.privateDnsZoneId -eq $zoneId }) -or
  $dnsLink.properties.virtualNetwork.id -ne "$resourceRoot/Microsoft.Network/virtualNetworks/$vnetName") {
  throw 'Storage private DNS is not linked to the upload VNet. Run the approved Bicep deployment.'
}
$regState = az provider show -n Microsoft.ContainerInstance --query registrationState -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Cannot read ACI provider registration. Check authorization.' }
if ($regState -ne 'Registered') { throw 'Microsoft.ContainerInstance must be registered before upload. Complete infrastructure prerequisites.' }

# --- 3. Pack corpus into base64 tar.gz ---
Write-Host "→ Packing $corpusDir into tar.gz" -ForegroundColor Cyan
$tarPath = Join-Path $env:TEMP 'demofs-corpus.tar.gz'
if (Test-Path $tarPath) { Remove-Item $tarPath -Force }
Push-Location $corpusDir
tar -czf $tarPath .
Pop-Location
$tarBytes = [System.IO.File]::ReadAllBytes($tarPath)
$tarB64   = [Convert]::ToBase64String($tarBytes)
$tarSizeKB = [math]::Round($tarBytes.Length / 1KB, 1)
$b64SizeKB = [math]::Round($tarB64.Length / 1KB, 1)
Write-Host "  tar.gz: $tarSizeKB KB → base64: $b64SizeKB KB" -ForegroundColor DarkGray

# --- 4. Delete any prior ACI (idempotent re-run) ---
$aciExists = az container show --name $aciName --resource-group $env:AZURE_RESOURCE_GROUP --query name -o tsv 2>$null
if ($aciExists) {
  Write-Host "→ Removing prior ACI $aciName" -ForegroundColor Cyan
  az container delete --name $aciName --resource-group $env:AZURE_RESOURCE_GROUP --yes --output none
}

# Bash one-liner: use python3 (bundled with az-cli image) to decode tar.gz → az login → upload → list
# Bash script the container runs. Uses python3 (bundled in the az-cli image) to
# unpack the base64 tar.gz env var, then az login --identity and upload-batch.
# Indent each line by 12 spaces to satisfy the YAML block scalar below.
$bashLines = @(
  'set -e',
  'mkdir -p /data',
  "python3 -c 'import base64,io,tarfile,os; tarfile.open(fileobj=io.BytesIO(base64.b64decode(os.environ[`"CORPUS_B64`"]))).extractall(`"/data`")'",
  'echo === staged files ===',
  'find /data -type f',
  'echo === logging in with UAMI ===',
  'az login --identity --username $UAMI_CLIENT_ID',
  'echo === wiping existing blobs ===',
  'az storage blob delete-batch --account-name $STORAGE_ACCOUNT --source $CONTAINER --auth-mode login',
  'echo === uploading ===',
  'az storage blob upload-batch --account-name $STORAGE_ACCOUNT --destination $CONTAINER --source /data --auth-mode login --overwrite',
  'echo === listing ===',
  'az storage blob list --account-name $STORAGE_ACCOUNT --container-name $CONTAINER --auth-mode login --query "[].{name:name,size:properties.contentLength}" -o table',
  'echo === done ==='
)
$indented = ($bashLines | ForEach-Object { '            ' + $_ }) -join "`n"

# --- 6. Container group YAML (block scalar keeps bash verbatim, no escaping) ---
$aciYaml = @"
apiVersion: '2021-10-01'
location: $($env:AZURE_LOCATION)
name: $aciName
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
          requests:
            cpu: 1.0
            memoryInGB: 1.0
        environmentVariables:
          - name: STORAGE_ACCOUNT
            value: $($env:AZURE_STORAGE_ACCOUNT)
          - name: CONTAINER
            value: $($env:AZURE_STORAGE_CONTAINER)
          - name: UAMI_CLIENT_ID
            value: $uamiClientId
          - name: CORPUS_B64
            secureValue: $tarB64
tags: {}
type: Microsoft.ContainerInstance/containerGroups
"@

$yamlPath = Join-Path $env:TEMP 'aci-demofs-upload.yaml'
Set-Content -Path $yamlPath -Value $aciYaml -Encoding UTF8

Write-Host "→ Launching ACI $aciName in $aciSubnetName (via YAML)" -ForegroundColor Cyan
az container create `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --file $yamlPath `
  --output none
if ($LASTEXITCODE -ne 0) {
  Write-Host "❌ ACI creation failed — aborting" -ForegroundColor Red
  exit 1
}

# --- 7. Wait for exit, tail logs ---
Write-Host "→ Waiting for ACI to complete..." -ForegroundColor Cyan
$maxWaitSec = 300
$waited = 0
while ($waited -lt $maxWaitSec) {
  $state = az container show --name $aciName --resource-group $env:AZURE_RESOURCE_GROUP --query "containers[0].instanceView.currentState.state" -o tsv 2>$null
  if ($state -eq 'Terminated') { break }
  Start-Sleep -Seconds 5
  $waited += 5
  Write-Host "  state=$state (${waited}s)" -ForegroundColor DarkGray
}

$exitCode = az container show --name $aciName --resource-group $env:AZURE_RESOURCE_GROUP --query "containers[0].instanceView.currentState.exitCode" -o tsv 2>$null
Write-Host ""
Write-Host "=== ACI logs ===" -ForegroundColor Cyan
az container logs --name $aciName --resource-group $env:AZURE_RESOURCE_GROUP
Write-Host ""
Write-Host "=== ACI exit code: $exitCode ===" -ForegroundColor Cyan

# --- 8. Tear down ACI ---
Write-Host "→ Deleting ACI $aciName" -ForegroundColor Cyan
az container delete --name $aciName --resource-group $env:AZURE_RESOURCE_GROUP --yes --output none

# --- 9. Summary ---
Write-Host ""
if ($exitCode -eq '0') {
  Write-Host "✅ Corpus uploaded to $env:AZURE_STORAGE_ACCOUNT/$env:AZURE_STORAGE_CONTAINER" -ForegroundColor Green
  Write-Host ""
  Write-Host "  Next: ./scripts/setup/03c-create-foundry-iq-kb.ps1" -ForegroundColor Cyan
} else {
  Write-Host "❌ Upload failed with exit code $exitCode — see logs above" -ForegroundColor Red
  exit 1
}
