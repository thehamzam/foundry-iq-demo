targetScope = 'resourceGroup'

param location string
param storageAccountName string
param containerName string
param packageContainerName string
param uploadIdentityName string
param operatorPrincipalId string
param logAnalyticsWorkspaceId string
param tags { *: string }

var storageBlobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storage
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource packageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: packageContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource uploadIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uploadIdentityName
  location: location
  tags: tags
}

resource uploaderStorageContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, uploadIdentity.id, storageBlobDataContributorRoleId)
  properties: {
    principalId: uploadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataContributorRoleId
  }
}

resource operatorStorageContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, operatorPrincipalId, storageBlobDataContributorRoleId)
  properties: {
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: storageBlobDataContributorRoleId
  }
}

resource storageDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'storage-to-log-analytics'
  scope: storage
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

output storageAccountId string = storage.id
output containerId string = container.id
output packageContainerId string = packageContainer.id
output blobEndpoint string = storage.properties.primaryEndpoints.blob
output uploadIdentityId string = uploadIdentity.id
output uploadIdentityClientId string = uploadIdentity.properties.clientId
output uploadIdentityPrincipalId string = uploadIdentity.properties.principalId
output roleAssignments array = [
  {
    id: uploaderStorageContributor.id
    scope: storage.id
    principalId: uploadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataContributorRoleId
  }
  {
    id: operatorStorageContributor.id
    scope: storage.id
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: storageBlobDataContributorRoleId
  }
]
output diagnosticSettingIds array = [
  storageDiagnostics.id
]
