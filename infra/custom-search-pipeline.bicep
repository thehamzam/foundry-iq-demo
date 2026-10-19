targetScope = 'resourceGroup'

param location string
param functionAppName string
param functionPlanName string
@allowed([
  'P1v3'
])
param functionPlanSku string = 'P1v3'
param functionStorageName string
param integrationSubnetId string
param packageStorageResourceId string
param searchEndpoint string
param searchPrincipalId string
param functionAuthClientId string
param functionAuthAudience string
param sourceStorageResourceId string
param sourceContainerName string
param openAiEndpoint string
param embeddingDeploymentName string
param chatDeploymentName string
param chatModelName string
param indexName string
param dataSourceName string
param skillsetName string
param indexerName string
param knowledgeSourceName string
param knowledgeBaseName string
param logAnalyticsWorkspaceId string
param tags { *: string }

var searchApiVersion = '2024-09-01-preview'
var foundryIqApiVersion = '2026-08-01-preview'
var customSkillRoute = '/api/policy-applicability'
var functionEndpoint = 'https://${functionApp.properties.defaultHostName}${customSkillRoute}'
var readerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'acdd72a7-3385-48ef-bd42-f606fba81ae7'
)
var storageBlobDataOwnerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
)
var storageQueueDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
)
var storageTableDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
)
var operationRetry = {
  maxAttempts: 6
  initialDelaySeconds: 5
  maxDelaySeconds: 30
  statusCodes: [
    408
    409
    429
    500
    502
    503
    504
  ]
}

resource functionStorage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: functionStorageName
}

resource functionPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: functionPlanName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: functionPlanSku
    tier: 'PremiumV3'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      alwaysOn: true
      ftpsState: 'Disabled'
      http20Enabled: true
      linuxFxVersion: 'Python|3.11'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      appSettings: [
          {
            name: 'FUNCTIONS_EXTENSION_VERSION'
            value: '~4'
          }
          {
            name: 'FUNCTIONS_WORKER_RUNTIME'
            value: 'python'
          }
          {
            name: 'AzureWebJobsFeatureFlags'
            value: 'EnableWorkerIndexing'
          }
          {
            name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
            value: 'false'
          }
          {
            name: 'AzureWebJobsStorage__blobServiceUri'
            value: 'https://${functionStorage.name}.blob.${environment().suffixes.storage}'
          }
          {
            name: 'AzureWebJobsStorage__queueServiceUri'
            value: 'https://${functionStorage.name}.queue.${environment().suffixes.storage}'
          }
          {
            name: 'AzureWebJobsStorage__tableServiceUri'
            value: 'https://${functionStorage.name}.table.${environment().suffixes.storage}'
          }
          {
            name: 'AzureWebJobsStorage__credential'
            value: 'managedidentity'
          }
          {
            name: 'WEBSITE_VNET_ROUTE_ALL'
            value: '1'
          }
      ]
    }
  }
}

resource functionVnetIntegration 'Microsoft.Web/sites/networkConfig@2023-12-01' = {
  parent: functionApp
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: integrationSubnetId
    swiftSupported: true
  }
}

resource functionAuth 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
      excludedPaths: [
        '/api/health'
      ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: functionAuthClientId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            functionAuthAudience
          ]
          defaultAuthorizationPolicy: {
            allowedPrincipals: {
              identities: [
                searchPrincipalId
              ]
            }
          }
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
  }
}

resource functionStorageReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionStorage
  name: guid(functionStorage.id, functionApp.id, readerRoleId)
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRoleId
  }
}

resource functionStorageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionStorage
  name: guid(functionStorage.id, functionApp.id, storageBlobDataOwnerRoleId)
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataOwnerRoleId
  }
}

resource functionStorageQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionStorage
  name: guid(functionStorage.id, functionApp.id, storageQueueDataContributorRoleId)
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageQueueDataContributorRoleId
  }
}

resource functionStorageTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionStorage
  name: guid(functionStorage.id, functionApp.id, storageTableDataContributorRoleId)
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageTableDataContributorRoleId
  }
}

resource functionDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'function-to-log-analytics'
  scope: functionApp
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

