targetScope = 'subscription'

@minLength(1)
param location string

@minLength(3)
@maxLength(24)
param environment string

@minLength(1)
param deploymentId string

param operatorPrincipalId string

@description('Client ID of the single-tenant Microsoft Entra application protecting the custom-skill Function API.')
param functionAuthClientId string

@description('Application ID URI for the Function API. The guarded wrapper requires api://<functionAuthClientId>.')
param functionAuthAudience string

@allowed([
  'standard'
  'standard2'
])
param searchSku string = 'standard'

param chatModelName string = 'gpt-4o'
param chatModelVersion string

@minValue(1)
param chatCapacity int = 10

param embeddingModelName string = 'text-embedding-3-large'
param embeddingModelVersion string

@minValue(1)
param embeddingCapacity int = 50

@allowed([
  'P1v3'
])
param functionPlanSku string = 'P1v3'

param tags { *: string } = {}

var contractSchemaVersion = '3.1.0'
var normalizedEnvironmentName = toLower(environment)
var normalizedDeploymentId = toLower(deploymentId)
var resourceGroupName = 'rg-${normalizedEnvironmentName}-${normalizedDeploymentId}'
var provenanceId = uniqueString(subscription().id, deployment().name, normalizedDeploymentId, resourceGroupName)
var resourceToken = uniqueString(subscription().id, resourceGroupName, deploymentId)
var ownershipTags = {
  'quickstart.owner': 'financial-services-knowledge-quickstart'
  'quickstart.schemaVersion': contractSchemaVersion
  'quickstart.deploymentId': normalizedDeploymentId
  'quickstart.deploymentName': deployment().name
  'quickstart.provenanceId': provenanceId
  'quickstart.protected': 'false'
}
var resourceTags = union(tags, ownershipTags, {
  environment: normalizedEnvironmentName
})
var names = {
  search: take('srch-${normalizedEnvironmentName}-${resourceToken}', 60)
  foundry: take('aif-${normalizedEnvironmentName}-${resourceToken}', 64)
  project: take('proj-${normalizedEnvironmentName}', 64)
  chatDeployment: take('chat-${normalizedEnvironmentName}', 64)
  embeddingDeployment: take('embed-${normalizedEnvironmentName}', 64)
  searchConnection: take('search-${normalizedEnvironmentName}', 64)
  corpusStorage: take(replace('stcorpus${normalizedEnvironmentName}${resourceToken}', '-', ''), 24)
  corpusContainer: 'synthetic-corpus'
  packageContainer: 'function-packages'
  packageBlob: 'custom-skill.zip'
  logAnalytics: take('log-${normalizedEnvironmentName}-${resourceToken}', 63)
  appInsights: take('appi-${normalizedEnvironmentName}-${resourceToken}', 260)
  functionPlan: take('planv3-${normalizedEnvironmentName}-${resourceToken}', 40)
  functionApp: take('funcv3-${normalizedEnvironmentName}-${resourceToken}', 60)
  vnet: take('vnet-${normalizedEnvironmentName}-${resourceToken}', 64)
  uploadIdentity: take('uami-upload-${normalizedEnvironmentName}-${resourceToken}', 128)
  storageSharedPrivateLink: take('spl-storage-${normalizedEnvironmentName}', 80)
  index: 'policy-chunks-v2'
  dataSource: 'synthetic-corpus'
  skillset: 'policy-enrichment-v2'
  indexer: 'policy-indexer-v2'
  knowledgeSource: 'policy-knowledge-source-v2'
  knowledgeBase: 'policy-knowledge-base-v2'
}

resource quickstartGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: resourceTags
}

module observability './observability.bicep' = {
  scope: quickstartGroup
  params: {
    location: location
    logAnalyticsName: names.logAnalytics
    applicationInsightsName: names.appInsights
    tags: resourceTags
  }
}

module core './resources.bicep' = {
  scope: quickstartGroup
  params: {
    location: location
    searchServiceName: names.search
    searchSku: searchSku
    foundryAccountName: names.foundry
    foundryProjectName: names.project
    chatDeploymentName: names.chatDeployment
    chatModelName: chatModelName
    chatModelVersion: chatModelVersion
    chatCapacity: chatCapacity
    embeddingDeploymentName: names.embeddingDeployment
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    embeddingCapacity: embeddingCapacity
    searchConnectionName: names.searchConnection
    operatorPrincipalId: operatorPrincipalId
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsId
    tags: resourceTags
  }
}

module storage './storage.bicep' = {
  scope: quickstartGroup
  params: {
    location: location
    storageAccountName: names.corpusStorage
    containerName: names.corpusContainer
    packageContainerName: names.packageContainer
    uploadIdentityName: names.uploadIdentity
    operatorPrincipalId: operatorPrincipalId
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsId
    tags: resourceTags
  }
}

var sharedPrivateLinkRequestMessage = 'Quickstart ${normalizedDeploymentId} Search access to private corpus Blob'

module privateNetwork './private-network.bicep' = {
  scope: quickstartGroup
  params: {
    location: location
    vnetName: names.vnet
    storageAccountName: names.corpusStorage
    storageAccountId: storage.outputs.storageAccountId
    searchServiceName: names.search
    searchPrincipalId: core.outputs.searchPrincipalId
    sharedPrivateLinkName: names.storageSharedPrivateLink
    sharedPrivateLinkRequestMessage: sharedPrivateLinkRequestMessage
    tags: resourceTags
  }
}

