# postprovision.ps1 — Handles cross-RG AOAI role assignment and generates env/.env.azure

Write-Host "=== Postprovision: configuring resources ==="

# ─── Ensure Service Principal exists for Bot App Registration ─────────────────

$BotAppId = Get-AzdEnv "BOT_CLIENT_ID"
if (-not [string]::IsNullOrWhiteSpace($BotAppId)) {
    Write-Host "  Ensuring service principal exists for bot app ($BotAppId)..."
    $existingSp = az ad sp show --id $BotAppId 2>$null
    if ($LASTEXITCODE -ne 0) {
        az ad sp create --id $BotAppId --output none
        Write-Host "  Service principal created."
    } else {
        Write-Host "  Service principal already exists."
    }
}

# Ensure Entra manifest build directory exists (needed by Toolkit aadApp/update)
$ScriptDir0 = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir0 = Split-Path -Parent $ScriptDir0
$EntraBuildDir = Join-Path $RootDir0 "infra\entra\build"
if (-not (Test-Path $EntraBuildDir)) {
    New-Item -ItemType Directory -Path $EntraBuildDir -Force | Out-Null
}

# Helper: get azd env var (robust version)
function Get-AzdEnv {
    param([string]$Key)
    try {
        $val = azd env get-value $Key 2>$null
        if ($LASTEXITCODE -ne 0) { return "" }
        if ($null -eq $val) { return "" }
        return "$val".Trim()
    } catch { return "" }
}

function Set-AzdEnv {
    param([string]$Key, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = "" }
    azd env set "$Key" "$Value" 2>$null
}

# ─── Cross-RG Azure OpenAI Role Assignment ───────────────────────────────────────

$CreateAoai = Get-AzdEnv "CREATE_AZURE_OPENAI"
$AoaiSameRg = Get-AzdEnv "AOAI_SAME_RESOURCE_GROUP"

if ($CreateAoai -ne "true" -and $AoaiSameRg -ne "true") {
    $AoaiResourceName = Get-AzdEnv "AZURE_OPENAI_RESOURCE_NAME"
    $AoaiRg = Get-AzdEnv "AZURE_OPENAI_RESOURCE_GROUP"
    $AoaiSub = Get-AzdEnv "AZURE_OPENAI_SUBSCRIPTION"
    $AcaPrincipalId = Get-AzdEnv "acaPrincipalId"

    # Fallback to other possible output names
    if ([string]::IsNullOrWhiteSpace($AcaPrincipalId)) {
        $AcaPrincipalId = Get-AzdEnv "SERVICE_AGENT_PRINCIPAL_ID"
    }
    if ([string]::IsNullOrWhiteSpace($AcaPrincipalId)) {
        $AcaPrincipalId = Get-AzdEnv "ACA_PRINCIPAL_ID"
    }

    if (-not [string]::IsNullOrWhiteSpace($AcaPrincipalId) -and $AoaiResourceName -and $AoaiRg) {
        Write-Host "  Azure OpenAI is in a different resource group ($AoaiRg)."
        Write-Host "  Assigning Cognitive Services OpenAI User role to ACA managed identity..."

        $subArg = if ($AoaiSub) { "--subscription $AoaiSub" } else { "" }

        try {
            $AoaiFullId = Invoke-Expression "az cognitiveservices account show --name $AoaiResourceName --resource-group $AoaiRg --query id -o tsv $subArg"
            az role assignment create `
                --role "Cognitive Services OpenAI User" `
                --assignee-object-id $AcaPrincipalId `
                --assignee-principal-type ServicePrincipal `
                --scope $AoaiFullId `
                --output none
            Write-Host "  Role assignment complete."
        } catch {
            Write-Host "  Warning: Could not assign role. Assign Cognitive Services OpenAI User role manually."
        }
    } else {
        Write-Host "  Warning: Could not assign cross-RG AOAI role. Assign manually if needed."
    }
}

# ─── ACR Role Assignment (AcrPull for ACA managed identity) ──────────────────────

$UseAcr = Get-AzdEnv "USE_ACR"
$AcrName = Get-AzdEnv "ACR_NAME"

if ($UseAcr -eq "true" -and $AcrName) {
    $AcaPrincipalId = Get-AzdEnv "acaPrincipalId"
    if ([string]::IsNullOrWhiteSpace($AcaPrincipalId)) {
        $AcaPrincipalId = Get-AzdEnv "SERVICE_AGENT_PRINCIPAL_ID"
    }

    if (-not [string]::IsNullOrWhiteSpace($AcaPrincipalId)) {
        $CreateAcr = Get-AzdEnv "CREATE_ACR"
        $AcrRg = if ($CreateAcr -eq "true") { Get-AzdEnv "AZURE_RESOURCE_GROUP" } else { Get-AzdEnv "ACR_RESOURCE_GROUP" }
        if ([string]::IsNullOrWhiteSpace($AcrRg)) { $AcrRg = Get-AzdEnv "AZURE_RESOURCE_GROUP" }

        Write-Host "  Assigning AcrPull role to ACA managed identity on ACR ($AcrName)..."
        try {
            $AcrId = az acr show --name $AcrName --resource-group $AcrRg --query id -o tsv 2>$null
            if ($AcrId) {
                az role assignment create `
                    --role "AcrPull" `
                    --assignee-object-id $AcaPrincipalId `
                    --assignee-principal-type ServicePrincipal `
                    --scope $AcrId `
                    --output none 2>$null
                Write-Host "  AcrPull role assignment complete."
            }
        } catch {
            Write-Host "  Warning: Could not assign AcrPull role. Assign manually if needed."
        }
    }
}

