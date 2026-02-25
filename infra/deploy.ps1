# ─── Microsoft Agents Starter Kit — Azure Deployment (PowerShell) ────────────────
# Interactive script that deploys infrastructure via Bicep and optionally builds
# and pushes a container image.
# ─────────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$DeploymentName = "agents-starterkit"

Write-Host "========================================"
Write-Host " Microsoft Agents Starter Kit - Deploy"
Write-Host "========================================"
Write-Host ""

# ─── Read defaults from env/.env.local ───────────────────────────────────────────

function Read-EnvValue {
    param([string]$File, [string]$Key)
    if (Test-Path $File) {
        $line = Get-Content $File | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
        if ($line) { return ($line -replace "^$Key=", "").Trim() }
    }
    return ""
}

$EnvLocal = Join-Path $RootDir "env\.env.local"
$DotEnv = Join-Path $RootDir ".env"

$DefaultAoaiEndpoint = Read-EnvValue -File $EnvLocal -Key "AZURE_OPENAI_ENDPOINT"
$DefaultAoaiDeployment = Read-EnvValue -File $EnvLocal -Key "AZURE_OPENAI_DEPLOYMENT"
$DefaultAoaiApiVersion = Read-EnvValue -File $EnvLocal -Key "AZURE_OPENAI_API_VERSION"
$DefaultBotId = Read-EnvValue -File $EnvLocal -Key "BOT_ID"
$DefaultBotTenantId = Read-EnvValue -File $EnvLocal -Key "TEAMS_APP_TENANT_ID"
$DefaultBotSecret = Read-EnvValue -File $DotEnv -Key "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET"

# ─── Prompt Helpers ──────────────────────────────────────────────────────────────

function Prompt-Value {
    param(
        [string]$PromptText,
        [string]$Default = "",
        [switch]$Required
    )
    if ($Default) {
        $value = Read-Host "$PromptText [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    } else {
        do {
            $value = Read-Host $PromptText
        } while ($Required -and [string]::IsNullOrWhiteSpace($value))
    }
    return $value
}

function Prompt-YesNo {
    param(
        [string]$PromptText,
        [string]$Default = "n"
    )
    $value = Read-Host "$PromptText [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    return ($value -match "^[yY]")
}

# ─── Gather Configuration ───────────────────────────────────────────────────────

Write-Host "--- Resource Group ---"
$ResourceGroup = Prompt-Value -PromptText "Resource group name" -Default "rg-agents-starterkit"
$Location = Prompt-Value -PromptText "Azure region" -Default "eastus2"

Write-Host ""
Write-Host "--- Naming ---"
$NamePrefix = Prompt-Value -PromptText "Resource name prefix (used for all resources)" -Default "agents-starter"
$NamePrefix = $NamePrefix.TrimEnd('-')

# ─── Log Analytics / ACA Environment ────────────────────────────────────────────

Write-Host ""
Write-Host "--- Log Analytics & ACA Environment ---"
$UseExistingLog = Prompt-YesNo -PromptText "Use an existing Log Analytics workspace? (y/n)" -Default "n"
$LogAnalyticsName = Prompt-Value -PromptText "Log Analytics workspace name" -Default "$NamePrefix-logs"
$LogCustomerId = ""
$LogSharedKey = ""
if ($UseExistingLog) {
    $LogResourceGroup = Prompt-Value -PromptText "Log Analytics resource group" -Default $ResourceGroup
    if ($LogResourceGroup -ne $ResourceGroup) {
        $LogSubscription = Prompt-Value -PromptText "Log Analytics subscription (ID or name, leave blank if same)" -Default ""
        $subArg = if ($LogSubscription) { "--subscription $LogSubscription" } else { "" }
        Write-Host "  Fetching workspace credentials from $LogResourceGroup..."
        $LogCustomerId = Invoke-Expression "az monitor log-analytics workspace show --workspace-name $LogAnalyticsName --resource-group $LogResourceGroup --query customerId -o tsv $subArg"
        $LogSharedKey = Invoke-Expression "az monitor log-analytics workspace get-shared-keys --workspace-name $LogAnalyticsName --resource-group $LogResourceGroup --query primarySharedKey -o tsv $subArg"
    }
}
$AcaEnvName = Prompt-Value -PromptText "Container App Environment name" -Default "$NamePrefix-env"

# ─── Bot Registration ───────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Bot Registration ---"

