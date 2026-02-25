// Azure Bot Service registration with Teams and M365 Copilot channels

@description('Bot registration name')
param name string

@description('Bot/App registration client ID (Microsoft App ID)')
param msAppId string

@description('Bot/App registration tenant ID')
param tenantId string

@description('Bot messaging endpoint URL')
param messagingEndpoint string

@description('Tags to apply to resources')
param tags object = {}

resource bot 'Microsoft.BotService/botServices@2023-09-15-preview' = {
  name: name
  location: 'global'
  tags: tags
  kind: 'azurebot'
  sku: {
    name: 'F0'
  }
  properties: {
    displayName: name
    msaAppId: msAppId
    msaAppTenantId: tenantId
    msaAppType: 'SingleTenant'
    endpoint: messagingEndpoint
  }
}

// Teams channel
resource teamsChannel 'Microsoft.BotService/botServices/channels@2023-09-15-preview' = {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: {
      isEnabled: true
      acceptedTerms: true
    }
  }
}

// M365 Extensions channel (for M365 Copilot)
resource m365Channel 'Microsoft.BotService/botServices/channels@2023-09-15-preview' = {
  parent: bot
  name: 'M365Extensions'
  location: 'global'
  properties: {
    channelName: 'M365Extensions'
  }
}

output botId string = bot.properties.msaAppId
output botName string = bot.name
