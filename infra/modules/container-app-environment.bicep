// Log Analytics workspace and Container App Environment (Consumption tier)

@description('Log Analytics workspace name (used when creating new or referencing existing in same RG)')
param logAnalyticsName string = ''

@description('Container App Environment name')
param environmentName string

@description('Location for resources')
param location string = resourceGroup().location

@description('Tags to apply to resources')
param tags object = {}

@description('Use an existing Log Analytics workspace instead of creating one')
param useExistingLogAnalytics bool = false

@description('Existing Log Analytics customer ID (workspace ID). Required when existing workspace is in a different RG.')
param existingLogCustomerId string = ''

@secure()
@description('Existing Log Analytics shared key. Required when existing workspace is in a different RG.')
param existingLogSharedKey string = ''

// When using existing from same RG, we can reference it directly
var useExistingRef = useExistingLogAnalytics && empty(existingLogCustomerId)

// Log Analytics Workspace (create new)
resource logAnalyticsNew 'Microsoft.OperationalInsights/workspaces@2022-10-01' = if (!useExistingLogAnalytics) {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Reference existing Log Analytics Workspace (same RG only)
resource logAnalyticsExisting 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = if (useExistingRef) {
  name: logAnalyticsName
}

var logCustomerId = useExistingLogAnalytics
  ? (!empty(existingLogCustomerId) ? existingLogCustomerId : logAnalyticsExisting.properties.customerId)
  : logAnalyticsNew.properties.customerId
var logSharedKey = useExistingLogAnalytics
  ? (!empty(existingLogSharedKey) ? existingLogSharedKey : logAnalyticsExisting.listKeys().primarySharedKey)
  : logAnalyticsNew.listKeys().primarySharedKey

// Container App Environment (Consumption plan — cheapest, scale to zero)
resource environment 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logCustomerId
        sharedKey: logSharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

output environmentId string = environment.id
output environmentNameOut string = environment.name