# ─── Generate env/.env.azure ─────────────────────────────────────────────────────

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$EnvFile = Join-Path $RootDir "env\.env.azure"

$BotClientId = Get-AzdEnv "BOT_CLIENT_ID"
$BotTenantId = Get-AzdEnv "BOT_TENANT_ID"
$BotObjectId = Get-AzdEnv "BOT_OBJECT_ID"
$AcaFqdn = Get-AzdEnv "acaFqdn"
$AoaiEndpoint = Get-AzdEnv "AZURE_OPENAI_ENDPOINT"
if ([string]::IsNullOrWhiteSpace($AoaiEndpoint)) { $AoaiEndpoint = Get-AzdEnv "azureOpenAiEndpoint" }
$AoaiDeployment = Get-AzdEnv "AZURE_OPENAI_DEPLOYMENT"
$AoaiApiVersion = Get-AzdEnv "AZURE_OPENAI_API_VERSION"
$ResourceGroup = Get-AzdEnv "AZURE_RESOURCE_GROUP"
$AcaName = Get-AzdEnv "ACA_NAME"
if ([string]::IsNullOrWhiteSpace($AcaName)) { $AcaName = Get-AzdEnv "acaName" }
$AcrName = Get-AzdEnv "ACR_NAME"
$UseAcr = Get-AzdEnv "USE_ACR"

# Set AZURE_CONTAINER_REGISTRY_ENDPOINT for azd deploy
if ($UseAcr -eq "true" -and $AcrName) {
    $AcrLoginServer = Get-AzdEnv "acrLoginServer"
    if ([string]::IsNullOrWhiteSpace($AcrLoginServer)) {
        $AcrLoginServer = "${AcrName}.azurecr.io"
    }
    Set-AzdEnv "AZURE_CONTAINER_REGISTRY_ENDPOINT" $AcrLoginServer
} else {
    $AcrLoginServer = ""
}

$envContent = @"
# Auto-generated by azd postprovision hook
BOT_ID=$BotClientId
BOT_OBJECT_ID=$BotObjectId
BOT_TENANT_ID=$BotTenantId
TEAMS_APP_TENANT_ID=$BotTenantId
BOT_ENDPOINT=https://$AcaFqdn
BOT_DOMAIN=$AcaFqdn
AZURE_OPENAI_ENDPOINT=$AoaiEndpoint
AZURE_OPENAI_DEPLOYMENT=$AoaiDeployment
AZURE_OPENAI_API_VERSION=$AoaiApiVersion
RESOURCE_GROUP=$ResourceGroup
ACA_NAME=$AcaName
"@

if ($AcrLoginServer) {
    $envContent += "`nACR_LOGIN_SERVER=$AcrLoginServer"
    $envContent += "`nACR_NAME=$AcrName"
}

# Preserve Toolkit-managed env vars (written by M365 Agents Toolkit provision)
$toolkitKeys = @(
    "APP_NAME_SUFFIX",
    "TEAMS_APP_ID",
    "TEAMSFX_ENV",
    "AAD_APP_ACCESS_AS_USER_PERMISSION_ID",
    "TEAMS_APP_TENANT_ID",
    "M365_TITLE_ID",
    "M365_APP_ID"
)
if (Test-Path $EnvFile) {
    $existingLines = Get-Content $EnvFile
    foreach ($key in $toolkitKeys) {
        $line = $existingLines | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
        if ($line) {
            $envContent += "`n$line"
        }
    }
}

Set-Content -Path $EnvFile -Value $envContent -Encoding UTF8
Write-Host "  Generated $EnvFile"

Write-Host "=== Postprovision: complete ==="
