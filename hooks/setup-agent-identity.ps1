# setup-agent-identity.ps1 — Creates Agent Identity Blueprint + Agent Identity via Microsoft Graph API
#
# Prerequisites:
#   - Microsoft 365 Copilot license with Frontier enabled
#   - Agent ID Developer or Agent ID Administrator role
#   - Microsoft Graph PowerShell modules:
#       Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
#       Install-Module Microsoft.Graph.Beta.Applications -Scope CurrentUser
#       Install-Module Microsoft.Graph.Users -Scope CurrentUser
#
# This script is called by postprovision.ps1 after ACA is provisioned.
# It creates the Agent Identity Blueprint, configures credentials and scope,
# creates the Agent Identity, and sets up FIC with the ACA managed identity.
#
# NOTE: Agent ID APIs reject tokens containing Directory.AccessAsUser.All,
# so we use Connect-MgGraph with scoped permissions instead of az CLI tokens.

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$DisplayName,

    [Parameter(Mandatory = $false)]
    [string]$SponsorUserId = "",

    [Parameter(Mandatory = $false)]
    [string]$ManagedIdentityPrincipalId = "",

    [Parameter(Mandatory = $false)]
    [switch]$SkipIfExists
)

# ─── Helpers ─────────────────────────────────────────────────────────────────────

function Invoke-GraphApi {
    param(
        [string]$Method,
        [string]$Uri,
        [object]$Body = $null
    )
    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = @{ "OData-Version" = "4.0" }
    }
    if ($Body -and $Method -ne "GET" -and $Method -ne "DELETE") {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
        $params["ContentType"] = "application/json"
    }
    try {
        $response = Invoke-MgGraphRequest @params
        return $response
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody = $_.ErrorDetails.Message
        if (-not $errorBody) { $errorBody = $_.Exception.Message }
        Write-Host "  Graph API error ($statusCode): $errorBody"
        return $null
    }
}

# ─── Main ────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Agent Identity Setup ---"

# Connect to Microsoft Graph with Agent ID scopes
# NOTE: Run this script from a standalone PowerShell 7 window (not VS Code terminal)
#       WAM (Web Account Manager) authentication may not work in embedded terminals.
$requiredScopes = @(
    "AgentIdentityBlueprint.Create",
    "AgentIdentityBlueprint.AddRemoveCreds.All",
    "AgentIdentityBlueprint.ReadWrite.All",
    "AgentIdentityBlueprintPrincipal.Create",
    "User.Read"
)

$existingContext = Get-MgContext -ErrorAction SilentlyContinue
if ($existingContext -and $existingContext.TenantId -eq $TenantId) {
    Write-Host "  Using existing Microsoft Graph connection (tenant: $TenantId)."
} else {
    Write-Host "  Connecting to Microsoft Graph with Agent ID scopes..."
    try {
        Connect-MgGraph -Scopes $requiredScopes -TenantId $TenantId -NoWelcome -ErrorAction Stop
    } catch {
        Write-Host "ERROR: Failed to connect to Microsoft Graph."
        Write-Host ""
        Write-Host "  If running from VS Code terminal, try a standalone PowerShell 7 window instead:"
        Write-Host "    cd $PWD"
        Write-Host "    Connect-MgGraph -Scopes 'AgentIdentityBlueprint.Create','AgentIdentityBlueprint.AddRemoveCreds.All','AgentIdentityBlueprint.ReadWrite.All','AgentIdentityBlueprintPrincipal.Create','User.Read' -TenantId '$TenantId'"
        Write-Host "    .\hooks\setup-agent-identity.ps1 -TenantId '$TenantId' -DisplayName '$DisplayName'"
        Write-Host ""
        Write-Host "  Prerequisite: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
        Write-Host "  Error: $($_.Exception.Message)"
        exit 1
    }
}

Write-Host "  Connected to Microsoft Graph."

# Resolve sponsor — use current user if not provided
if ([string]::IsNullOrWhiteSpace($SponsorUserId)) {
    Write-Host "  Resolving current user as sponsor..."
    $me = Invoke-GraphApi -Method GET -Uri "https://graph.microsoft.com/v1.0/me?`$select=id,displayName"
    if ($me) {
        $SponsorUserId = $me.id
        Write-Host "  Sponsor: $($me.displayName) ($SponsorUserId)"
    } else {
        Write-Host "ERROR: Could not resolve current user for sponsor. Provide -SponsorUserId."
        exit 1
    }
}

# ─── Step 1: Create Agent Identity Blueprint ─────────────────────────────────────

Write-Host "  Creating Agent Identity Blueprint '$DisplayName'..."

$blueprintBody = @{
    "@odata.type"       = "Microsoft.Graph.AgentIdentityBlueprint"
    displayName         = $DisplayName
    "sponsors@odata.bind" = @(
        "https://graph.microsoft.com/v1.0/users/$SponsorUserId"
    )
    "owners@odata.bind" = @(
        "https://graph.microsoft.com/v1.0/users/$SponsorUserId"
    )
}