$ReuseBot = $false
if ($DefaultBotId) {
    Write-Host "Found existing bot registration in env/.env.local:"
    Write-Host "  BOT_ID:        $DefaultBotId"
    Write-Host "  BOT_TENANT_ID: $(if ($DefaultBotTenantId) { $DefaultBotTenantId } else { '<not found>' })"
    $ReuseBot = Prompt-YesNo -PromptText "Reuse this bot registration? (y/n)" -Default "y"
}

if ($ReuseBot) {
    $BotClientId = $DefaultBotId
    $BotTenantId = $DefaultBotTenantId
    if (-not $BotTenantId) {
        $BotTenantId = Prompt-Value -PromptText "Bot App registration tenant ID (GUID)" -Required
    }
    if ($DefaultBotSecret) {
        Write-Host "  Client secret found in .env"
        $UseExistingSecret = Prompt-YesNo -PromptText "Use existing client secret? (y/n)" -Default "y"
        if ($UseExistingSecret) {
            $BotClientSecret = $DefaultBotSecret
        } else {
            $BotClientSecret = Prompt-Value -PromptText "Bot App registration client secret" -Required
        }
    } else {
        Write-Host "  Client secret not found in .env — run a local debug (F5) first, or copy it from Azure Portal > App registrations > Certificates & secrets."
        $BotClientSecret = Prompt-Value -PromptText "Bot App registration client secret" -Required
    }
} else {
    Write-Host "You need an Entra ID app registration for the bot."
    Write-Host "Create one at https://portal.azure.com > App registrations."
    $BotClientId = Prompt-Value -PromptText "Bot App registration client ID (GUID)" -Required
    $BotTenantId = Prompt-Value -PromptText "Bot App registration tenant ID (GUID)" -Required
    $BotClientSecret = Prompt-Value -PromptText "Bot App registration client secret" -Required
}

# ─── Azure OpenAI ────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Azure OpenAI ---"
$CreateAoai = Prompt-YesNo -PromptText "Create a new Azure OpenAI resource? (y/n)" -Default "n"

$AoaiEndpoint = ""
$AoaiResourceName = ""
$AoaiResourceGroup = $ResourceGroup

$AoaiNewName = ""

if (-not $CreateAoai) {
    $aoaiDefault = if ($DefaultAoaiEndpoint) { $DefaultAoaiEndpoint } else { "" }
    $AoaiEndpoint = Prompt-Value -PromptText "Azure OpenAI endpoint URL" -Default $aoaiDefault -Required

    # Derive resource name from endpoint
    $DerivedAoaiName = ""
    if ($AoaiEndpoint -match "https://([^.]+)\.openai\.azure\.com") {
        $DerivedAoaiName = $Matches[1]
    }
    $AoaiResourceName = Prompt-Value -PromptText "Azure OpenAI resource name" -Default $DerivedAoaiName -Required
    $AoaiResourceGroup = Prompt-Value -PromptText "Azure OpenAI resource group (for role assignment)" -Default $ResourceGroup
    $AoaiSubscription = ""
    if ($AoaiResourceGroup -ne $ResourceGroup) {
        $AoaiSubscription = Prompt-Value -PromptText "Azure OpenAI subscription (ID or name, leave blank if same)" -Default ""
    }
} else {
    $AoaiNewName = Prompt-Value -PromptText "Azure OpenAI account name" -Default "$NamePrefix-openai"
}

$AoaiSameRg = if ($CreateAoai -or ($AoaiResourceGroup -eq $ResourceGroup)) { "true" } else { "false" }

$deployDefault = if ($DefaultAoaiDeployment) { $DefaultAoaiDeployment } else { "gpt-4o-mini" }
$AoaiDeployment = Prompt-Value -PromptText "Azure OpenAI deployment name" -Default $deployDefault

$apiVerDefault = if ($DefaultAoaiApiVersion) { $DefaultAoaiApiVersion } else { "2024-12-01-preview" }
$AoaiApiVersion = Prompt-Value -PromptText "Azure OpenAI API version" -Default $apiVerDefault

# ─── Container Registry ─────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Container Registry ---"
Write-Host "Container Registry options:"
Write-Host "  1) Create new ACR"
Write-Host "  2) Use existing ACR"
Write-Host "  3) No ACR (ACA source deploy)"
$acrChoice = Read-Host "Choice [1]"
if ([string]::IsNullOrWhiteSpace($acrChoice)) { $acrChoice = "1" }

$UseAcr = $false
$CreateAcr = $false
$AcrName = ""
$AcrSku = "Basic"
$AcrLoginServer = ""

