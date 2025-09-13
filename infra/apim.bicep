// apim.bicep
// APIM (Standard v2) を作成し、MCP API と Named Value を構築します。

targetScope = 'resourceGroup'

@description('Name of the API Management service.')
param apimName string
@description('Azure region for the APIM instance.')
param location string
@description('Email address of the API publisher.')
param publisherEmail string
@description('Name of the API publisher.')
param publisherName string
@description('Resource ID of the subnet used for APIM outbound VNet integration.')
param vnetSubnetId string
@description('Default hostname of the Function App (e.g. <app>.azurewebsites.net).')
param functionHostName string
@description('System key named mcp_extension from the Function App.')
@secure()
param mcpFunctionsKey string
@description('Path segment for the MCP API exposed via APIM.')
param apiPath string = 'mcp'
@description('SKU name for APIM.')
param skuName string = 'StandardV2'
@description('Capacity unit for the APIM instance.')
param skuCapacity int = 1

// APIM サービス
resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: apimName
  location: location
  sku: { name: skuName; capacity: skuCapacity }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkConfiguration: {
      subnetResourceId: vnetSubnetId
    }
    virtualNetworkType: 'External'
    publicNetworkAccess: 'Enabled'
  }
}

// Named Value に MCP システムキーを保存
resource mcpKey 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'mcp-functions-key'
  properties: {
    displayName: 'mcp-functions-key'
    value: mcpFunctionsKey
    secret: true
  }
}

// MCP API
resource mcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: '${apiPath}'
  properties: {
    displayName: 'MCP API'
    path: apiPath
    serviceUrl: 'https://${functionHostName}/runtime/webhooks/mcp'
    protocols: [ 'https' ]
    subscriptionRequired: false
  }
  dependsOn: [mcpKey]
}

// ポリシー：x-functions-key を自動付与:contentReference[oaicite:4]{index=4}
resource mcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: mcpApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: '''<policies>
  <inbound>
    <set-header name="x-functions-key" exists-action="override">
      <value>{{mcp-functions-key}}</value>
    </set-header>
  </inbound>
  <backend>
    <forward-request />
  </backend>
  <outbound />
  <on-error />
</policies>'''
  }
}

// SSE GET と message POST 操作
resource sseOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: mcpApi
  name: 'sse'
  properties: {
    displayName: 'Server Sent Events'
    method: 'GET'
    urlTemplate: '/sse'
    responses: [ { statusCode: 200 } ]
  }
}

resource messageOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: mcpApi
  name: 'message'
  properties: {
    displayName: 'MCP Message'
    method: 'POST'
    urlTemplate: '/message'
    responses: [ { statusCode: 200 } ]
  }
}

output apimGatewayUrl string = 'https://${apim.name}.azure-api.net'
output mcpApiUrl string = 'https://${apim.name}.azure-api.net/${apiPath}'