var indexPayload = {
  name: indexName
  fields: [
    {
      name: 'chunk_id'
      type: 'Edm.String'
      key: true
      searchable: true
      analyzer: 'keyword'
      filterable: true
      retrievable: true
    }
    {
      name: 'parent_id'
      type: 'Edm.String'
      filterable: true
      retrievable: true
    }
    {
      name: 'title'
      type: 'Edm.String'
      searchable: true
      retrievable: true
    }
    {
      name: 'content'
      type: 'Edm.String'
      searchable: true
      retrievable: true
    }
    {
      name: 'contentVector'
      type: 'Collection(Edm.Single)'
      searchable: true
      retrievable: false
      dimensions: 3072
      vectorSearchProfile: 'policy-vector-profile'
    }
    {
      name: 'sourcePath'
      type: 'Edm.String'
      filterable: true
      retrievable: true
    }
    {
      name: 'documentType'
      type: 'Edm.String'
      searchable: true
      filterable: true
      retrievable: true
    }
    {
      name: 'requiresEscalation'
      type: 'Edm.Boolean'
      filterable: true
      retrievable: true
    }
  ]
  semantic: {
    defaultConfiguration: 'policy-semantic'
    configurations: [
      {
        name: 'policy-semantic'
        prioritizedFields: {
          titleField: {
            fieldName: 'title'
          }
          prioritizedContentFields: [
            {
              fieldName: 'content'
            }
          ]
        }
      }
    ]
  }
  vectorSearch: {
    algorithms: [
      {
        name: 'policy-hnsw'
        kind: 'hnsw'
        hnswParameters: {
          metric: 'cosine'
        }
      }
    ]
    profiles: [
      {
        name: 'policy-vector-profile'
        algorithm: 'policy-hnsw'
        vectorizer: 'policy-openai-vectorizer'
      }
    ]
    vectorizers: [
      {
        name: 'policy-openai-vectorizer'
        kind: 'azureOpenAI'
        azureOpenAIParameters: {
          resourceUri: openAiEndpoint
          deploymentId: embeddingDeploymentName
          modelName: 'text-embedding-3-large'
        }
      }
    ]
  }
}

var dataSourcePayload = {
  name: dataSourceName
  type: 'azureblob'
  credentials: {
    connectionString: 'ResourceId=${sourceStorageResourceId};'
  }
  container: {
    name: sourceContainerName
  }
}

var skillsetPayload = {
  name: skillsetName
  description: 'Token chunking, deterministic policy classification, and Azure OpenAI embeddings.'
  skills: [
    {
      '@odata.type': '#Microsoft.Skills.Text.SplitSkill'
      name: 'split-policy-content'
      context: '/document'
      textSplitMode: 'pages'
      unit: 'azureOpenAITokens'
      maximumPageLength: 2000
      pageOverlapLength: 200
      azureOpenAITokenizerParameters: {
        encoderModelName: 'cl100k_base'
      }
      inputs: [
        {
          name: 'text'
          source: '/document/content'
        }
      ]
      outputs: [
        {
          name: 'textItems'
          targetName: 'pages'
        }
      ]
    }
    {
      '@odata.type': '#Microsoft.Skills.Custom.WebApiSkill'
      name: 'classify-policy-applicability'
      context: '/document'
      uri: functionEndpoint
      authResourceId: functionAuthAudience
      httpMethod: 'POST'
      timeout: 'PT60S'
      batchSize: 10
      degreeOfParallelism: 2
      inputs: [
        {
          name: 'text'
          source: '/document/content'
        }
        {
          name: 'sourcePath'
          source: '/document/metadata_storage_path'
        }
      ]
      outputs: [
        {
          name: 'documentType'
          targetName: 'documentType'
        }
        {
          name: 'requiresEscalation'
          targetName: 'requiresEscalation'
        }
      ]
    }
    {
      '@odata.type': '#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill'
      name: 'embed-policy-chunk'
      context: '/document/pages/*'
      resourceUri: openAiEndpoint
      deploymentId: embeddingDeploymentName
      modelName: 'text-embedding-3-large'
      dimensions: 3072
      inputs: [
        {
          name: 'text'
          source: '/document/pages/*'
        }
      ]
      outputs: [
        {
          name: 'embedding'
          targetName: 'contentVector'
        }
      ]
    }
  ]
  indexProjections: {
    selectors: [
      {
        targetIndexName: indexName
        parentKeyFieldName: 'parent_id'
        sourceContext: '/document/pages/*'
        mappings: [
          {
            name: 'content'
            source: '/document/pages/*'
          }
          {
            name: 'contentVector'
            source: '/document/pages/*/contentVector'
          }
          {
            name: 'title'
            source: '/document/metadata_storage_name'
          }
          {
            name: 'sourcePath'
            source: '/document/metadata_storage_path'
          }
          {
            name: 'documentType'
            source: '/document/documentType'
          }
          {
            name: 'requiresEscalation'
            source: '/document/requiresEscalation'
          }
        ]
      }
    ]
    parameters: {
      projectionMode: 'skipIndexingParentDocuments'
    }
  }
}