switch ($acrChoice) {
    "1" {
        $UseAcr = $true
        $CreateAcr = $true
        $DefaultAcrName = ($NamePrefix -replace "-", "") + "acr"
        $AcrName = Prompt-Value -PromptText "ACR name (globally unique, alphanumeric)" -Default $DefaultAcrName
        Write-Host "ACR SKU:"
        Write-Host "  1) Basic (default)"
        Write-Host "  2) Standard"
        Write-Host "  3) Premium"
        $skuChoice = Read-Host "Choice [Basic]"
        switch ($skuChoice) {
            "2" { $AcrSku = "Standard" }
            "Standard" { $AcrSku = "Standard" }
            "3" { $AcrSku = "Premium" }
            "Premium" { $AcrSku = "Premium" }
            default { $AcrSku = "Basic" }
        }
    }
    "2" {
        $UseAcr = $true
        $CreateAcr = $false
        $AcrName = Prompt-Value -PromptText "Existing ACR name" -Required
        $AcrResourceGroup = Prompt-Value -PromptText "ACR resource group" -Default $ResourceGroup
        $AcrLoginServer = "$AcrName.azurecr.io"
        Write-Host "  Using existing ACR: $AcrLoginServer"
    }
    default {
        Write-Host "  No ACR — will use ACA source deploy."
    }
}

# ─── Container App ──────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Container App ---"
$AcaName = Prompt-Value -PromptText "Container App name" -Default "$NamePrefix-app"

Write-Host "Container App size:"
Write-Host "  1) Small  - 0.25 CPU, 0.5 Gi (default)"
Write-Host "  2) Medium - 0.5 CPU, 1 Gi"
Write-Host "  3) Large  - 1 CPU, 2 Gi"
$sizeChoice = Read-Host "Choice [1]"
switch ($sizeChoice) {
    "2" { $AcaCpu = "0.5"; $AcaMemory = "1Gi" }
    "Medium" { $AcaCpu = "0.5"; $AcaMemory = "1Gi" }
    "3" { $AcaCpu = "1"; $AcaMemory = "2Gi" }
    "Large" { $AcaCpu = "1"; $AcaMemory = "2Gi" }
    default { $AcaCpu = "0.25"; $AcaMemory = "0.5Gi" }
}

# ─── Pre-deployment Summary ─────────────────────────────────────────────────────

Write-Host ""
Write-Host "========================================"
Write-Host " Deployment Summary"
Write-Host "========================================"
Write-Host ""
Write-Host "  Resource Group:     $ResourceGroup ($Location)"
Write-Host "  Name Prefix:        $NamePrefix"
Write-Host ""
Write-Host "  Bot Client ID:      $BotClientId"
Write-Host "  Bot Tenant ID:      $BotTenantId"
Write-Host ""
if ($CreateAoai) {
    Write-Host "  Azure OpenAI:       Create new ($AoaiNewName)"
} else {
    Write-Host "  Azure OpenAI:       Use existing ($AoaiResourceName)"
    Write-Host "  AOAI Endpoint:      $AoaiEndpoint"
    Write-Host "  AOAI Resource Group: $AoaiResourceGroup"
}
Write-Host "  AOAI Deployment:    $AoaiDeployment"
Write-Host "  AOAI API Version:   $AoaiApiVersion"
Write-Host ""
if ($UseAcr) {
    if ($CreateAcr) {
        Write-Host "  Container Registry: Create new $AcrName ($AcrSku)"
    } else {
        Write-Host "  Container Registry: Use existing $AcrName ($AcrLoginServer)"
    }
} else {
    Write-Host "  Container Registry: None (ACA source deploy)"
}
Write-Host "  Container App:      $AcaName ($AcaCpu CPU, $AcaMemory)"
Write-Host "  ACA Environment:   $AcaEnvName"
Write-Host "  Log Analytics:     $LogAnalyticsName$(if ($UseExistingLog) { ' (existing)' } else { ' (new)' })"
Write-Host ""

$Proceed = Prompt-YesNo -PromptText "Proceed with deployment? (y/n)" -Default "y"
if (-not $Proceed) {
    Write-Host "Deployment cancelled."
    exit 0
}

# ─── Create Resource Group ──────────────────────────────────────────────────────

