//APIM

targetScope = 'resourceGroup'

@description('Name of the API Management service.')
param apimName string

@description('Azure region for the APIM instance.')
param location string

@description('Email address of the API publisher.  Shown in the developer portal.')
param publisherEmail string

@description('Name of the API publisher.  Shown in the developer portal.')
param publisherName string

@description('The resource ID of the subnet used for APIM outbound VNet integration.')
param vnetSubnetId string

@description('The default hostname of the Function App (e.g. <app>.azurewebsites.net).')
param functionHostName string

@description('The system key named mcp_extension from the Function App.  This key is required for the APIM to authenticate with the MCP extension.  Retrieve itfrom the Function App after deployment via the Azure portal or CLI.')
@secure()
param mcpFunctionsKey string

@description('Path segment for the MCP API exposed via APIM.')
param apiPath string = 'mcp'

@description('SKU name for APIM.  Must be StandardV2 or Premium for VNet integration.')
param skuName string = 'StandardV2'

@description('Capacity unit for the APIM instance.')
param skuCapacity int = 1


// APIM サービス
resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkConfiguration: {
      subnetResourceId: vnetSubnetId
    }
    virtualNetworkType: 'External'
    publicNetworkAccess: 'Enabled'
    // Additional optional settings can be specified here, such as
    // customProperties to disable older TLS protocols.
  }
}

// Named Value に MCP システムキーを保存
resource mcpKey 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = if (!empty(mcpFunctionsKey)) {
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
  name: apiPath
  properties: {
    displayName: 'MCP API'
    path: apiPath
    // Host name only; operations will include the full MCP extension path
    serviceUrl: 'https://${functionHostName}'
    protocols: [ 'https' ]
    subscriptionRequired: false
  }
}

// MCP API のポリシー定義
resource mcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = if (!empty(mcpFunctionsKey)) {
  parent: mcpApi
  name: 'policy'
  // Named Value の作成順序を保証
  dependsOn: [ mcpKey ]
  properties: {
    format: 'xml'
    value: '''
    <policies>
        <inbound>
            <base />
            <!-- Functions 認証：mcp_extension の system key を Named value から -->
            <set-header name="x-functions-key" exists-action="override">
                <value>{{mcp-functions-key}}</value>
            </set-header>
            <!-- GET のときだけ SSE 用ヘッダーを付与 -->
            <choose>
                <when condition="@(context.Request.Method == \"GET\")">
                    <set-header name="Accept" exists-action="override">
                        <value>text/event-stream</value>
                    </set-header>
                    <set-header name="Cache-Control" exists-action="override">
                        <value>no-cache</value>
                    </set-header>
                </when>
            </choose>
        </inbound>
        <backend>
            <!-- SSE はバッファ無効が必須 -->
            <forward-request buffer-response="false" timeout="300" />
        </backend>
        <outbound>
            <base />
            <!-- GET 応答だけ event-stream にする -->
            <choose>
                <when condition="@(context.Request.Method == \"GET\")">
                    <set-header name="Content-Type" exists-action="override">
                        <value>text/event-stream</value>
                    </set-header>
                </when>
            </choose>
        </outbound>
        <on-error>
            <base />
        </on-error>
    </policies>
    '''
  }
}

// SSE GET と message POST 操作
resource sseOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: mcpApi
  name: 'sse'
  properties: {
    displayName: 'Server Sent Events'
    method: 'GET'
    // Map to /runtime/webhooks/mcp/sse on the Function App
    urlTemplate: '/runtime/webhooks/mcp/sse'
    responses: [ { statusCode: 200 } ]
  }
}

// Define the message POST operation exposed at /mcp/message.  The backend
// endpoint relative to the base serviceUrl is /message.
resource messageOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: mcpApi
  name: 'message'
  properties: {
    displayName: 'MCP Message'
    method: 'POST'
    // Map to /runtime/webhooks/mcp/message on the Function App
    urlTemplate: '/runtime/webhooks/mcp/message'
    request: {
      queryParameters: []
    }
    responses: [ { statusCode: 200 } ]
  }
}

// Product の作成（サブスクリプション不要の公開プロダクト）
resource mcpProduct 'Microsoft.ApiManagement/service/products@2024-06-01-preview' = {
  parent: apim
  name: 'mcp'
  properties: {
    displayName: 'MCP'
    description: 'Managed Client Protocol API product'
    subscriptionRequired: false
    state: 'published'
  }
}

// API を Product に関連付け
resource mcpApiProductLink 'Microsoft.ApiManagement/service/products/apis@2024-06-01-preview' = {
  parent: mcpProduct
  name: mcpApi.name
}

output apimGatewayUrl string = 'https://${apim.name}.azure-api.net'
output mcpApiUrl string = 'https://${apim.name}.azure-api.net/${apiPath}'
