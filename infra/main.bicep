// main.bicep
// ネットワーク、Function、APIM の各モジュールを呼び出すエントリーポイントです。

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the virtual network.')
param vnetName string = 'mcp-vnet'

@description('Name of the Function App.')
param functionName string = 'mcpfunc${uniqueString(resourceGroup().id)}'

@description('Name of the storage account.')
param storageAccountName string = toLower(replace('${functionName}sa', '-', ''))

@description('Name of the App Service plan.')
param appServicePlanName string = 'asp-${functionName}'

@description('Name of the Application Insights instance.')
param appInsightsName string = 'appi-${functionName}'

@description('Name of the API Management service.')
param apimName string = 'apim-${functionName}'

@description('Publisher email for APIM.')
param publisherEmail string = 'admin@example.com'

@description('Publisher name for APIM.')
param publisherName string = 'mcp'

@secure()
@description('System key (mcp_extension) from the Function App. Leave empty on initial deployment.')
param mcpFunctionsKey string = ''

// ネットワークモジュール
module network './network.bicep' = {
  name: 'network'
  params: {
    vnetName: vnetName
    location: location
  }
}

// Function モジュール
module function './function.bicep' = {
  name: 'function'
  params: {
    functionName: functionName
    location: location
    storageAccountName: storageAccountName
    appServicePlanName: appServicePlanName
    appInsightsName: appInsightsName
    peSubnetId: network.outputs.peSubnetId
    dnsZoneId: network.outputs.dnsZoneId
  }
}

// APIM モジュール
module apim './apim.bicep' = {
  name: 'apim'
  params: {
    apimName: apimName
    location: location
    publisherEmail: publisherEmail
    publisherName: publisherName
    vnetSubnetId: network.outputs.apimSubnetId
    functionHostName: function.outputs.functionHostName
    mcpFunctionsKey: mcpFunctionsKey
    apiPath: 'mcp'
  }
}

output functionUrl string = 'https://${function.outputs.functionHostName}'
output apimUrl string = apim.outputs.apimGatewayUrl