$rgExists = az group show --name $ResourceGroup 2>$null
if (-not $rgExists) {
    Write-Host ""
    Write-Host "Creating resource group '$ResourceGroup' in '$Location'..."
    az group create --name $ResourceGroup --location $Location --output none
} else {
    Write-Host ""
    Write-Host "Using existing resource group '$ResourceGroup'."
}

# ─── What-If Preview ────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "========================================"
Write-Host " Running what-if preview..."
Write-Host "========================================"

$ContainerImage = "mcr.microsoft.com/azurelinux/base/core:3.0"

az deployment group what-if `
    --resource-group $ResourceGroup `
    --name $DeploymentName `
    --template-file "$ScriptDir\main.bicep" `
    --parameters `
        namePrefix=$NamePrefix `
        location=$Location `
        botClientId=$BotClientId `
        botTenantId=$BotTenantId `
        botClientSecret=$BotClientSecret `
        createAzureOpenAi=$($CreateAoai.ToString().ToLower()) `
        existingAzureOpenAiEndpoint=$AoaiEndpoint `
        existingAzureOpenAiName=$AoaiResourceName `
        azureOpenAiName=$AoaiNewName `
        azureOpenAiDeployment=$AoaiDeployment `
        azureOpenAiApiVersion=$AoaiApiVersion `
        useAcr=$($CreateAcr.ToString().ToLower()) `
        acrName=$AcrName `
        acrSku=$AcrSku `
        acaName=$AcaName `
        acaCpuCores=$AcaCpu `
        acaMemorySize=$AcaMemory `
        logAnalyticsName=$LogAnalyticsName `
        useExistingLogAnalytics=$($UseExistingLog.ToString().ToLower()) `
        existingLogCustomerId=$LogCustomerId `
        existingLogSharedKey=$LogSharedKey `
        acaEnvironmentName=$AcaEnvName `
        aoaiSameResourceGroup=$AoaiSameRg `
        containerImage=$ContainerImage `
    2>&1 | Out-Host

Write-Host ""
$DeployNow = Prompt-YesNo -PromptText "Deploy now? (y/n)" -Default "y"
if (-not $DeployNow) {
    Write-Host "Deployment cancelled."
    exit 0
}

# ─── Deploy Infrastructure ──────────────────────────────────────────────────────

Write-Host ""
Write-Host "========================================"
Write-Host " Deploying infrastructure via Bicep..."
Write-Host "========================================"

# Build and show the deployment tracking URL
$SubId = az account show --query id -o tsv
$RawId = "/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.Resources/deployments/$DeploymentName"
$EncodedId = [System.Uri]::EscapeDataString($RawId)
Write-Host ""
Write-Host "Track deployment in Azure Portal:"
Write-Host "  https://portal.azure.com/#view/HubsExtension/DeploymentDetailsBlade/~/overview/id/$EncodedId"
Write-Host ""

az deployment group create `
    --resource-group $ResourceGroup `
    --name $DeploymentName `
    --template-file "$ScriptDir\main.bicep" `
    --parameters `
        namePrefix=$NamePrefix `
        location=$Location `
        botClientId=$BotClientId `
        botTenantId=$BotTenantId `
        botClientSecret=$BotClientSecret `
        createAzureOpenAi=$($CreateAoai.ToString().ToLower()) `
        existingAzureOpenAiEndpoint=$AoaiEndpoint `
        existingAzureOpenAiName=$AoaiResourceName `
        azureOpenAiName=$AoaiNewName `
        azureOpenAiDeployment=$AoaiDeployment `
        azureOpenAiApiVersion=$AoaiApiVersion `
        useAcr=$($CreateAcr.ToString().ToLower()) `
        acrName=$AcrName `
        acrSku=$AcrSku `
        acaName=$AcaName `
        acaCpuCores=$AcaCpu `
        acaMemorySize=$AcaMemory `
        logAnalyticsName=$LogAnalyticsName `
        useExistingLogAnalytics=$($UseExistingLog.ToString().ToLower()) `
        existingLogCustomerId=$LogCustomerId `
        existingLogSharedKey=$LogSharedKey `
        acaEnvironmentName=$AcaEnvName `
        aoaiSameResourceGroup=$AoaiSameRg `
        containerImage=$ContainerImage

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Infrastructure deployment failed. Check the Azure Portal for details:"
    Write-Host "  https://portal.azure.com/#view/HubsExtension/DeploymentDetailsBlade/~/overview/id/$EncodedId"
    exit 1
}

Write-Host "Infrastructure deployment complete."

# Read outputs
$AcaFqdn = az deployment group show --resource-group $ResourceGroup --name $DeploymentName --query "properties.outputs.acaFqdn.value" -o tsv
$MessagingEndpoint = az deployment group show --resource-group $ResourceGroup --name $DeploymentName --query "properties.outputs.messagingEndpoint.value" -o tsv
$DeployedAoaiEndpoint = az deployment group show --resource-group $ResourceGroup --name $DeploymentName --query "properties.outputs.azureOpenAiEndpoint.value" -o tsv

if ($CreateAcr) {
    $AcrLoginServer = az deployment group show --resource-group $ResourceGroup --name $DeploymentName --query "properties.outputs.acrLoginServer.value" -o tsv
}

# ─── Handle cross-RG role assignment ─────────────────────────────────────────────

if ((-not $CreateAoai) -and ($AoaiResourceGroup -ne $ResourceGroup)) {
    Write-Host ""
    Write-Host "Azure OpenAI is in a different resource group ($AoaiResourceGroup)."
    Write-Host "Assigning Cognitive Services OpenAI User role to ACA managed identity..."
    try {
        $AcaPrincipalId = az deployment group show --resource-group $ResourceGroup --name $DeploymentName --query "properties.outputs.acaPrincipalId.value" -o tsv
        $aoaiSubArg = if ($AoaiSubscription) { "--subscription $AoaiSubscription" } else { "" }
        $AoaiFullId = Invoke-Expression "az cognitiveservices account show --name $AoaiResourceName --resource-group $AoaiResourceGroup --query id -o tsv $aoaiSubArg"
        az role assignment create `
            --role "Cognitive Services OpenAI User" `
            --assignee-object-id $AcaPrincipalId `
            --assignee-principal-type ServicePrincipal `
            --scope $AoaiFullId `
            --output none
        Write-Host "Role assignment complete."
    } catch {
        Write-Host "Warning: Could not assign role. Assign Cognitive Services OpenAI User role manually."
    }
}

