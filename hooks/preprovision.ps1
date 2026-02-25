# preprovision.ps1 — Interactively prompts for configuration, sets defaults, and fetches cross-RG credentials

Write-Host "========================================"
Write-Host " Microsoft Agents Starter Kit - Configure"
Write-Host "========================================"
Write-Host ""

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

# ─── Helpers ─────────────────────────────────────────────────────────────────────

function Get-AzdEnv {
    param([string]$Key)
    try {
        $val = azd env get-value $Key 2>$null
        if ($LASTEXITCODE -ne 0) { return "" }
        if ($null -eq $val) { return "" }
        return "$val".Trim()
    } catch { return "" }
}

function Read-EnvValue {
    param([string]$File, [string]$Key)
    if (Test-Path $File) {
        $line = Get-Content $File | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
        if ($line) { return ($line -replace "^$Key=", "").Trim() }
    }
    return ""
}

function Set-AzdEnv {
    param([string]$Key, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = "" }
    azd env set "$Key" "$Value" 2>$null
}

function Prompt-Value {
    param(
        [string]$AzdKey,
        [string]$PromptText,
        [string]$Default = "",
        [switch]$Required
    )
    $current = Get-AzdEnv $AzdKey
    if ($current) { $Default = $current }
    if ($Default) {
        $value = Read-Host "$PromptText [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    } else {
        do {
            $value = Read-Host $PromptText
        } while ($Required -and [string]::IsNullOrWhiteSpace($value))
    }
    Set-AzdEnv $AzdKey $value
    return $value
}

function Prompt-YesNo {
    param(
        [string]$AzdKey,
        [string]$PromptText,
        [string]$Default = "n"
    )
    $current = Get-AzdEnv $AzdKey
    if ($current -eq "true") { $Default = "y" }
    elseif ($current -eq "false") { $Default = "n" }
    $value = Read-Host "$PromptText [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    $result = ($value -match "^[yY]")
    Set-AzdEnv $AzdKey $(if ($result) { "true" } else { "false" })
    return $result
}

# ─── Read defaults from env files ────────────────────────────────────────────────

$EnvLocal = Join-Path $RootDir "env\.env.local"
$DotEnv = Join-Path $RootDir ".env"

$DefaultAoaiEndpoint = Read-EnvValue -File $EnvLocal -Key "AZURE_OPENAI_ENDPOINT"
$DefaultAoaiDeployment = Read-EnvValue -File $EnvLocal -Key "AZURE_OPENAI_DEPLOYMENT"
$DefaultAoaiApiVersion = Read-EnvValue -File $EnvLocal -Key "AZURE_OPENAI_API_VERSION"
$DefaultBotId = Read-EnvValue -File $EnvLocal -Key "BOT_ID"
$DefaultBotTenantId = Read-EnvValue -File $EnvLocal -Key "TEAMS_APP_TENANT_ID"
$DefaultBotSecret = Read-EnvValue -File $DotEnv -Key "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET"

$AzureEnvName = Get-AzdEnv "AZURE_ENV_NAME"

# ─── Resource Name Prefix ────────────────────────────────────────────────────────

Write-Host "--- Resource Naming ---"
$NamePrefix = Prompt-Value -AzdKey "AZURE_NAME_PREFIX" -PromptText "Resource name prefix (used for all resources)" -Default "agents-starter"
$NamePrefix = $NamePrefix.TrimEnd('-')
Set-AzdEnv "AZURE_NAME_PREFIX" $NamePrefix

# ─── Bot App Registration ────────────────────────────────────────────────────────

Write-Host "--- Bot App Registration ---"

$BotClientId = Get-AzdEnv "BOT_CLIENT_ID"
$BotTenantId = Get-AzdEnv "BOT_TENANT_ID"
$BotClientSecret = Get-AzdEnv "BOT_CLIENT_SECRET"
$BotObjectId = Get-AzdEnv "BOT_OBJECT_ID"

