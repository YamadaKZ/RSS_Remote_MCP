// function.bicep
// ストレージ、App Service プラン、Application Insights、Function App を作成。
// peSubnetId を渡すと Private Endpoint を作成し、パブリックアクセスを無効にします:contentReference[oaicite:3]{index=3}。

targetScope = 'resourceGroup'

@description('Name of the Function App (must be globally unique).')
param functionName string
@description('Azure region for the Function App and related resources.')
param location string
@description('Name of the storage account used by the Function App.')
param storageAccountName string
@description('Name of the App Service plan.')
param appServicePlanName string
@description('Name of the Application Insights instance.')
param appInsightsName string
@description('ID of the subnet used for the Function’s private endpoint.')
param peSubnetId string
@description('ID of the private DNS zone for privatelink.azurewebsites.net.')
param dnsZoneId string
@description('Python version for the Function runtime.')
param pythonVersion string = '3.11'
@description('Name of the blob container used as the deployment source for Flex Consumption.')
param deploymentStorageContainerName string = 'deployments'
@description('Enable public network access to the Function App (required for Kudu/SCM based deployments like azd deploy).')
param enablePublicNetworkAccess bool = true

// removed: no longer needed after switching to identity-based AzureWebJobsStorage

// ストレージアカウント（2024-02-01 は japaneast で未登録のため 2024-01-01 を使用）
resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    allowSharedKeyAccess: true
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// Blob service (default) and container for Flex Consumption deployment source
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: deploymentStorageContainerName
  properties: {
    publicAccess: 'None'
  }
}

// App Service プラン (Flex Consumption)
resource plan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: appServicePlanName
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

// Application Insights
resource appInsights 'microsoft.insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    // LogAnalytics を指定するには WorkspaceResourceId が必須となるため、既定の ApplicationInsights を使用
    IngestionMode: 'ApplicationInsights'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    RetentionInDays: 90
  }
}

// 推奨: 関数ではなくリソース参照の listKeys() を使用
// removed: no longer needed after switching to identity-based AzureWebJobsStorage

// Function App
resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
  name: functionName
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  tags: {
    // azd がサービスを特定するためのタグ。azure.yaml の services.<name> に合わせる
    'azd-service-name': 'function'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: enablePublicNetworkAccess ? 'Enabled' : 'Disabled'
    siteConfig: {
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.2'
    }
    // Flex Consumption: functionAppConfig is REQUIRED on create
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          // primaryEndpoints.blob already ends with '/'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentStorageContainerName}'
          authentication: {
            // use system-assigned managed identity of the Function App
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: 'python'
        version: pythonVersion
      }
      // Optional but recommended: tune as needed
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
    }
  }
}

// アプリ設定は子リソースで構成
resource appSettings 'Microsoft.Web/sites/config@2024-11-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    // Host storage をマネージドIDで利用
    AzureWebJobsStorage__accountName: storage.name
    AzureWebJobsStorage__credential: 'managedidentity'
    APPINSIGHTS_INSTRUMENTATIONKEY: appInsights.properties.InstrumentationKey
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
  }
}

// Grant Function App's system-assigned identity access to the deployment container (storage account scope)
resource deployStorageBlobDataContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, 'blob-data-contributor', functionApp.name)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Host storage 用の推奨ロール: Blob Data Owner（ホスト管理操作で不足しないように安全側）
resource hostStorageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, 'blob-data-owner', functionApp.name)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b') // Storage Blob Data Owner
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// キュー拡張やホストでのキュー利用に備え Queue Data Contributor を付与
resource hostStorageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, 'queue-data-contributor', functionApp.name)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88') // Storage Queue Data Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Private Endpoint
resource pe 'Microsoft.Network/privateEndpoints@2024-07-01' = if (!empty(peSubnetId)) {
  name: 'pe-${functionName}'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'pe-${functionName}-connection'
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: ['sites']
        }
      }
    ]
  }
}

// DNS zone group
resource peDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = if (!empty(peSubnetId)) {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'azurewebsites'
        properties: { privateDnsZoneId: dnsZoneId }
      }
    ]
  }
}

output functionHostName string = functionApp.properties.defaultHostName
output functionAppId string = functionApp.id
output appInsightsKey string = appInsights.properties.InstrumentationKey
output storageAccountId string = storage.id
