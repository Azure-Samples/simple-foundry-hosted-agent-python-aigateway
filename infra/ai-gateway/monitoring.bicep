targetScope = 'resourceGroup'

param location string
param tags object = {}
param enableMonitoring bool = true
param appInsightsName string
param logAnalyticsWorkspaceName string

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (enableMonitoring) {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (enableMonitoring) {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    #disable-next-line BCP037
    AzureMonitorWorkspaceIngestionMode: 'Enabled'
  }
}

output appInsightsId string = enableMonitoring ? appInsights.id : ''
output appInsightsName string = enableMonitoring ? appInsights.name : ''
output logAnalyticsWorkspaceId string = enableMonitoring ? logAnalyticsWorkspace.id : ''
output logAnalyticsWorkspaceName string = enableMonitoring ? logAnalyticsWorkspace.name : ''
