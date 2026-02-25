// Main orchestrator — composes all modules for the Microsoft Agents Starter Kit
targetScope = 'resourceGroup'

// ─── Required Parameters ───────────────────────────────────────────────────────

@description('Base name prefix for all resources')
param namePrefix string = ''

@description('Location for resources')
param location string = resourceGroup().location

@description('Bot/App registration client ID')
param botClientId string = ''

@description('Bot/App registration tenant ID')
param botTenantId string = ''

@secure()
@description('Bot/App registration client secret')
param botClientSecret string = ''

// ─── Azure OpenAI Parameters ───────────────────────────────────────────────────

@description('Set to true to create a new Azure OpenAI resource; false to use an existing one')
param createAzureOpenAi bool = false

@description('Azure OpenAI endpoint (required when createAzureOpenAi is false)')
param existingAzureOpenAiEndpoint string = ''

@description('Existing Azure OpenAI account name (required when createAzureOpenAi is false, for role assignment)')
param existingAzureOpenAiName string = ''

@description('Whether the existing Azure OpenAI is in the same resource group (if false, role assignment is handled by the deploy script)')
param aoaiSameResourceGroup bool = true

@description('Azure OpenAI deployment name')
param azureOpenAiDeployment string = 'gpt-4o-mini'

@description('Azure OpenAI API version')
param azureOpenAiApiVersion string = '2024-12-01-preview'

@description('Azure OpenAI model name (only used when creating new)')
param azureOpenAiModelName string = 'gpt-4o-mini'

@description('Azure OpenAI model version (only used when creating new)')
param azureOpenAiModelVersion string = '2024-11-20'

@description('Azure OpenAI account name (only used when creating new)')
param azureOpenAiName string = '${namePrefix}-openai'

// ─── Container Registry Parameters ─────────────────────────────────────────────

@description('Set to true to create an Azure Container Registry')
param useAcr bool = false

@description('ACR name (only used when useAcr is true)')
param acrName string = ''

@description('ACR SKU')
@allowed(['Basic', 'Standard', 'Premium'])
param acrSku string = 'Basic'

@description('Container image to deploy (e.g., myacr.azurecr.io/agent:latest)')
param containerImage string = 'mcr.microsoft.com/azurelinux/base/core:3.0'

// ─── Container App Parameters ──────────────────────────────────────────────────

@description('Container App name')
param acaName string = '${namePrefix}-app'

@description('Container CPU cores')
param acaCpuCores string = '0.25'

@description('Container memory')
param acaMemorySize string = '0.5Gi'

// ─── Log Analytics / ACA Environment Parameters ────────────────────────────────

@description('Log Analytics workspace name')
param logAnalyticsName string = '${namePrefix}-logs'

@description('Use an existing Log Analytics workspace')
param useExistingLogAnalytics bool = false

@description('Existing Log Analytics customer ID (for cross-RG existing workspace)')
param existingLogCustomerId string = ''

@secure()
@description('Existing Log Analytics shared key (for cross-RG existing workspace)')
param existingLogSharedKey string = ''

@description('Container App Environment name')
param acaEnvironmentName string = '${namePrefix}-env'

@description('Azure Bot Service name')
param botServiceName string = '${namePrefix}-bot'

// ─── Tags ───────────────────────────────────────────────────────────────────────

@description('Tags to apply to all resources')
param tags object = {
  project: 'microsoft-agents-starterkit'
}

// Merge azd tags for resource discovery
var azdTags = union(tags, {
  'azd-env-name': namePrefix
})

var azdServiceTags = union(azdTags, {
  'azd-service-name': 'agent'
})

// ─── Modules ────────────────────────────────────────────────────────────────────

// Container App Environment + Log Analytics
module acaEnv 'modules/container-app-environment.bicep' = {
  name: 'aca-environment'
  params: {
    logAnalyticsName: logAnalyticsName
    environmentName: acaEnvironmentName
    useExistingLogAnalytics: useExistingLogAnalytics
    existingLogCustomerId: existingLogCustomerId
    existingLogSharedKey: existingLogSharedKey
    location: location
    tags: azdTags
  }
}

// Container Registry (optional)
module acr 'modules/container-registry.bicep' = if (useAcr) {
  name: 'container-registry'
  params: {
    name: acrName
    location: location
    skuName: acrSku
    tags: azdServiceTags
  }
}

// Azure OpenAI (optional — create new)
module openAi 'modules/azure-openai.bicep' = if (createAzureOpenAi) {
  name: 'azure-openai'
  params: {
    name: azureOpenAiName
    location: location
    deploymentName: azureOpenAiDeployment
    modelName: azureOpenAiModelName
    modelVersion: azureOpenAiModelVersion
    tags: azdTags
  }
}

// Resolve the Azure OpenAI endpoint and resource name
var aoaiEndpoint = createAzureOpenAi ? openAi.outputs.endpoint : existingAzureOpenAiEndpoint
var aoaiName = createAzureOpenAi ? openAi.outputs.name : existingAzureOpenAiName

// Resolve the ACR login server for both new and existing ACR
var resolvedAcrLoginServer = useAcr ? acr.outputs.loginServer : (acrName != '' ? '${acrName}.azurecr.io' : '')

// Container App
module aca 'modules/container-app.bicep' = {
  name: 'container-app'
  params: {
    name: acaName
    location: location
    environmentId: acaEnv.outputs.environmentId
    containerImage: containerImage
    azureOpenAiEndpoint: aoaiEndpoint
    azureOpenAiDeployment: azureOpenAiDeployment
    azureOpenAiApiVersion: azureOpenAiApiVersion
    botClientId: botClientId
    botTenantId: botTenantId
    botClientSecret: botClientSecret
    cpuCores: acaCpuCores
    memorySize: acaMemorySize
    acrLoginServer: resolvedAcrLoginServer
    tags: azdServiceTags
  }
}

// Managed Identity role assignment (only when AOAI is in the same RG; cross-RG is handled by deploy script)
var assignRoleViaBicep = createAzureOpenAi || aoaiSameResourceGroup
module roles 'modules/managed-identity-roles.bicep' = if (assignRoleViaBicep) {
  name: 'role-assignments'
  params: {
    principalId: aca.outputs.principalId
    openAiAccountName: aoaiName
  }
}

// Azure Bot Service with Teams channel
module botService 'modules/bot-service.bicep' = {
  name: 'bot-service'
  params: {
    name: botServiceName
    msAppId: botClientId
    tenantId: botTenantId
    messagingEndpoint: 'https://${aca.outputs.fqdn}/api/messages'
    tags: azdTags
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────────

output acaFqdn string = aca.outputs.fqdn
output acaEndpoint string = 'https://${aca.outputs.fqdn}'
output messagingEndpoint string = 'https://${aca.outputs.fqdn}/api/messages'
output acaName string = aca.outputs.name
output acaPrincipalId string = aca.outputs.principalId
output acrLoginServer string = resolvedAcrLoginServer
output azureOpenAiEndpoint string = aoaiEndpoint
