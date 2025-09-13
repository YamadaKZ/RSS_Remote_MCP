// network.bicep
// VNet、サブネット、NSG、Private DNS の作成

targetScope = 'resourceGroup'

@description('Name of the virtual network to be created.')
param vnetName string
@description('Azure region for the virtual network and associated resources.')
param location string
@description('Address prefix for the virtual network.')
param vnetAddressPrefix string = '10.20.0.0/16'
@description('Address prefix for the subnet used by the Function App private endpoint.')
param peSubnetPrefix string = '10.20.0.0/24'
@description('Address prefix for the subnet used by APIM VNet integration.')
param apimSubnetPrefix string = '10.20.1.0/24'
@description('Name of the network security group to attach to the APIM subnet.')
param nsgName string = '${vnetName}-apim-nsg'
@description('Name of the private DNS zone used for AzureWebSites private link.')
param dnsZoneName string = 'privatelink.azurewebsites.net'

// NSG を作成し、APIM サブネットにストレージ宛て HTTPS のみ許可するルールを付与:contentReference[oaicite:1]{index=1}。
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-out-storage-443'
        properties: {
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          priority: 100
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Storage'
        }
      }
    ]
  }
}

// VNet と 2 つのサブネットを作成。APIM 用サブネットは Microsoft.Web/serverFarms に委任:contentReference[oaicite:2]{index=2}。
resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        name: 'snet-apim-int'
        properties: {
          addressPrefix: apimSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.Web/serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          networkSecurityGroup: {
            id: nsg.id
          }
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
  dependsOn: [nsg]
}

// Private DNS ゾーンと VNet リンクの作成
resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: dnsZoneName
  location: 'global'
}

resource dnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  name: '${dnsZone.name}/link-${vnet.name}'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

output vnetId string = vnet.id
output peSubnetId string = vnet.properties.subnets[0].id
output apimSubnetId string = vnet.properties.subnets[1].id
output nsgId string = nsg.id
output dnsZoneId string = dnsZone.id
