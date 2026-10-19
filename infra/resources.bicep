targetScope = 'resourceGroup'

param location string
param searchServiceName string
param searchSku string
param foundryAccountName string
param foundryProjectName string
param chatDeploymentName string
param chatModelName string
param chatModelVersion string
param chatCapacity int
param embeddingDeploymentName string
param embeddingModelName string
param embeddingModelVersion string
param embeddingCapacity int
param searchConnectionName string
param operatorPrincipalId string
param logAnalyticsWorkspaceId string
param tags { *: string }

var searchServiceContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
)
var searchIndexDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
)
var searchIndexDataReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '1407120a-92aa-4202-b7e9-c0e197c71c8f'
)
var cognitiveServicesOpenAiUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
)
var cognitiveServicesUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a97b65f3-24c7-4388-baec-2e87135dc908'
)

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchServiceName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: searchSku
  }
  properties: {
    disableLocalAuth: true
    hostingMode: 'Default'
    partitionCount: 1
    publicNetworkAccess: 'Enabled'
    replicaCount: 1
    semanticSearch: 'free'
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: foundryAccountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryAccountName
    disableLocalAuth: true
    dynamicThrottlingEnabled: true
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: foundry
  name: foundryProjectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: foundryProjectName
    description: 'Disposable public quickstart project using synthetic content.'
  }
}

resource chat 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: foundry
  name: chatDeploymentName
  dependsOn: [
    project
  ]
  sku: {
    name: 'GlobalStandard'
    capacity: chatCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: chatModelName
      version: chatModelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: foundry
  name: embeddingDeploymentName
  dependsOn: [
    chat
  ]
  sku: {
    name: 'GlobalStandard'
    capacity: embeddingCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: embeddingModelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: searchConnectionName
  dependsOn: [
    embedding
  ]
  properties: {
    category: 'CognitiveSearch'
    authType: 'AAD'
    target: search.properties.endpoint
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
      ResourceId: search.id
    }
  }
}

resource operatorSearchServiceContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, operatorPrincipalId, searchServiceContributorRoleId)
  properties: {
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: searchServiceContributorRoleId
  }
}

resource operatorSearchIndexContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, operatorPrincipalId, searchIndexDataContributorRoleId)
  properties: {
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: searchIndexDataContributorRoleId
  }
}

resource operatorFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, operatorPrincipalId, cognitiveServicesUserRoleId)
  properties: {
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: cognitiveServicesUserRoleId
  }
}

resource projectSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, project.id, searchIndexDataReaderRoleId)
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: searchIndexDataReaderRoleId
  }
}

resource searchOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, search.id, cognitiveServicesOpenAiUserRoleId)
  properties: {
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAiUserRoleId
  }
}

resource searchDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'search-to-log-analytics'
  scope: search
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource foundryDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'foundry-to-log-analytics'
  scope: foundry
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output searchId string = search.id
output searchEndpoint string = search.properties.endpoint
output searchPrincipalId string = search.identity.principalId
output foundryAccountId string = foundry.id
output foundryProjectId string = project.id
output foundryProjectPrincipalId string = project.identity.principalId
output foundryProjectEndpoint string = project.properties.endpoints['AI Foundry API']
output openAiEndpoint string = foundry.properties.endpoint
output roleAssignments array = [
  {
    id: operatorSearchServiceContributor.id
    scope: search.id
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: searchServiceContributorRoleId
  }
  {
    id: operatorSearchIndexContributor.id
    scope: search.id
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: searchIndexDataContributorRoleId
  }
  {
    id: operatorFoundryUser.id
    scope: foundry.id
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: cognitiveServicesUserRoleId
  }
  {
    id: projectSearchReader.id
    scope: search.id
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: searchIndexDataReaderRoleId
  }
  {
    id: searchOpenAiUser.id
    scope: foundry.id
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAiUserRoleId
  }
]
output diagnosticSettingIds array = [
  searchDiagnostics.id
  foundryDiagnostics.id
]
