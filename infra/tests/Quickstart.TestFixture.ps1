function New-TestQuickstartContract {
  $subscriptionId = '11111111-1111-1111-1111-111111111111'
  $deploymentId = '22222222-2222-2222-2222-222222222222'
  $environment = 'offline'
  $deploymentName = "quickstart-$deploymentId"
  $resourceGroupName = "rg-$environment-$deploymentId"
  $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"
  $provenanceId = 'offline-provenance'
  $functionAuthClientId = '33333333-3333-3333-3333-333333333333'
  $functionAuthAudience = "api://$functionAuthClientId"
  $ownershipTags = [ordered]@{
    'quickstart.owner' = 'financial-services-knowledge-quickstart'
    'quickstart.schemaVersion' = '3.1.0'
    'quickstart.deploymentId' = $deploymentId
    'quickstart.deploymentName' = $deploymentName
    'quickstart.provenanceId' = $provenanceId
    'quickstart.protected' = 'false'
  }
  $retry = @{
    maxAttempts = 6
    initialDelaySeconds = 5
    maxDelaySeconds = 30
    statusCodes = @(408, 409, 429, 500, 502, 503, 504)
  }
  $searchApiVersion = '2024-09-01-preview'
  $foundryApiVersion = '2026-08-01-preview'
  $searchEndpoint = 'https://owned.search.windows.net'

  function New-Operation {
    param(
      [string]$Id,
      [int]$Order,
      [string[]]$DependsOn,
      [string]$Path,
      [string]$Name,
      [string]$ApiVersion
    )

    return @{
      id = $Id
      order = $Order
      dependsOn = $DependsOn
      serviceKind = 'search-management'
      method = 'PUT'
      uri = "$searchEndpoint$Path$Name`?api-version=$ApiVersion"
      audience = 'https://search.azure.com/'
      apiVersion = $ApiVersion
      body = @{ name = $Name }
      acceptedStatusCodes = @(200, 201, 204)
      retry = $retry
      verificationUri = "$searchEndpoint$Path$Name`?api-version=$ApiVersion"
      canonicalization = @{ removeFields = @('@odata.context', '@odata.etag') }
    }
  }

  $operations = @(
    (New-Operation -Id 'search-index' -Order 10 -DependsOn @() -Path '/indexes/' -Name 'policy-chunks' -ApiVersion $searchApiVersion)
    (New-Operation -Id 'search-data-source' -Order 20 -DependsOn @('search-index') -Path '/datasources/' -Name 'synthetic-corpus' -ApiVersion $searchApiVersion)
    (New-Operation -Id 'search-skillset' -Order 30 -DependsOn @('search-index') -Path '/skillsets/' -Name 'policy-enrichment' -ApiVersion $searchApiVersion)
    (New-Operation -Id 'search-indexer' -Order 40 -DependsOn @('search-data-source', 'search-skillset') -Path '/indexers/' -Name 'policy-indexer' -ApiVersion $searchApiVersion)
    (New-Operation -Id 'foundry-knowledge-source' -Order 50 -DependsOn @('search-index') -Path '/knowledgeSources/' -Name 'policy-knowledge-source' -ApiVersion $foundryApiVersion)
    (New-Operation -Id 'foundry-knowledge-base' -Order 60 -DependsOn @('foundry-knowledge-source') -Path '/knowledgeBases/' -Name 'policy-knowledge-base' -ApiVersion $foundryApiVersion)
  )

  return @{
    schemaVersion = '3.1.0'
    deployment = @{
      deploymentId = $deploymentId
      deploymentName = $deploymentName
      environment = $environment
      subscriptionId = $subscriptionId
      resourceGroupId = $resourceGroupId
      resourceGroupName = $resourceGroupName
      location = 'offline'
      provenanceId = $provenanceId
      ownershipTags = $ownershipTags
    }
    resources = @{
      search = @{
        endpoint = $searchEndpoint
      }
      function = @{
        endpoint = 'https://owned.azurewebsites.net/api/policy-applicability'
        authClientId = $functionAuthClientId
        authAudience = $functionAuthAudience
      }
    }
    dataPlane = @{
      apiProfile = @{
        search = $searchApiVersion
        foundryIq = $foundryApiVersion
      }
      operations = $operations
    }
    verification = @{
      checks = @(
        @{
          id = 'function-health'
          order = 10
          kind = 'health'
          method = 'GET'
          uri = 'https://owned.azurewebsites.net/api/health'
          audience = ''
          acceptedStatusCodes = @(200)
        }
        @{
          id = 'indexer-status'
          order = 20
          kind = 'indexer-status'
          method = 'GET'
          uri = "$searchEndpoint/indexers/policy-indexer/status?api-version=$searchApiVersion"
          audience = 'https://search.azure.com/'
          acceptedStatusCodes = @(200)
          poll = @{
            maxAttempts = 30
            intervalSeconds = 10
          }
          successStatus = 'success'
          failureStatuses = @('transientFailure', 'persistentFailure')
        }
        @{
          id = 'document-count'
          order = 30
          kind = 'count'
          method = 'GET'
          uri = "$searchEndpoint/indexes/policy-chunks/docs/`$count?api-version=$searchApiVersion"
          audience = 'https://search.azure.com/'
          acceptedStatusCodes = @(200)
          minimum = 1
        }
        @{
          id = 'knowledge-retrieval'
          order = 40
          kind = 'retrieval'
          method = 'POST'
          uri = "$searchEndpoint/knowledgebases/policy-knowledge-base/retrieve?api-version=$foundryApiVersion"
          audience = 'https://search.azure.com/'
          acceptedStatusCodes = @(200)
          body = @{
            messages = @(
              @{
                role = 'user'
                content = @(
                  @{
                    type = 'text'
                    text = 'What synthetic procedure applies to duplicate dispute intake?'
                  }
                )
              }
            )
            retrievalReasoningEffort = @{ kind = 'low' }
          }
          resultCollectionField = 'response'
          citationCollectionField = 'references'
          sourceIdField = 'id'
        }
      )
    }
    cleanup = @{
      resourceGroupId = $resourceGroupId
      resourceGroupName = $resourceGroupName
      deploymentId = $deploymentId
      deploymentName = $deploymentName
      provenanceId = $provenanceId
      requiredOwnershipTags = $ownershipTags
      expectedSubscriptionId = $subscriptionId
      protectionTagName = 'quickstart.protected'
      protectionTagValue = 'true'
    }
  } | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
}

