targetScope = 'resourceGroup'

@description('AI Gateway resource name in the current resource group.')
param gatewayName string

@description('AI Gateway default hostname (without scheme).')
param runtimeHostname string

@description('AI Gateway API key resource name.')
param apiKeyName string = 'default'

@description('Resource group containing the Foundry project.')
param foundryAgentsResourceGroupName string

@description('Foundry AI Services account name.')
param foundryAgentsAccountName string

@description('Foundry project name.')
param foundryAgentsProjectName string

#disable-next-line BCP081
resource aiGateway 'Microsoft.ApiManagement/aigateways@2025-09-01-preview' existing = {
  name: gatewayName
}

#disable-next-line BCP081
resource runtimeApiKey 'Microsoft.ApiManagement/aigateways/apiKeys@2025-09-01-preview' existing = {
  parent: aiGateway
  name: apiKeyName
}

module githubConnection '../foundry-agents/github-connection.bicep' = {
  name: 'github-connection-${uniqueString(gatewayName, foundryAgentsProjectName)}'
  scope: resourceGroup(foundryAgentsResourceGroupName)
  params: {
    aiServicesName: foundryAgentsAccountName
    aiProjectName: foundryAgentsProjectName
    gatewayUrl: 'https://${runtimeHostname}'
    gatewayApiKey: runtimeApiKey.listSecrets().key
  }
}

output connectionId string = githubConnection.outputs.connectionId
output connectionName string = githubConnection.outputs.connectionName
