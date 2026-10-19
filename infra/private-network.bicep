targetScope = 'resourceGroup'

param location string
param vnetName string
param storageAccountName string
param storageAccountId string
param searchServiceName string
param searchPrincipalId string
param sharedPrivateLinkName string
param sharedPrivateLinkRequestMessage string
param tags { *: string }

var functionIntegrationSubnetName = 'snet-function-integration'
var privateEndpointSubnetName = 'snet-private-endpoints'
var uploadSubnetName = 'snet-private-upload'
var storageBlobDataReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
)
var storageServices = [
  {
    name: 'blob'
    privateDnsZoneName: 'privatelink.blob.${environment().suffixes.storage}'
  }
  {
    name: 'queue'
    privateDnsZoneName: 'privatelink.queue.${environment().suffixes.storage}'
  }
  {
    name: 'table'
    privateDnsZoneName: 'privatelink.table.${environment().suffixes.storage}'
  }
  {
    name: 'file'
    privateDnsZoneName: 'privatelink.file.${environment().suffixes.storage}'
  }
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/16'
      ]
    }
    subnets: [
      {
        name: functionIntegrationSubnetName
        properties: {
          addressPrefix: '10.42.1.0/24'
          defaultOutboundAccess: true
          delegations: [
            {
              name: 'function-integration'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: '10.42.2.0/24'
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: uploadSubnetName
        properties: {
          addressPrefix: '10.42.3.0/24'
          defaultOutboundAccess: true
          delegations: [
            {
              name: 'private-uploader'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
    ]
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

resource search 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: searchServiceName
}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for service in storageServices: {
    name: service.privateDnsZoneName
    location: 'global'
    tags: tags
  }
]

resource privateDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (service, index) in storageServices: {
    parent: privateDnsZones[index]
    name: 'link-${vnetName}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnet.id
      }
    }
  }
]

resource privateEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [
  for service in storageServices: {
    name: 'pe-${storageAccountName}-${service.name}'
    location: location
    tags: tags
    properties: {
      subnet: {
        id: '${vnet.id}/subnets/${privateEndpointSubnetName}'
      }
      privateLinkServiceConnections: [
        {
          name: '${storageAccountName}-${service.name}'
          properties: {
            privateLinkServiceId: storage.id
            groupIds: [
              service.name
            ]
          }
        }
      ]
    }
  }
]

resource privateDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [
  for (service, index) in storageServices: {
    parent: privateEndpoints[index]
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: '${service.name}-storage'
          properties: {
            privateDnsZoneId: privateDnsZones[index].id
          }
        }
      ]
    }
  }
]

resource searchStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, searchPrincipalId, storageBlobDataReaderRoleId)
  properties: {
    principalId: searchPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}

resource searchStoragePrivateLink 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-02-01-preview' = {
  parent: search
  name: sharedPrivateLinkName
  properties: {
    groupId: 'blob'
    privateLinkResourceId: storageAccountId
    requestMessage: sharedPrivateLinkRequestMessage
  }
}

output vnetId string = vnet.id
output functionIntegrationSubnetId string = '${vnet.id}/subnets/${functionIntegrationSubnetName}'
output uploadSubnetId string = '${vnet.id}/subnets/${uploadSubnetName}'
output privateEndpointIds array = map(privateEndpoints, endpoint => endpoint.id)
output privateDnsZoneIds array = map(privateDnsZones, zone => zone.id)
output sharedPrivateLink object = {
  apiVersion: '2025-02-01-preview'
  id: searchStoragePrivateLink.id
  name: searchStoragePrivateLink.name
  requestMessage: sharedPrivateLinkRequestMessage
  storageAccountId: storageAccountId
}
output roleAssignments array = [
  {
    id: searchStorageReader.id
    scope: storage.id
    principalId: searchPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
]