$blueprint = Invoke-GraphApi -Method POST -Uri "https://graph.microsoft.com/beta/applications/" -Body $blueprintBody

if (-not $blueprint) {
    Write-Host "ERROR: Failed to create Agent Identity Blueprint."
    exit 1
}

$BlueprintObjectId = $blueprint.id
$BlueprintAppId = $blueprint.appId
Write-Host "  Blueprint created: appId=$BlueprintAppId, objectId=$BlueprintObjectId"

# ─── Step 2: Add client secret (transition credential until SDK supports MI-as-FIC) ──

Write-Host "  Adding client secret to blueprint (transition credential)..."

$secretBody = @{
    passwordCredential = @{
        displayName = "azd-deploy-agent-identity"
        endDateTime = (Get-Date).AddYears(1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
}

$secretResult = Invoke-GraphApi -Method POST -Uri "https://graph.microsoft.com/beta/applications/$BlueprintObjectId/addPassword" -Body $secretBody

if (-not $secretResult) {
    Write-Host "WARNING: Failed to add client secret. You may need to add one manually."
    $BlueprintSecret = ""
} else {
    $BlueprintSecret = $secretResult.secretText
    Write-Host "  Client secret added (store securely, cannot be retrieved later)."
}

# ─── Step 3: Configure identifier URI and scope ─────────────────────────────────

Write-Host "  Configuring identifier URI and scope..."

$scopeId = [guid]::NewGuid().ToString()

$scopeBody = @{
    identifierUris = @("api://$BlueprintAppId")
    api = @{
        oauth2PermissionScopes = @(
            @{
                adminConsentDescription = "Allow the application to access the agent on behalf of the signed-in user."
                adminConsentDisplayName = "Access agent"
                id                      = $scopeId
                isEnabled               = $true
                type                    = "User"
                userConsentDescription  = "Allow the agent to act on your behalf."
                userConsentDisplayName  = "Access agent on your behalf"
                value                   = "access_agent"
            }
        )
    }
}

Invoke-GraphApi -Method PATCH -Uri "https://graph.microsoft.com/beta/applications/$BlueprintObjectId" -Body $scopeBody | Out-Null
Write-Host "  Identifier URI and scope configured."

# ─── Step 4: Pre-authorize Teams/M365 client apps ───────────────────────────────

Write-Host "  Pre-authorizing Teams and M365 client apps..."

# Build pre-auth JSON manually to avoid serialization issues with Invoke-MgGraphRequest
$preAuthApps = @(
    "1fec8e78-bce4-4aaf-ab1b-5451cc387264",  # Teams Web
    "5e3ce6c0-2b1f-4285-8d4b-75ee78787346",  # Teams Mobile
    "d3590ed6-52b3-4102-aeff-aad2292ab01c",  # Office Desktop
    "bc59ab01-8403-45c6-8796-ac3ef710b3e3",  # Office Web
    "0ec893e0-5785-4de6-99da-4ed124e5296c",  # Outlook Desktop
    "4765445b-32c6-49b0-83e6-1d93765276ca",  # Office Mobile
    "27922004-5251-4030-b22d-91ecd9a37ea4",  # Outlook Mobile
    "00000002-0000-0ff1-ce00-000000000000",  # SharePoint
    "4345a7b9-9a63-4910-a426-35363201d503"   # M365 Apps
)

$preAuthEntries = ($preAuthApps | ForEach-Object {
    "{`"appId`":`"$_`",`"permissionIds`":[`"$scopeId`"]}"
}) -join ","

$preAuthJson = "{`"api`":{`"preAuthorizedApplications`":[$preAuthEntries]}}"

try {
    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/beta/applications/$BlueprintObjectId" `
        -Body $preAuthJson `
        -ContentType "application/json" `
        -Headers @{ "OData-Version" = "4.0" }
    Write-Host "  Pre-authorized $($preAuthApps.Count) client apps."
} catch {
    Write-Host "  WARNING: Failed to pre-authorize client apps. You can do this manually in the Entra portal."
}

# ─── Step 5: Create Blueprint Principal (service principal) ──────────────────────

Write-Host "  Creating Blueprint Principal..."

$spBody = @{
    appId = $BlueprintAppId
}

$sp = Invoke-GraphApi -Method POST -Uri "https://graph.microsoft.com/beta/serviceprincipals/graph.agentIdentityBlueprintPrincipal" -Body $spBody

if (-not $sp) {
    Write-Host "WARNING: Failed to create Blueprint Principal. It may already exist."
} else {
    Write-Host "  Blueprint Principal created: id=$($sp.id)"
}

# ─── Step 6: Create Agent Identity (authenticated as the blueprint) ──────────────

Write-Host "  Creating Agent Identity..."

if ([string]::IsNullOrWhiteSpace($BlueprintSecret)) {
    Write-Host "ERROR: Blueprint client secret is required to create Agent Identity."
    Write-Host "  The Agent Identity must be created by the blueprint itself, not by a user."
    exit 1
}

# Wait for Entra to propagate the secret and service principal
Write-Host "  Waiting for Entra propagation (30 seconds)..."
Start-Sleep -Seconds 30

# Get a token as the blueprint (client_credentials flow)
Write-Host "  Acquiring token as blueprint ($BlueprintAppId)..."
$tokenBody = "client_id=$BlueprintAppId&scope=https://graph.microsoft.com/.default&client_secret=$([uri]::EscapeDataString($BlueprintSecret))&grant_type=client_credentials"
try {
    $tokenResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $tokenBody
    $blueprintToken = $tokenResponse.access_token
    Write-Host "  Blueprint token acquired."
} catch {
    Write-Host "ERROR: Failed to get token as blueprint: $($_.Exception.Message)"
    exit 1
}

# Create Agent Identity using the blueprint's token
$agentBody = @{
    displayName                = "$DisplayName - Agent"
    agentIdentityBlueprintId   = $BlueprintAppId
    "sponsors@odata.bind"      = @(
        "https://graph.microsoft.com/v1.0/users/$SponsorUserId"
    )
} | ConvertTo-Json -Depth 5

try {
    $agentIdentity = Invoke-RestMethod -Method POST `
        -Uri "https://graph.microsoft.com/beta/serviceprincipals/Microsoft.Graph.AgentIdentity" `
        -Headers @{
            "Authorization" = "Bearer $blueprintToken"
            "Content-Type"  = "application/json"
            "OData-Version" = "4.0"
        } `
        -Body $agentBody
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errorBody = $_.ErrorDetails.Message
    if (-not $errorBody) { $errorBody = $_.Exception.Message }
    Write-Host "  Graph API error ($statusCode): $errorBody"
    $agentIdentity = $null
}

if (-not $agentIdentity) {
    Write-Host "ERROR: Failed to create Agent Identity."
    exit 1
}

$AgentIdentityId = $agentIdentity.appId
$AgentIdentityObjectId = $agentIdentity.id
Write-Host "  Agent Identity created: appId=$AgentIdentityId, objectId=$AgentIdentityObjectId"

# ─── Step 7: Configure FIC with managed identity (if provided) ───────────────────

if (-not [string]::IsNullOrWhiteSpace($ManagedIdentityPrincipalId)) {
    Write-Host "  Configuring Federated Identity Credential with managed identity..."

    $ficBody = @{
        name      = "aca-managed-identity"
        issuer    = "https://login.microsoftonline.com/$TenantId/v2.0"
        subject   = $ManagedIdentityPrincipalId
        audiences = @("api://AzureADTokenExchange")
    }

    $ficResult = Invoke-GraphApi -Method POST -Uri "https://graph.microsoft.com/beta/applications/$BlueprintObjectId/federatedIdentityCredentials" -Body $ficBody

    if (-not $ficResult) {
        Write-Host "WARNING: Failed to configure FIC. You may need to configure it manually."
    } else {
        Write-Host "  FIC configured: managed identity $ManagedIdentityPrincipalId linked to blueprint."
    }
}

# ─── Step 8: Grant delegated permissions (User.Read on Graph) ────────────────────

Write-Host "  Configuring required resource access (Microsoft Graph - User.Read)..."

$permBody = @{
    requiredResourceAccess = @(
        @{
            resourceAppId  = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
            resourceAccess = @(
                @{ id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"; type = "Scope" }  # User.Read
                @{ id = "37f7f235-527c-4136-accd-4a02d197296e"; type = "Scope" }  # openid
                @{ id = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"; type = "Scope" }  # offline_access
                @{ id = "14dad69e-099b-42c9-810b-d002981feec1"; type = "Scope" }  # profile
                @{ id = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0"; type = "Scope" }  # email
            )
        }
    )
}

Invoke-GraphApi -Method PATCH -Uri "https://graph.microsoft.com/beta/applications/$BlueprintObjectId" -Body $permBody | Out-Null
Write-Host "  Delegated permissions configured."

# ─── Output ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Agent Identity Setup Complete ==="
Write-Host "  Blueprint App ID:        $BlueprintAppId"
Write-Host "  Blueprint Object ID:     $BlueprintObjectId"
Write-Host "  Blueprint Scope ID:      $scopeId"
Write-Host "  Agent Identity App ID:   $AgentIdentityId"
Write-Host "  Agent Identity Object ID: $AgentIdentityObjectId"

# Return values for caller to capture
$result = @{
    BlueprintAppId          = $BlueprintAppId
    BlueprintObjectId       = $BlueprintObjectId
    BlueprintScopeId        = $scopeId
    BlueprintSecret         = $BlueprintSecret
    AgentIdentityAppId      = $AgentIdentityId
    AgentIdentityObjectId   = $AgentIdentityObjectId
}

# Disconnect from Microsoft Graph
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

return $result