# ─── Build and Deploy Container ─────────────────────────────────────────────────

Write-Host ""
Write-Host "========================================"
Write-Host " Building and deploying container..."
Write-Host "========================================"

if ($UseAcr) {
    $BuildRg = if ($CreateAcr) { $ResourceGroup } else { $AcrResourceGroup }
    Write-Host "Building image with ACR..."
    az acr build `
        --registry $AcrName `
        --resource-group $BuildRg `
        --image "agent:latest" `
        $RootDir

    Write-Host "Updating Container App with new image..."
    az containerapp update `
        --name $AcaName `
        --resource-group $ResourceGroup `
        --image "$AcrLoginServer/agent:latest" `
        --output none
} else {
    Write-Host "Deploying via ACA source deploy..."
    az containerapp up `
        --name $AcaName `
        --resource-group $ResourceGroup `
        --source $RootDir `
        --output none
}

# ─── Generate env/.env.azure ────────────────────────────────────────────────────

$EnvFile = Join-Path $RootDir "env\.env.azure"
$envContent = @"
# Auto-generated by deploy.ps1 - Azure deployment configuration
BOT_ID=$BotClientId
BOT_TENANT_ID=$BotTenantId
BOT_ENDPOINT=https://$AcaFqdn
BOT_DOMAIN=$AcaFqdn
AZURE_OPENAI_ENDPOINT=$DeployedAoaiEndpoint
AZURE_OPENAI_DEPLOYMENT=$AoaiDeployment
AZURE_OPENAI_API_VERSION=$AoaiApiVersion
RESOURCE_GROUP=$ResourceGroup
ACA_NAME=$AcaName
APP_NAME_SUFFIX=
"@

if ($UseAcr) {
    $envContent += "`nACR_LOGIN_SERVER=$AcrLoginServer"
    $envContent += "`nACR_NAME=$AcrName"
}

Set-Content -Path $EnvFile -Value $envContent

# ─── Summary ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "========================================"
Write-Host " Deployment Complete"
Write-Host "========================================"
Write-Host ""
Write-Host "  ACA Endpoint:       https://$AcaFqdn"
Write-Host "  Messaging Endpoint: $MessagingEndpoint"
Write-Host "  Health Check:       https://$AcaFqdn/api/health"
Write-Host "  AOAI Endpoint:      $DeployedAoaiEndpoint"
Write-Host "  Env file:           $EnvFile"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Publish Teams app: use M365 Agents Toolkit with m365agents.azure.yml"
Write-Host "  2. Teams admin approval: see README.md for details"
Write-Host ""
