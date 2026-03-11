# postprovision.ps1 — Handles cross-RG AOAI role assignment and generates env/.env.azure

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

function Set-AzdEnv {
    param([string]$Key, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = "" }
    azd env set "$Key" "$Value" 2>$null
}

# ─── Main ────────────────────────────────────────────────────────────────────────

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

        # Configure ACR registry on the Container App with managed identity
        $AcaName = Get-AzdEnv "ACA_NAME"
        if ([string]::IsNullOrWhiteSpace($AcaName)) { $AcaName = Get-AzdEnv "acaName" }
        $AcaRg = Get-AzdEnv "AZURE_RESOURCE_GROUP"
        $AcrLoginServer = "${AcrName}.azurecr.io"

        if ($AcaName -and $AcaRg) {
            Write-Host "  Configuring ACR registry on Container App ($AcaName)..."
            try {
                az containerapp registry set `
                    --name $AcaName `
                    --resource-group $AcaRg `
                    --server $AcrLoginServer `
                    --identity system `
                    --output none 2>$null
                Write-Host "  ACR registry configured."
            } catch {
                Write-Host "  Warning: Could not configure ACR registry on Container App."
            }
        }
    }
}

# ─── Agent Identity Setup ────────────────────────────────────────────────────────

$SetupAgentIdentity = Get-AzdEnv "SETUP_AGENT_IDENTITY"
$ExistingBlueprintId = Get-AzdEnv "AGENT_BLUEPRINT_CLIENT_ID"

if ($SetupAgentIdentity -eq "true" -and [string]::IsNullOrWhiteSpace($ExistingBlueprintId)) {
    $ScriptDir1 = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SetupScript = Join-Path $ScriptDir1 "setup-agent-identity.ps1"
    $BotTenantId1 = Get-AzdEnv "BOT_TENANT_ID"
    $NamePrefix1 = Get-AzdEnv "AZURE_NAME_PREFIX"
    $AcaPrincipalId1 = Get-AzdEnv "acaPrincipalId"
    if ([string]::IsNullOrWhiteSpace($AcaPrincipalId1)) {
        $AcaPrincipalId1 = Get-AzdEnv "SERVICE_AGENT_PRINCIPAL_ID"
    }

    if (Test-Path $SetupScript) {
        Write-Host "  Running Agent Identity setup..."
        $agentResult = & $SetupScript `
            -TenantId $BotTenantId1 `
            -DisplayName "$NamePrefix1-agent" `
            -ManagedIdentityPrincipalId $AcaPrincipalId1

        if ($agentResult -and $agentResult.BlueprintAppId) {
            Set-AzdEnv "AGENT_BLUEPRINT_CLIENT_ID" $agentResult.BlueprintAppId
            Set-AzdEnv "AGENT_BLUEPRINT_OBJECT_ID" $agentResult.BlueprintObjectId
            Set-AzdEnv "AGENT_BLUEPRINT_SCOPE_ID" $agentResult.BlueprintScopeId
            Set-AzdEnv "AGENT_IDENTITY_CLIENT_ID" $agentResult.AgentIdentityAppId
            Set-AzdEnv "AGENT_IDENTITY_OBJECT_ID" $agentResult.AgentIdentityObjectId
            if (-not [string]::IsNullOrWhiteSpace($agentResult.BlueprintSecret)) {
                Set-AzdEnv "AGENT_BLUEPRINT_CLIENT_SECRET" $agentResult.BlueprintSecret
            }
            Write-Host "  Agent Identity setup complete."

            # Update Container App with Agent Identity env vars
            $AcaName1 = Get-AzdEnv "ACA_NAME"
            if ([string]::IsNullOrWhiteSpace($AcaName1)) { $AcaName1 = Get-AzdEnv "acaName" }
            $AcaRg1 = Get-AzdEnv "AZURE_RESOURCE_GROUP"

            if ($AcaName1 -and $AcaRg1) {
                Write-Host "  Updating Container App with Agent Identity environment variables..."
                az containerapp update `
                    --name $AcaName1 `
                    --resource-group $AcaRg1 `
                    --set-env-vars `
                        "AGENT_BLUEPRINT_CLIENT_ID=$($agentResult.BlueprintAppId)" `
                        "AGENT_IDENTITY_CLIENT_ID=$($agentResult.AgentIdentityAppId)" `
                        "AUTH_HANDLER_NAME=AGENTIC" `
                        "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__TYPE=AgenticUserAuthorization" `
                        "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__SCOPES=https://graph.microsoft.com/.default" `
                        "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__ALTERNATEBLUEPRINTCONNECTIONNAME=BLUEPRINT_CONNECTION" `
                        "CONNECTIONS__BLUEPRINT_CONNECTION__SETTINGS__CLIENTID=$($agentResult.BlueprintAppId)" `
                        "CONNECTIONS__BLUEPRINT_CONNECTION__SETTINGS__TENANTID=$BotTenantId1" `
                        "CONNECTIONS__BLUEPRINT_CONNECTION__SETTINGS__AUTHTYPE=ClientSecret" `
                    --output none 2>$null

                # Set the blueprint secret separately (as a secret ref)
                if (-not [string]::IsNullOrWhiteSpace($agentResult.BlueprintSecret)) {
                    az containerapp secret set `
                        --name $AcaName1 `
                        --resource-group $AcaRg1 `
                        --secrets "blueprint-client-secret=$($agentResult.BlueprintSecret)" `
                        --output none 2>$null

                    az containerapp update `
                        --name $AcaName1 `
                        --resource-group $AcaRg1 `
                        --set-env-vars `
                            "CONNECTIONS__BLUEPRINT_CONNECTION__SETTINGS__CLIENTSECRET=secretref:blueprint-client-secret" `
                        --output none 2>$null
                }

                Write-Host "  Container App updated with Agent Identity configuration."
            }
        } else {
            Write-Host "WARNING: Agent Identity setup did not return expected results."
        }
    } else {
        Write-Host "WARNING: setup-agent-identity.ps1 not found at $SetupScript"
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
$AgentBlueprintClientId = Get-AzdEnv "AGENT_BLUEPRINT_CLIENT_ID"
$AgentIdentityClientId = Get-AzdEnv "AGENT_IDENTITY_CLIENT_ID"

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

if (-not [string]::IsNullOrWhiteSpace($AgentBlueprintClientId)) {
    $envContent += "`nAGENT_BLUEPRINT_CLIENT_ID=$AgentBlueprintClientId"
}
if (-not [string]::IsNullOrWhiteSpace($AgentIdentityClientId)) {
    $envContent += "`nAGENT_IDENTITY_CLIENT_ID=$AgentIdentityClientId"
}

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
