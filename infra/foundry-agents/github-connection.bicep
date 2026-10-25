targetScope = 'resourceGroup'

param aiServicesName string
param aiProjectName string
param gatewayUrl string
@secure()
param gatewayApiKey string

var normalizedGatewayUrl = endsWith(gatewayUrl, '/') ? take(gatewayUrl, length(gatewayUrl) - 1) : gatewayUrl

resource aiServices 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiServicesName
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: aiServices
  name: aiProjectName
}

resource githubConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: aiProject
  name: 'aigw-github'
  properties: {
    category: 'RemoteTool'
    authType: 'CustomKeys'
    target: '${normalizedGatewayUrl}/default/mcp/github/mcp'
    credentials: {
      keys: {
        'Api-Key': gatewayApiKey
      }
    }
    isSharedToAll: true
    metadata: {
      type: 'custom_MCP'
    }
  }
}