var indexerPayload = {
  name: indexerName
  dataSourceName: dataSourceName
  skillsetName: skillsetName
  targetIndexName: indexName
  parameters: {
    batchSize: 10
    maxFailedItems: 0
    maxFailedItemsPerBatch: 0
    configuration: {
      dataToExtract: 'contentAndMetadata'
      executionEnvironment: 'private'
      parsingMode: 'default'
    }
  }
}

var knowledgeSourcePayload = {
  name: knowledgeSourceName
  kind: 'searchIndex'
  description: 'Synthetic policy index with deterministic enrichment metadata.'
  searchIndexParameters: {
    searchIndexName: indexName
  }
}

var knowledgeBasePayload = {
  name: knowledgeBaseName
  description: 'Disposable synthetic policy knowledge base.'
  knowledgeSources: [
    {
      name: knowledgeSourceName
    }
  ]
  outputMode: 'answerSynthesis'
  retrievalReasoningEffort: {
    kind: 'low'
  }
  answerInstructions: 'Return the shortest passage that answers the question with a direct citation. Include the source document ID in every answer.'
  models: [
    {
      kind: 'azureOpenAI'
      azureOpenAIParameters: {
        resourceUri: openAiEndpoint
        deploymentId: chatDeploymentName
        modelName: chatModelName
      }
    }
  ]
  retrievalInstructions: 'Retrieve only from the explicitly synthetic policy corpus and preserve source identifiers.'
  retrieveDefaults: {
    maxOutputDocuments: 5
    maxOutputSizeInTokens: 6000
  }
}

var operations = [
  {
    id: 'search-index'
    order: 10
    dependsOn: []
    serviceKind: 'search-management'
    method: 'PUT'
    uri: '${searchEndpoint}/indexes/${indexName}?api-version=${searchApiVersion}'
    audience: 'https://search.azure.com/'
    apiVersion: searchApiVersion
    body: indexPayload
    acceptedStatusCodes: [
      200
      201
      204
    ]
    retry: operationRetry
    verificationUri: '${searchEndpoint}/indexes/${indexName}?api-version=${searchApiVersion}'
    canonicalization: {
      removeFields: [
        '@odata.context'
        '@odata.etag'
      ]
    }
  }
  {
    id: 'search-data-source'
    order: 20
    dependsOn: [
      'search-index'
    ]
    serviceKind: 'search-management'
    method: 'PUT'
    uri: '${searchEndpoint}/datasources/${dataSourceName}?api-version=${searchApiVersion}'
    audience: 'https://search.azure.com/'
    apiVersion: searchApiVersion
    body: dataSourcePayload
    acceptedStatusCodes: [
      200
      201
      204
    ]
    retry: operationRetry
    verificationUri: '${searchEndpoint}/datasources/${dataSourceName}?api-version=${searchApiVersion}'
    canonicalization: {
      removeFields: [
        '@odata.context'
        '@odata.etag'
      ]
    }
  }
  {
    id: 'search-skillset'
    order: 30
    dependsOn: [
      'search-index'
    ]
    serviceKind: 'search-management'
    method: 'PUT'
    uri: '${searchEndpoint}/skillsets/${skillsetName}?api-version=${searchApiVersion}'
    audience: 'https://search.azure.com/'
    apiVersion: searchApiVersion
    body: skillsetPayload
    acceptedStatusCodes: [
      200
      201
      204
    ]
    retry: operationRetry
    verificationUri: '${searchEndpoint}/skillsets/${skillsetName}?api-version=${searchApiVersion}'
    canonicalization: {
      removeFields: [
        '@odata.context'
        '@odata.etag'
      ]
    }
  }
  {
    id: 'search-indexer'
    order: 40
    dependsOn: [
      'search-data-source'
      'search-skillset'
    ]
    serviceKind: 'search-management'
    method: 'PUT'
    uri: '${searchEndpoint}/indexers/${indexerName}?api-version=${searchApiVersion}'
    audience: 'https://search.azure.com/'
    apiVersion: searchApiVersion
    body: indexerPayload
    acceptedStatusCodes: [
      200
      201
      204
    ]
    retry: operationRetry
    verificationUri: '${searchEndpoint}/indexers/${indexerName}?api-version=${searchApiVersion}'
    canonicalization: {
      removeFields: [
        '@odata.context'
        '@odata.etag'
      ]
    }
  }
  {
    id: 'foundry-knowledge-source'
    order: 50
    dependsOn: [
      'search-index'
    ]
    serviceKind: 'search-management'
    method: 'PUT'
    uri: '${searchEndpoint}/knowledgeSources/${knowledgeSourceName}?api-version=${foundryIqApiVersion}'
    audience: 'https://search.azure.com/'
    apiVersion: foundryIqApiVersion
    body: knowledgeSourcePayload
    acceptedStatusCodes: [
      200
      201
      204
    ]
    retry: operationRetry
    verificationUri: '${searchEndpoint}/knowledgeSources/${knowledgeSourceName}?api-version=${foundryIqApiVersion}'
    canonicalization: {
      removeFields: [
        '@odata.context'
        '@odata.etag'
      ]
    }
  }
  {
    id: 'foundry-knowledge-base'
    order: 60
    dependsOn: [
      'foundry-knowledge-source'
    ]
    serviceKind: 'search-management'
    method: 'PUT'
    uri: '${searchEndpoint}/knowledgeBases/${knowledgeBaseName}?api-version=${foundryIqApiVersion}'
    audience: 'https://search.azure.com/'
    apiVersion: foundryIqApiVersion
    body: knowledgeBasePayload
    acceptedStatusCodes: [
      200
      201
      204
    ]
    retry: operationRetry
    verificationUri: '${searchEndpoint}/knowledgeBases/${knowledgeBaseName}?api-version=${foundryIqApiVersion}'
    canonicalization: {
      removeFields: [
        '@odata.context'
        '@odata.etag'
      ]
    }
  }
]

