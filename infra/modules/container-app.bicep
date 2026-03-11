// Container App with scale-to-zero and system-assigned managed identity

@description('Container App name')
param name string

@description('Location for resources')
param location string = resourceGroup().location

@description('Container App Environment resource ID')
param environmentId string

@description('Container image to deploy')
param containerImage string

@description('Tags to apply to resources')
param tags object = {}

// Environment variables (non-secret)
@description('Azure OpenAI endpoint URL')
param azureOpenAiEndpoint string

@description('Azure OpenAI deployment name')
param azureOpenAiDeployment string

@description('Azure OpenAI API version')
param azureOpenAiApiVersion string = '2025-01-01-preview'

@description('Bot/App registration client ID')
param botClientId string

@description('Bot/App registration tenant ID')
param botTenantId string

// Secrets
@secure()
@description('Bot/App registration client secret')
param botClientSecret string

@description('Container CPU cores')
param cpuCores string = '0.25'

@description('Container memory')
param memorySize string = '0.5Gi'

@description('ACR login server (e.g., myacr.azurecr.io). Empty if no ACR.')
param acrLoginServer string = ''

// ─── Agent Identity Parameters ─────────────────────────────────────────────────

@description('Agent Identity Blueprint client ID (empty = skip Agent Identity config)')
param agentBlueprintClientId string = ''

@description('Agent Identity client ID')
param agentIdentityClientId string = ''

@secure()
@description('Agent Identity Blueprint client secret (transition credential)')
param agentBlueprintClientSecret string = ''

// Determine whether Agent Identity is configured
var hasAgentIdentity = agentBlueprintClientId != ''
var hasAgentBlueprintSecret = agentBlueprintClientSecret != ''

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 3978
        transport: 'http'
        allowInsecure: false
      }
      registries: acrLoginServer != '' ? [
        {
          server: acrLoginServer
          identity: 'system'
        }
      ] : []
      secrets: concat([
        {
          name: 'bot-client-secret'
          value: botClientSecret
        }
      ], hasAgentBlueprintSecret ? [
        {
          name: 'blueprint-client-secret'
          value: agentBlueprintClientSecret
        }
      ] : [])
    }
    template: {
      containers: [
        {
          name: 'agent'
          image: containerImage
          resources: {
            cpu: json(cpuCores)
            memory: memorySize
          }
          env: concat([
            { name: 'AZURE_OPENAI_ENDPOINT', value: azureOpenAiEndpoint }
            { name: 'AZURE_OPENAI_DEPLOYMENT', value: azureOpenAiDeployment }
            { name: 'AZURE_OPENAI_API_VERSION', value: azureOpenAiApiVersion }
            { name: 'CLIENT_ID', value: botClientId }
            { name: 'TENANT_ID', value: botTenantId }
            { name: 'CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID', value: botClientId }
            { name: 'CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET', secretRef: 'bot-client-secret' }
            { name: 'CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID', value: botTenantId }
            { name: 'CONNECTIONS__SERVICE_CONNECTION__SETTINGS__SCOPES', value: '' }
            { name: 'CONNECTIONSMAP_0_SERVICEURL', value: '*' }
            { name: 'CONNECTIONSMAP_0_CONNECTION', value: 'SERVICE_CONNECTION' }
            { name: 'PORT', value: '3978' }
          ], hasAgentIdentity ? [
            // Agent Identity configuration
            { name: 'AGENT_BLUEPRINT_CLIENT_ID', value: agentBlueprintClientId }
            { name: 'AGENT_IDENTITY_CLIENT_ID', value: agentIdentityClientId }
            { name: 'AUTH_HANDLER_NAME', value: 'AGENTIC' }
            { name: 'AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__TYPE', value: 'UserAuthorization' }
            { name: 'AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME', value: 'AgentIdentityOBO' }
            { name: 'AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__SCOPES', value: '' }
            { name: 'CONNECTIONS__BLUEPRINT_CONNECTION__SETTINGS__CLIENTID', value: agentBlueprintClientId }
            { name: 'CONNECTIONS__BLUEPRINT_CONNECTION__SETTINGS__TENANTID', value: botTenantId }
            { name: 'CONNECTIONS__BLUEPRINT_CONNECTION__SETTINGS__AUTHTYPE', value: 'ClientSecret' }
          ] : [], hasAgentBlueprintSecret ? [
            { name: 'CONNECTIONS__BLUEPRINT_CONNECTION__SETTINGS__CLIENTSECRET', secretRef: 'blueprint-client-secret' }
          ] : [])
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
        rules: [
          {
            name: 'http-rule'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

output fqdn string = containerApp.properties.configuration.ingress.fqdn
output principalId string = containerApp.identity.principalId
output name string = containerApp.name
