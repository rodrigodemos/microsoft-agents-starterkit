// Azure OpenAI account and model deployment

@description('Azure OpenAI account name')
param name string

@description('Location for resources')
param location string = resourceGroup().location

@description('Model deployment name')
param deploymentName string = 'gpt-4o'

@description('Model name')
param modelName string = 'gpt-4o'

@description('Model version')
param modelVersion string = '2024-11-20'

@description('Model deployment capacity (TPM in thousands)')
param deploymentCapacity int = 10

@description('Tags to apply to resources')
param tags object = {}

resource openAi 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  parent: openAi
  name: deploymentName
  sku: {
    name: 'Standard'
    capacity: deploymentCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

output endpoint string = openAi.properties.endpoint
output name string = openAi.name
output id string = openAi.id
