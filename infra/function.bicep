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

var storageSuffix = environment().suffixes.storage

// ストレージアカウント
resource storage 'Microsoft.Storage/storageAccounts@2024-02-01' = {
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
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    RetentionInDays: 90
  }
}

var storageKeys = listKeys(storage.id, '2024-02-01')
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storageKeys.keys[0].value};EndpointSuffix=${storageSuffix}'

// Function App
resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
  name: functionName
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: empty(peSubnetId) ? 'Enabled' : 'Disabled'
    siteConfig: {
      linuxFxVersion: 'Python|${pythonVersion}'
      ftpsState: 'FtpsOnly'
      minimumElasticInstanceCount: 0
    }
    appSettings: [
      { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
      { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
      { name: 'AzureWebJobsStorage', value: storageConnectionString }
      { name: 'APPINSIGHTS_INSTRUMENTATIONKEY', value: appInsights.properties.InstrumentationKey }
      { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
    ]
  }
  dependsOn: [plan, storage, appInsights]
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
  dependsOn: [functionApp]
}

// DNS zone group
resource peDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = if (!empty(peSubnetId)) {
  name: '${pe.name}/default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'azurewebsites'
        properties: { privateDnsZoneId: dnsZoneId }
      }
    ]
  }
  dependsOn: [pe]
}

output functionHostName string = functionApp.properties.defaultHostName
output functionAppId string = functionApp.id
output appInsightsKey string = appInsights.properties.InstrumentationKey
output storageAccountId string = storage.id