function Get-TestManagedResources {
  param([Parameter(Mandatory)][object]$Template)

  $result = @()
  $entries = if ($Template.resources -is [array]) {
    @($Template.resources)
  } elseif ($null -ne $Template.resources) {
    @($Template.resources.PSObject.Properties | ForEach-Object { $_.Value })
  } else {
    @()
  }

  foreach ($resource in $entries) {
    if ($null -eq $resource.PSObject.Properties['type']) {
      throw 'Compiled resource is missing its type.'
    }
    if ($resource.type -eq 'Microsoft.Resources/deployments') {
      $result += Get-TestManagedResources -Template $resource.properties.template
    } elseif ($null -eq $resource.PSObject.Properties['existing'] -or $resource.existing -ne $true) {
      $result += $resource
    }
  }
  return $result
}

function Assert-TestQuickstartCompiledInventory {
  param([Parameter(Mandatory)][object]$Template)

  $managed = @(Get-TestManagedResources -Template $Template)
  $types = @($managed | ForEach-Object { [string]$_.type })

  $templateJson = $Template | ConvertTo-Json -Depth 100 -Compress
  if ($templateJson -match '(?i)"networkProfile"\s*:') {
    throw 'Compiled template contains unsupported networkProfile configuration.'
  }
  $supportedTypes = @(
    'Microsoft.Authorization/roleAssignments'
    'Microsoft.CognitiveServices/accounts'
    'Microsoft.CognitiveServices/accounts/deployments'
    'Microsoft.CognitiveServices/accounts/projects'
    'Microsoft.CognitiveServices/accounts/projects/connections'
    'Microsoft.Insights/components'
    'Microsoft.Insights/diagnosticSettings'
    'Microsoft.ManagedIdentity/userAssignedIdentities'
    'Microsoft.Network/privateDnsZones'
    'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
    'Microsoft.Network/privateEndpoints'
    'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
    'Microsoft.Network/virtualNetworks'
    'Microsoft.OperationalInsights/workspaces'
    'Microsoft.Resources/resourceGroups'
    'Microsoft.Search/searchServices'
    'Microsoft.Search/searchServices/sharedPrivateLinkResources'
    'Microsoft.Storage/storageAccounts'
    'Microsoft.Storage/storageAccounts/blobServices'
    'Microsoft.Storage/storageAccounts/blobServices/containers'
    'Microsoft.Web/serverfarms'
    'Microsoft.Web/sites'
    'Microsoft.Web/sites/config'
    'Microsoft.Web/sites/networkConfig'
  )
  $orphanTypes = @($types | Where-Object { $_ -notin $supportedTypes } | Sort-Object -Unique)
  if ($orphanTypes.Count -ne 0) {
    throw "Compiled inventory contains unsupported orphan resource types: $($orphanTypes -join ', ')."
  }
  if (@($managed | Where-Object {
        $null -ne $_.PSObject.Properties['existing'] -and $_.existing -eq $true
      }).Count -ne 0) {
    throw 'Compiled managed inventory contains existing resources.'
  }
  return $managed
}