if ([string]::IsNullOrWhiteSpace($BotClientId)) {
    Write-Host "Bot App Registration options:"
    Write-Host "  1) Create new Entra app registration (recommended)"
    Write-Host "  2) Use an existing app registration (provide credentials)"
    $botChoice = Read-Host "Choice [1]"
    if ([string]::IsNullOrWhiteSpace($botChoice)) { $botChoice = "1" }

    if ($botChoice -eq "1") {
        $AppDisplayName = "$NamePrefix-bot"
        Write-Host "  Creating Entra app registration '$AppDisplayName'..."
        $appJson = az ad app create `
            --display-name $AppDisplayName `
            --sign-in-audience AzureADMyOrg `
            --query "{appId:appId, id:id}" `
            -o json
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Failed to create app registration."
            exit 1
        }
        $app = $appJson | ConvertFrom-Json
        $BotClientId = $app.appId
        $BotObjectId = $app.id
        $BotTenantId = (az account show --query tenantId -o tsv)
        Write-Host "  App registration created: $BotClientId"

        Write-Host "  Generating client secret..."
        $credJson = az ad app credential reset `
            --id $BotClientId `
            --display-name "azd-deploy" `
            --years 2 `
            --query "{password:password}" `
            -o json
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Failed to generate client secret."
            exit 1
        }
        $cred = $credJson | ConvertFrom-Json
        $BotClientSecret = $cred.password
        Write-Host "  Client secret generated."
    } else {
        Write-Host "You need an Entra ID app registration for the bot."
        Write-Host "Create one at https://portal.azure.com > App registrations."
        do { $BotClientId = Read-Host "Bot App registration client ID (GUID)" } while ([string]::IsNullOrWhiteSpace($BotClientId))
        # Fetch object ID from the provided client ID
        $BotObjectId = az ad app show --id $BotClientId --query id -o tsv 2>$null
        if ([string]::IsNullOrWhiteSpace($BotObjectId)) {
            do { $BotObjectId = Read-Host "Bot App registration object ID (GUID)" } while ([string]::IsNullOrWhiteSpace($BotObjectId))
        }
        if ([string]::IsNullOrWhiteSpace($BotTenantId)) {
            do { $BotTenantId = Read-Host "Bot App registration tenant ID (GUID)" } while ([string]::IsNullOrWhiteSpace($BotTenantId))
        }
        if ([string]::IsNullOrWhiteSpace($BotClientSecret)) {
            do { $BotClientSecret = Read-Host "Bot App registration client secret" } while ([string]::IsNullOrWhiteSpace($BotClientSecret))
        }
    }
}

if ([string]::IsNullOrWhiteSpace($BotTenantId)) {
    $BotTenantId = (az account show --query tenantId -o tsv)
}

Set-AzdEnv "BOT_CLIENT_ID" $BotClientId
Set-AzdEnv "BOT_TENANT_ID" $BotTenantId
Set-AzdEnv "BOT_CLIENT_SECRET" $BotClientSecret

# Ensure BOT_OBJECT_ID is set (resolve from client ID if needed)
if ([string]::IsNullOrWhiteSpace($BotObjectId) -and -not [string]::IsNullOrWhiteSpace($BotClientId)) {
    $BotObjectId = az ad app show --id $BotClientId --query id -o tsv 2>$null
}
Set-AzdEnv "BOT_OBJECT_ID" $BotObjectId

# ─── Bot Service ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Azure Bot Service ---"
Prompt-Value -AzdKey "BOT_SERVICE_NAME" -PromptText "Azure Bot Service name" -Default "$NamePrefix-bot" | Out-Null

# ─── Azure OpenAI ────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Azure OpenAI ---"
$CreateAoai = Prompt-YesNo -AzdKey "CREATE_AZURE_OPENAI" -PromptText "Create a new Azure OpenAI resource? (y/n)" -Default "n"

if (-not $CreateAoai) {
    $aoaiDefault = if ($DefaultAoaiEndpoint) { $DefaultAoaiEndpoint } else { "" }
    $AoaiEndpoint = Prompt-Value -AzdKey "AZURE_OPENAI_ENDPOINT" -PromptText "Azure OpenAI endpoint URL" -Default $aoaiDefault -Required

    $DerivedAoaiName = ""
    if ($AoaiEndpoint -match "https://([^.]+)\.openai\.azure\.com") {
        $DerivedAoaiName = $Matches[1]
    }
    $AoaiResourceName = Prompt-Value -AzdKey "AZURE_OPENAI_RESOURCE_NAME" -PromptText "Azure OpenAI resource name" -Default $DerivedAoaiName -Required

    $AzureRg = Get-AzdEnv "AZURE_RESOURCE_GROUP"
    $AoaiResourceGroup = Prompt-Value -AzdKey "AZURE_OPENAI_RESOURCE_GROUP" -PromptText "Azure OpenAI resource group (for role assignment)" -Default $AzureRg

    if ($AoaiResourceGroup -ne $AzureRg) {
        Prompt-Value -AzdKey "AZURE_OPENAI_SUBSCRIPTION" -PromptText "Azure OpenAI subscription (ID or name, leave blank if same)" -Default "" | Out-Null
    } else {
        Set-AzdEnv "AZURE_OPENAI_SUBSCRIPTION" ""
    }
} else {
    Prompt-Value -AzdKey "AZURE_OPENAI_NAME" -PromptText "Azure OpenAI account name" -Default "$NamePrefix-openai" | Out-Null
    Set-AzdEnv "AZURE_OPENAI_ENDPOINT" ""
    Set-AzdEnv "AZURE_OPENAI_RESOURCE_NAME" ""
    Set-AzdEnv "AZURE_OPENAI_RESOURCE_GROUP" ""
    Set-AzdEnv "AZURE_OPENAI_SUBSCRIPTION" ""
}

$deployDefault = if ($DefaultAoaiDeployment) { $DefaultAoaiDeployment } else { "gpt-4o-mini" }
Prompt-Value -AzdKey "AZURE_OPENAI_DEPLOYMENT" -PromptText "Azure OpenAI deployment name" -Default $deployDefault | Out-Null

$apiDefault = if ($DefaultAoaiApiVersion) { $DefaultAoaiApiVersion } else { "2024-12-01-preview" }
Prompt-Value -AzdKey "AZURE_OPENAI_API_VERSION" -PromptText "Azure OpenAI API version" -Default $apiDefault | Out-Null

# Compute AOAI_SAME_RESOURCE_GROUP
$AzureRg = Get-AzdEnv "AZURE_RESOURCE_GROUP"
$AoaiRg = Get-AzdEnv "AZURE_OPENAI_RESOURCE_GROUP"
if ($CreateAoai -or -not $AoaiRg -or $AoaiRg -eq $AzureRg) {
    Set-AzdEnv "AOAI_SAME_RESOURCE_GROUP" "true"
} else {
    Set-AzdEnv "AOAI_SAME_RESOURCE_GROUP" "false"
}

# ─── Container Registry ─────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Container Registry ---"
Write-Host "Container Registry options:"
Write-Host "  1) Create new ACR"
Write-Host "  2) Use existing ACR"
Write-Host "  3) No ACR (ACA source deploy)"

$currentUseAcr = Get-AzdEnv "USE_ACR"
$currentCreateAcr = Get-AzdEnv "CREATE_ACR"
$acrDefault = "3"
if ($currentUseAcr -eq "true" -and $currentCreateAcr -eq "false") { $acrDefault = "2" }
elseif ($currentUseAcr -eq "true") { $acrDefault = "1" }

$acrChoice = Read-Host "Choice [$acrDefault]"
if ([string]::IsNullOrWhiteSpace($acrChoice)) { $acrChoice = $acrDefault }

switch ($acrChoice) {
    "1" {
        Set-AzdEnv "USE_ACR" "true"
        Set-AzdEnv "CREATE_ACR" "true"
        $DefaultAcrName = ($NamePrefix -replace "-", "") + "acr"
        Prompt-Value -AzdKey "ACR_NAME" -PromptText "ACR name (globally unique, alphanumeric)" -Default $DefaultAcrName | Out-Null
        Prompt-Value -AzdKey "ACR_SKU" -PromptText "ACR SKU (Basic/Standard/Premium)" -Default "Basic" | Out-Null
        Set-AzdEnv "ACR_RESOURCE_GROUP" ""
    }
    "2" {
        Set-AzdEnv "USE_ACR" "true"
        Set-AzdEnv "CREATE_ACR" "false"
        Prompt-Value -AzdKey "ACR_NAME" -PromptText "Existing ACR name" -Required | Out-Null
        $AzureRg = Get-AzdEnv "AZURE_RESOURCE_GROUP"
        Prompt-Value -AzdKey "ACR_RESOURCE_GROUP" -PromptText "ACR resource group" -Default $AzureRg | Out-Null
        Set-AzdEnv "ACR_SKU" "Basic"
        $acrName = Get-AzdEnv "ACR_NAME"
        Write-Host "  Using existing ACR: ${acrName}.azurecr.io"
    }
    default {
        Set-AzdEnv "USE_ACR" "false"
        Set-AzdEnv "CREATE_ACR" "false"
        Set-AzdEnv "ACR_NAME" ""
        Set-AzdEnv "ACR_SKU" "Basic"
        Set-AzdEnv "ACR_RESOURCE_GROUP" ""
        Write-Host "  No ACR — will use ACA source deploy."
    }
}

# ─── Container App ──────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Container App ---"
Prompt-Value -AzdKey "ACA_NAME" -PromptText "Container App name" -Default "$NamePrefix-app" | Out-Null

Write-Host "Container App size:"
Write-Host "  1) Small  - 0.25 CPU, 0.5 Gi (default)"
Write-Host "  2) Medium - 0.5 CPU, 1 Gi"
Write-Host "  3) Large  - 1 CPU, 2 Gi"
$sizeChoice = Read-Host "Choice [1]"
switch ($sizeChoice) {
    "2" { Set-AzdEnv "ACA_CPU_CORES" "0.5"; Set-AzdEnv "ACA_MEMORY_SIZE" "1Gi" }
    "Medium" { Set-AzdEnv "ACA_CPU_CORES" "0.5"; Set-AzdEnv "ACA_MEMORY_SIZE" "1Gi" }
    "3" { Set-AzdEnv "ACA_CPU_CORES" "1"; Set-AzdEnv "ACA_MEMORY_SIZE" "2Gi" }
    "Large" { Set-AzdEnv "ACA_CPU_CORES" "1"; Set-AzdEnv "ACA_MEMORY_SIZE" "2Gi" }
    default { Set-AzdEnv "ACA_CPU_CORES" "0.25"; Set-AzdEnv "ACA_MEMORY_SIZE" "0.5Gi" }
}

# ─── Log Analytics / ACA Environment ────────────────────────────────────────────

Write-Host ""
Write-Host "--- Log Analytics & ACA Environment ---"
$UseExistingLog = Prompt-YesNo -AzdKey "USE_EXISTING_LOG_ANALYTICS" -PromptText "Use an existing Log Analytics workspace? (y/n)" -Default "n"
Prompt-Value -AzdKey "LOG_ANALYTICS_NAME" -PromptText "Log Analytics workspace name" -Default "$NamePrefix-logs" | Out-Null

$LogCustomerId = ""
$LogSharedKey = ""

if ($UseExistingLog) {
    $AzureRg = Get-AzdEnv "AZURE_RESOURCE_GROUP"
    $LogResourceGroup = Prompt-Value -AzdKey "LOG_ANALYTICS_RESOURCE_GROUP" -PromptText "Log Analytics resource group" -Default $AzureRg
    if ($LogResourceGroup -ne $AzureRg) {
        $LogSubscription = Prompt-Value -AzdKey "LOG_ANALYTICS_SUBSCRIPTION" -PromptText "Log Analytics subscription (ID or name, leave blank if same)" -Default ""
        $subArg = if ($LogSubscription) { "--subscription $LogSubscription" } else { "" }
        $LogName = Get-AzdEnv "LOG_ANALYTICS_NAME"
        Write-Host "  Fetching workspace credentials from $LogResourceGroup..."
        $LogCustomerId = Invoke-Expression "az monitor log-analytics workspace show --workspace-name $LogName --resource-group $LogResourceGroup --query customerId -o tsv $subArg"
        $LogSharedKey = Invoke-Expression "az monitor log-analytics workspace get-shared-keys --workspace-name $LogName --resource-group $LogResourceGroup --query primarySharedKey -o tsv $subArg"
        Write-Host "  Log Analytics credentials fetched successfully."
    }
} else {
    Set-AzdEnv "LOG_ANALYTICS_RESOURCE_GROUP" ""
    Set-AzdEnv "LOG_ANALYTICS_SUBSCRIPTION" ""
}

Set-AzdEnv "EXISTING_LOG_CUSTOMER_ID" "$LogCustomerId"
Set-AzdEnv "EXISTING_LOG_SHARED_KEY" "$LogSharedKey"

Prompt-Value -AzdKey "ACA_ENVIRONMENT_NAME" -PromptText "Container App Environment name" -Default "$NamePrefix-env" | Out-Null

# Ensure AZURE_OPENAI_NAME has a value
$currentAoaiName = Get-AzdEnv "AZURE_OPENAI_NAME"
if (-not $currentAoaiName) {
    Set-AzdEnv "AZURE_OPENAI_NAME" "$NamePrefix-openai"
}

Write-Host ""
Write-Host "=== Configuration complete ==="