module customSearchPipeline './custom-search-pipeline.bicep' = {
  scope: quickstartGroup
  params: {
    location: location
    functionAppName: names.functionApp
    functionPlanName: names.functionPlan
    functionPlanSku: functionPlanSku
    functionStorageName: names.corpusStorage
    integrationSubnetId: privateNetwork.outputs.functionIntegrationSubnetId
    packageStorageResourceId: storage.outputs.storageAccountId
    searchEndpoint: core.outputs.searchEndpoint
    searchPrincipalId: core.outputs.searchPrincipalId
    functionAuthClientId: functionAuthClientId
    functionAuthAudience: functionAuthAudience
    sourceStorageResourceId: storage.outputs.storageAccountId
    sourceContainerName: names.corpusContainer
    openAiEndpoint: core.outputs.openAiEndpoint
    embeddingDeploymentName: names.embeddingDeployment
    chatDeploymentName: names.chatDeployment
    chatModelName: chatModelName
    indexName: names.index
    dataSourceName: names.dataSource
    skillsetName: names.skillset
    indexerName: names.indexer
    knowledgeSourceName: names.knowledgeSource
    knowledgeBaseName: names.knowledgeBase
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsId
    tags: resourceTags
  }
}

var resources = {
  resourceGroup: {
    id: quickstartGroup.id
    name: quickstartGroup.name
  }
  search: {
    id: core.outputs.searchId
    name: names.search
    endpoint: core.outputs.searchEndpoint
    principalId: core.outputs.searchPrincipalId
    storageSharedPrivateLink: privateNetwork.outputs.sharedPrivateLink
  }
  foundry: {
    accountId: core.outputs.foundryAccountId
    accountName: names.foundry
    accountEndpoint: core.outputs.openAiEndpoint
    projectId: core.outputs.foundryProjectId
    projectName: names.project
    projectEndpoint: core.outputs.foundryProjectEndpoint
    chatDeploymentName: names.chatDeployment
    embeddingDeploymentName: names.embeddingDeployment
  }
  corpus: {
    storageAccountId: storage.outputs.storageAccountId
    storageAccountName: names.corpusStorage
    containerId: storage.outputs.containerId
    containerName: names.corpusContainer
    blobEndpoint: storage.outputs.blobEndpoint
  }
  package: {
    storageAccountId: storage.outputs.storageAccountId
    storageAccountName: names.corpusStorage
    containerId: storage.outputs.packageContainerId
    containerName: names.packageContainer
    blobName: names.packageBlob
  }
  function: {
    id: customSearchPipeline.outputs.functionAppId
    name: names.functionApp
    endpoint: customSearchPipeline.outputs.functionEndpoint
    principalId: customSearchPipeline.outputs.functionPrincipalId
    integrationSubnetId: privateNetwork.outputs.functionIntegrationSubnetId
    authClientId: functionAuthClientId
    authAudience: functionAuthAudience
  }
  network: {
    vnetId: privateNetwork.outputs.vnetId
    uploadSubnetId: privateNetwork.outputs.uploadSubnetId
    privateEndpointIds: privateNetwork.outputs.privateEndpointIds
    privateDnsZoneIds: privateNetwork.outputs.privateDnsZoneIds
    uploadIdentityId: storage.outputs.uploadIdentityId
    uploadIdentityClientId: storage.outputs.uploadIdentityClientId
    uploadIdentityPrincipalId: storage.outputs.uploadIdentityPrincipalId
  }
  observability: {
    logAnalyticsId: observability.outputs.logAnalyticsId
    applicationInsightsId: observability.outputs.applicationInsightsId
    diagnosticSettingIds: concat(
      core.outputs.diagnosticSettingIds,
      storage.outputs.diagnosticSettingIds,
      customSearchPipeline.outputs.diagnosticSettingIds
    )
  }
  security: {
    roleAssignments: concat(
      core.outputs.roleAssignments,
      storage.outputs.roleAssignments,
      privateNetwork.outputs.roleAssignments,
      customSearchPipeline.outputs.roleAssignments
    )
  }
}

output quickstartContract object = {
  schemaVersion: contractSchemaVersion
  deployment: {
    deploymentId: normalizedDeploymentId
    deploymentName: deployment().name
    environment: normalizedEnvironmentName
    subscriptionId: subscription().subscriptionId
    resourceGroupId: quickstartGroup.id
    resourceGroupName: quickstartGroup.name
    location: location
    provenanceId: provenanceId
    ownershipTags: ownershipTags
  }
  resources: resources
  dataPlane: {
    apiProfile: customSearchPipeline.outputs.apiProfile
    operations: customSearchPipeline.outputs.operations
  }
  verification: {
    checks: customSearchPipeline.outputs.verificationChecks
  }
  cleanup: {
    resourceGroupId: quickstartGroup.id
    resourceGroupName: quickstartGroup.name
    deploymentId: normalizedDeploymentId
    deploymentName: deployment().name
    provenanceId: provenanceId
    requiredOwnershipTags: ownershipTags
    expectedSubscriptionId: subscription().subscriptionId
    protectionTagName: 'quickstart.protected'
    protectionTagValue: 'true'
  }
}