var verificationChecks = [
  {
    id: 'function-health'
    order: 10
    kind: 'health'
    method: 'GET'
    uri: 'https://${functionApp.properties.defaultHostName}/api/health'
    audience: ''
    acceptedStatusCodes: [
      200
    ]
  }
  {
    id: 'indexer-status'
    order: 20
    kind: 'indexer-status'
    method: 'GET'
    uri: '${searchEndpoint}/indexers/${indexerName}/status?api-version=${searchApiVersion}'
    audience: 'https://search.azure.com/'
    acceptedStatusCodes: [
      200
    ]
    poll: {
      maxAttempts: 30
      intervalSeconds: 10
    }
    successStatus: 'success'
    failureStatuses: [
      'transientFailure'
      'persistentFailure'
    ]
  }
  {
    id: 'document-count'
    order: 30
    kind: 'count'
    method: 'GET'
    uri: '${searchEndpoint}/indexes/${indexName}/docs/$count?api-version=${searchApiVersion}'
    audience: 'https://search.azure.com/'
    acceptedStatusCodes: [
      200
    ]
    minimum: 1
  }
  {
    id: 'knowledge-retrieval'
    order: 40
    kind: 'retrieval'
    method: 'POST'
    uri: '${searchEndpoint}/knowledgebases/${knowledgeBaseName}/retrieve?api-version=${foundryIqApiVersion}'
    audience: 'https://search.azure.com/'
    acceptedStatusCodes: [
      200
    ]
    body: {
      messages: [
        {
          role: 'user'
          content: [
            {
              type: 'text'
              text: 'What synthetic procedure applies to duplicate dispute intake?'
            }
          ]
        }
      ]
      retrievalReasoningEffort: {
        kind: 'low'
      }
    }
    resultCollectionField: 'response'
    citationCollectionField: 'references'
    sourceIdField: 'id'
  }
]

output apiProfile object = {
  search: searchApiVersion
  foundryIq: foundryIqApiVersion
}
output operations array = operations
output verificationChecks array = verificationChecks
output functionAppId string = functionApp.id
output functionEndpoint string = functionEndpoint
output functionPrincipalId string = functionApp.identity.principalId
output packageStorageResourceId string = packageStorageResourceId
output roleAssignments array = [
  {
    id: functionStorageReaderRole.id
    scope: functionStorage.id
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRoleId
  }
  {
    id: functionStorageBlobRole.id
    scope: functionStorage.id
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataOwnerRoleId
  }
  {
    id: functionStorageQueueRole.id
    scope: functionStorage.id
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageQueueDataContributorRoleId
  }
  {
    id: functionStorageTableRole.id
    scope: functionStorage.id
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageTableDataContributorRoleId
  }
]
output diagnosticSettingIds array = [
  functionDiagnostics.id
]
