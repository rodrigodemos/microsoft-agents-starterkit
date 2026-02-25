// Azure Container Registry (Basic SKU — cheapest)

@description('Container Registry name (must be globally unique, alphanumeric only)')
param name string

@description('Location for resources')
param location string = resourceGroup().location

@description('Tags to apply to resources')
param tags object = {}

@description('ACR SKU')
@allowed(['Basic', 'Standard', 'Premium'])
param skuName string = 'Basic'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    adminUserEnabled: true
  }
}

output loginServer string = acr.properties.loginServer
output name string = acr.name
output id string = acr.id
