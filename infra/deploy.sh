#!/usr/bin/env bash
set -euo pipefail

# ─── Microsoft Agents Starter Kit — Azure Deployment ────────────────────────────
# Interactive script that deploys infrastructure via Bicep and optionally builds
# and pushes a container image.
# ─────────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DEPLOYMENT_NAME="agents-starterkit"

echo "========================================"
echo " Microsoft Agents Starter Kit — Deploy"
echo "========================================"
echo ""

# ─── Read defaults from env/.env.local ───────────────────────────────────────────

read_env_value() {
  local file="$1" key="$2"
  if [[ -f "$file" ]]; then
    grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r'
  fi
}

ENV_LOCAL="$ROOT_DIR/env/.env.local"
DOT_ENV="$ROOT_DIR/.env"

DEFAULT_AOAI_ENDPOINT=$(read_env_value "$ENV_LOCAL" "AZURE_OPENAI_ENDPOINT")
DEFAULT_AOAI_DEPLOYMENT=$(read_env_value "$ENV_LOCAL" "AZURE_OPENAI_DEPLOYMENT")
DEFAULT_AOAI_API_VERSION=$(read_env_value "$ENV_LOCAL" "AZURE_OPENAI_API_VERSION")
DEFAULT_BOT_ID=$(read_env_value "$ENV_LOCAL" "BOT_ID")
DEFAULT_BOT_TENANT_ID=$(read_env_value "$ENV_LOCAL" "TEAMS_APP_TENANT_ID")
# Client secret is in .env (decrypted by toolkit)
DEFAULT_BOT_SECRET=$(read_env_value "$DOT_ENV" "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET")

# ─── Prompt Helpers ──────────────────────────────────────────────────────────────

prompt() {
  local var_name="$1" prompt_text="$2" default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    read -rp "$prompt_text [$default]: " value
    value="${value:-$default}"
  else
    while [[ -z "${value:-}" ]]; do
      read -rp "$prompt_text: " value
    done
  fi
  eval "$var_name='$value'"
}

prompt_yn() {
  local var_name="$1" prompt_text="$2" default="$3"
  local value
  read -rp "$prompt_text [$default]: " value
  value="${value:-$default}"
  if [[ "${value,,}" == "y" || "${value,,}" == "yes" ]]; then
    eval "$var_name=true"
  else
    eval "$var_name=false"
  fi
}

prompt_choice() {
  local var_name="$1" prompt_text="$2" default="$3"
  shift 3
  local options=("$@")
  echo "$prompt_text"
  for i in "${!options[@]}"; do
    local marker=""
    if [[ "${options[$i]}" == "$default" ]]; then marker=" (default)"; fi
    echo "  $((i+1))) ${options[$i]}${marker}"
  done
  local value
  read -rp "Choice [${default}]: " value
  value="${value:-$default}"
  # If numeric, map to option
  if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= ${#options[@]} )); then
    value="${options[$((value-1))]}"
  fi
  eval "$var_name='$value'"
}

# ─── Gather Configuration ───────────────────────────────────────────────────────

echo "--- Resource Group ---"
prompt RESOURCE_GROUP "Resource group name" "rg-agents-starterkit"
prompt LOCATION "Azure region" "eastus2"

echo ""
echo "--- Naming ---"
prompt NAME_PREFIX "Resource name prefix (used for all resources)" "agents-starter"
NAME_PREFIX="${NAME_PREFIX%-}"

# ─── Log Analytics / ACA Environment ────────────────────────────────────────────

echo ""
echo "--- Log Analytics & ACA Environment ---"
prompt_yn USE_EXISTING_LOG "Use an existing Log Analytics workspace? (y/n)" "n"
prompt LOG_ANALYTICS_NAME "Log Analytics workspace name" "${NAME_PREFIX}-logs"
LOG_CUSTOMER_ID=""
LOG_SHARED_KEY=""
if [[ "$USE_EXISTING_LOG" == "true" ]]; then
  prompt LOG_RESOURCE_GROUP "Log Analytics resource group" "$RESOURCE_GROUP"
  if [[ "$LOG_RESOURCE_GROUP" != "$RESOURCE_GROUP" ]]; then
    prompt LOG_SUBSCRIPTION "Log Analytics subscription (ID or name, leave blank if same)" ""
    SUB_ARG=""
    if [[ -n "$LOG_SUBSCRIPTION" ]]; then
      SUB_ARG="--subscription $LOG_SUBSCRIPTION"
    fi
    echo "  Fetching workspace credentials from $LOG_RESOURCE_GROUP..."
    LOG_CUSTOMER_ID=$(az monitor log-analytics workspace show --workspace-name "$LOG_ANALYTICS_NAME" --resource-group "$LOG_RESOURCE_GROUP" --query customerId -o tsv $SUB_ARG)
    LOG_SHARED_KEY=$(az monitor log-analytics workspace get-shared-keys --workspace-name "$LOG_ANALYTICS_NAME" --resource-group "$LOG_RESOURCE_GROUP" --query primarySharedKey -o tsv $SUB_ARG)
  fi
fi
prompt ACA_ENV_NAME "Container App Environment name" "${NAME_PREFIX}-env"

# ─── Bot Registration ───────────────────────────────────────────────────────────

echo ""
echo "--- Bot Registration ---"

if [[ -n "${DEFAULT_BOT_ID:-}" ]]; then
  echo "Found existing bot registration in env/.env.local:"
  echo "  BOT_ID:        $DEFAULT_BOT_ID"
  echo "  BOT_TENANT_ID: ${DEFAULT_BOT_TENANT_ID:-<not found>}"
  prompt_yn REUSE_BOT "Reuse this bot registration? (y/n)" "y"
else
  REUSE_BOT=false
fi

if [[ "$REUSE_BOT" == "true" ]]; then
  BOT_CLIENT_ID="$DEFAULT_BOT_ID"
  BOT_TENANT_ID="${DEFAULT_BOT_TENANT_ID:-}"
  if [[ -z "$BOT_TENANT_ID" ]]; then
    prompt BOT_TENANT_ID "Bot App registration tenant ID (GUID)" ""
  fi
  if [[ -n "${DEFAULT_BOT_SECRET:-}" ]]; then
    echo "  Client secret found in .env"
    prompt_yn USE_EXISTING_SECRET "Use existing client secret? (y/n)" "y"
    if [[ "$USE_EXISTING_SECRET" == "true" ]]; then
      BOT_CLIENT_SECRET="$DEFAULT_BOT_SECRET"
    else
      prompt BOT_CLIENT_SECRET "Bot App registration client secret" ""
    fi
  else
    echo "  Client secret not found in .env — run a local debug (F5) first, or copy it from Azure Portal > App registrations > Certificates & secrets."
    prompt BOT_CLIENT_SECRET "Bot App registration client secret" ""
  fi
else
  echo "You need an Entra ID app registration for the bot."
  echo "Create one at https://portal.azure.com > App registrations."
  prompt BOT_CLIENT_ID "Bot App registration client ID (GUID)" ""
  prompt BOT_TENANT_ID "Bot App registration tenant ID (GUID)" ""
  prompt BOT_CLIENT_SECRET "Bot App registration client secret" ""
fi

# ─── Azure OpenAI ────────────────────────────────────────────────────────────────

echo ""
echo "--- Azure OpenAI ---"
prompt_yn CREATE_AOAI "Create a new Azure OpenAI resource? (y/n)" "n"

AOAI_ENDPOINT=""
AOAI_RESOURCE_NAME=""
AOAI_NEW_NAME=""

if [[ "$CREATE_AOAI" == "false" ]]; then
  prompt AOAI_ENDPOINT "Azure OpenAI endpoint URL" "${DEFAULT_AOAI_ENDPOINT:-}"

  # Derive resource name from endpoint (e.g., https://my-openai.openai.azure.com/ → my-openai)
  DERIVED_AOAI_NAME=$(echo "$AOAI_ENDPOINT" | sed -E 's|https://([^.]+)\.openai\.azure\.com/?|\1|')
  prompt AOAI_RESOURCE_NAME "Azure OpenAI resource name" "$DERIVED_AOAI_NAME"

  prompt AOAI_RESOURCE_GROUP "Azure OpenAI resource group (for role assignment)" "$RESOURCE_GROUP"
  AOAI_SUBSCRIPTION=""
  if [[ "$AOAI_RESOURCE_GROUP" != "$RESOURCE_GROUP" ]]; then
    prompt AOAI_SUBSCRIPTION "Azure OpenAI subscription (ID or name, leave blank if same)" ""
  fi
else
  AOAI_RESOURCE_GROUP="$RESOURCE_GROUP"
  prompt AOAI_NEW_NAME "Azure OpenAI account name" "${NAME_PREFIX}-openai"
fi

# Determine if AOAI is in the same RG (for Bicep role assignment)
if [[ "$CREATE_AOAI" == "true" || "$AOAI_RESOURCE_GROUP" == "$RESOURCE_GROUP" ]]; then
  AOAI_SAME_RG="true"
else
  AOAI_SAME_RG="false"
fi

prompt AOAI_DEPLOYMENT "Azure OpenAI deployment name" "${DEFAULT_AOAI_DEPLOYMENT:-gpt-4o-mini}"
prompt AOAI_API_VERSION "Azure OpenAI API version" "${DEFAULT_AOAI_API_VERSION:-2024-12-01-preview}"

# ─── Container Registry ─────────────────────────────────────────────────────────

echo ""
echo "--- Container Registry ---"
echo "Container Registry options:"
echo "  1) Create new ACR"
echo "  2) Use existing ACR"
echo "  3) No ACR (ACA source deploy)"
read -rp "Choice [1]: " ACR_CHOICE
ACR_CHOICE="${ACR_CHOICE:-1}"

USE_ACR="false"
CREATE_ACR="false"
ACR_NAME=""
ACR_SKU="Basic"
ACR_LOGIN_SERVER=""
ACR_RESOURCE_GROUP=""

case "$ACR_CHOICE" in
  1)
    USE_ACR="true"
    CREATE_ACR="true"
    DEFAULT_ACR_NAME=$(echo "${NAME_PREFIX}acr" | tr -d '-')
    prompt ACR_NAME "ACR name (globally unique, alphanumeric)" "$DEFAULT_ACR_NAME"
    prompt_choice ACR_SKU "ACR SKU:" "Basic" "Basic" "Standard" "Premium"
    ;;
  2)
    USE_ACR="true"
    CREATE_ACR="false"
    prompt ACR_NAME "Existing ACR name" ""
    prompt ACR_RESOURCE_GROUP "ACR resource group" "$RESOURCE_GROUP"
    ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
    echo "  Using existing ACR: $ACR_LOGIN_SERVER"
    ;;
  *)
    echo "  No ACR - will use ACA source deploy."
    ;;
esac

# ─── Container App ──────────────────────────────────────────────────────────────

echo ""
echo "--- Container App ---"
prompt ACA_NAME "Container App name" "${NAME_PREFIX}-app"

echo "Container App size:"
echo "  1) Small  — 0.25 CPU, 0.5 Gi (default)"
echo "  2) Medium — 0.5 CPU, 1 Gi"
echo "  3) Large  — 1 CPU, 2 Gi"
read -rp "Choice [1]: " ACA_SIZE_CHOICE
ACA_SIZE_CHOICE="${ACA_SIZE_CHOICE:-1}"

case "$ACA_SIZE_CHOICE" in
  2|Medium|medium)  ACA_CPU="0.5";  ACA_MEMORY="1Gi" ;;
  3|Large|large)    ACA_CPU="1";    ACA_MEMORY="2Gi" ;;
  *)                ACA_CPU="0.25"; ACA_MEMORY="0.5Gi" ;;
esac

# ─── Pre-deployment Summary ─────────────────────────────────────────────────────

echo ""
echo "========================================"
echo " Deployment Summary"
echo "========================================"
echo ""
echo "  Resource Group:     $RESOURCE_GROUP ($LOCATION)"
echo "  Name Prefix:        $NAME_PREFIX"
echo ""
echo "  Bot Client ID:      $BOT_CLIENT_ID"
echo "  Bot Tenant ID:      $BOT_TENANT_ID"
echo ""
if [[ "$CREATE_AOAI" == "true" ]]; then
  echo "  Azure OpenAI:       Create new ($AOAI_NEW_NAME)"
else
  echo "  Azure OpenAI:       Use existing ($AOAI_RESOURCE_NAME)"
  echo "  AOAI Endpoint:      $AOAI_ENDPOINT"
  echo "  AOAI Resource Group: $AOAI_RESOURCE_GROUP"
fi
echo "  AOAI Deployment:    $AOAI_DEPLOYMENT"
echo "  AOAI API Version:   $AOAI_API_VERSION"
echo ""
if [[ "$USE_ACR" == "true" ]]; then
  if [[ "$CREATE_ACR" == "true" ]]; then
    echo "  Container Registry: Create new $ACR_NAME ($ACR_SKU)"
  else
    echo "  Container Registry: Use existing $ACR_NAME ($ACR_LOGIN_SERVER)"
  fi
else
  echo "  Container Registry: None (ACA source deploy)"
fi
echo "  Container App:      $ACA_NAME (${ACA_CPU} CPU, ${ACA_MEMORY})"
echo "  ACA Environment:   $ACA_ENV_NAME"
if [[ "$USE_EXISTING_LOG" == "true" ]]; then
  echo "  Log Analytics:     $LOG_ANALYTICS_NAME (existing)"
else
  echo "  Log Analytics:     $LOG_ANALYTICS_NAME (new)"
fi
echo ""

prompt_yn PROCEED "Proceed with deployment? (y/n)" "y"
if [[ "$PROCEED" != "true" ]]; then
  echo "Deployment cancelled."
  exit 0
fi

# ─── Create Resource Group ──────────────────────────────────────────────────────

if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  echo ""
  echo "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
else
  echo ""
  echo "Using existing resource group '$RESOURCE_GROUP'."
fi

# ─── What-If Preview ────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo " Running what-if preview..."
echo "========================================"

CONTAINER_IMAGE="mcr.microsoft.com/azurelinux/base/core:3.0"

az deployment group what-if \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --template-file "$SCRIPT_DIR/main.bicep" \
  --parameters \
    namePrefix="$NAME_PREFIX" \
    location="$LOCATION" \
    botClientId="$BOT_CLIENT_ID" \
    botTenantId="$BOT_TENANT_ID" \
    botClientSecret="$BOT_CLIENT_SECRET" \
    createAzureOpenAi="$CREATE_AOAI" \
    existingAzureOpenAiEndpoint="$AOAI_ENDPOINT" \
    existingAzureOpenAiName="$AOAI_RESOURCE_NAME" \
    azureOpenAiName="$AOAI_NEW_NAME" \
    azureOpenAiDeployment="$AOAI_DEPLOYMENT" \
    azureOpenAiApiVersion="$AOAI_API_VERSION" \
    useAcr="$CREATE_ACR" \
    acrName="$ACR_NAME" \
    acrSku="$ACR_SKU" \
    acaName="$ACA_NAME" \
    acaCpuCores="$ACA_CPU" \
    acaMemorySize="$ACA_MEMORY" \
    logAnalyticsName="$LOG_ANALYTICS_NAME" \
    useExistingLogAnalytics="$USE_EXISTING_LOG" \
    existingLogCustomerId="$LOG_CUSTOMER_ID" \
    existingLogSharedKey="$LOG_SHARED_KEY" \
    acaEnvironmentName="$ACA_ENV_NAME" \
    aoaiSameResourceGroup="$AOAI_SAME_RG" \
    containerImage="$CONTAINER_IMAGE" \
  2>&1 || true

echo ""
prompt_yn DEPLOY_NOW "Deploy now? (y/n)" "y"
if [[ "$DEPLOY_NOW" != "true" ]]; then
  echo "Deployment cancelled."
  exit 0
fi

# ─── Deploy Infrastructure ──────────────────────────────────────────────────────

echo ""
echo "========================================"
echo " Deploying infrastructure via Bicep..."
echo "========================================"

# Build and show the deployment tracking URL
SUB_ID=$(az account show --query id -o tsv)
RAW_ID="/subscriptions/$SUB_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Resources/deployments/$DEPLOYMENT_NAME"
ENCODED_ID=$(echo "$RAW_ID" | sed 's|/|%2F|g')
echo ""
echo "Track deployment in Azure Portal:"
echo "  https://portal.azure.com/#view/HubsExtension/DeploymentDetailsBlade/~/overview/id/$ENCODED_ID"
echo ""

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --template-file "$SCRIPT_DIR/main.bicep" \
  --parameters \
    namePrefix="$NAME_PREFIX" \
    location="$LOCATION" \
    botClientId="$BOT_CLIENT_ID" \
    botTenantId="$BOT_TENANT_ID" \
    botClientSecret="$BOT_CLIENT_SECRET" \
    createAzureOpenAi="$CREATE_AOAI" \
    existingAzureOpenAiEndpoint="$AOAI_ENDPOINT" \
    existingAzureOpenAiName="$AOAI_RESOURCE_NAME" \
    azureOpenAiName="$AOAI_NEW_NAME" \
    azureOpenAiDeployment="$AOAI_DEPLOYMENT" \
    azureOpenAiApiVersion="$AOAI_API_VERSION" \
    useAcr="$CREATE_ACR" \
    acrName="$ACR_NAME" \
    acrSku="$ACR_SKU" \
    acaName="$ACA_NAME" \
    acaCpuCores="$ACA_CPU" \
    acaMemorySize="$ACA_MEMORY" \
    logAnalyticsName="$LOG_ANALYTICS_NAME" \
    useExistingLogAnalytics="$USE_EXISTING_LOG" \
    existingLogCustomerId="$LOG_CUSTOMER_ID" \
    existingLogSharedKey="$LOG_SHARED_KEY" \
    acaEnvironmentName="$ACA_ENV_NAME" \
    aoaiSameResourceGroup="$AOAI_SAME_RG" \
    containerImage="$CONTAINER_IMAGE"

if [[ $? -ne 0 ]]; then
  echo ""
  echo "ERROR: Infrastructure deployment failed. Check the Azure Portal for details:"
  echo "  https://portal.azure.com/#view/HubsExtension/DeploymentDetailsBlade/~/overview/id/$ENCODED_ID"
  exit 1
fi

echo "Infrastructure deployment complete."

# Read outputs
ACA_FQDN=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.acaFqdn.value" -o tsv)
MESSAGING_ENDPOINT=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.messagingEndpoint.value" -o tsv)
DEPLOYED_AOAI_ENDPOINT=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.azureOpenAiEndpoint.value" -o tsv)

if [[ "$CREATE_ACR" == "true" ]]; then
  ACR_LOGIN_SERVER=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.acrLoginServer.value" -o tsv)
fi

# ─── Handle cross-RG role assignment ─────────────────────────────────────────────

if [[ "$CREATE_AOAI" == "false" && "$AOAI_RESOURCE_GROUP" != "$RESOURCE_GROUP" ]]; then
  echo ""
  echo "Azure OpenAI is in a different resource group ($AOAI_RESOURCE_GROUP)."
  echo "Assigning Cognitive Services OpenAI User role to ACA managed identity..."
  ACA_PRINCIPAL_ID=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.acaPrincipalId.value" -o tsv 2>/dev/null || echo "")
  if [[ -n "$ACA_PRINCIPAL_ID" ]]; then
    AOAI_SUB_ARG=""
    if [[ -n "$AOAI_SUBSCRIPTION" ]]; then
      AOAI_SUB_ARG="--subscription $AOAI_SUBSCRIPTION"
    fi
    AOAI_FULL_ID=$(az cognitiveservices account show --name "$AOAI_RESOURCE_NAME" --resource-group "$AOAI_RESOURCE_GROUP" --query id -o tsv $AOAI_SUB_ARG)
    az role assignment create \
      --role "Cognitive Services OpenAI User" \
      --assignee-object-id "$ACA_PRINCIPAL_ID" \
      --assignee-principal-type ServicePrincipal \
      --scope "$AOAI_FULL_ID" \
      --output none
    echo "Role assignment complete."
  else
    echo "Warning: Could not get ACA principal ID. Assign the role manually."
  fi
fi

# ─── Build and Deploy Container ─────────────────────────────────────────────────

echo ""
echo "========================================"
echo " Building and deploying container..."
echo "========================================"

if [[ "$USE_ACR" == "true" ]]; then
  BUILD_RG="$RESOURCE_GROUP"
  if [[ "$CREATE_ACR" == "false" && -n "$ACR_RESOURCE_GROUP" ]]; then
    BUILD_RG="$ACR_RESOURCE_GROUP"
  fi
  echo "Building image with ACR..."
  az acr build \
    --registry "$ACR_NAME" \
    --resource-group "$BUILD_RG" \
    --image "agent:latest" \
    "$ROOT_DIR"

  echo "Updating Container App with new image..."
  az containerapp update \
    --name "$ACA_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --image "${ACR_LOGIN_SERVER}/agent:latest" \
    --output none
else
  echo "Deploying via ACA source deploy..."
  az containerapp up \
    --name "$ACA_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --source "$ROOT_DIR" \
    --output none
fi

# ─── Generate env/.env.azure ────────────────────────────────────────────────────

ENV_FILE="$ROOT_DIR/env/.env.azure"
cat > "$ENV_FILE" <<EOF
# Auto-generated by deploy.sh — Azure deployment configuration
BOT_ID=$BOT_CLIENT_ID
BOT_TENANT_ID=$BOT_TENANT_ID
BOT_ENDPOINT=https://$ACA_FQDN
BOT_DOMAIN=$ACA_FQDN
AZURE_OPENAI_ENDPOINT=$DEPLOYED_AOAI_ENDPOINT
AZURE_OPENAI_DEPLOYMENT=$AOAI_DEPLOYMENT
AZURE_OPENAI_API_VERSION=$AOAI_API_VERSION
RESOURCE_GROUP=$RESOURCE_GROUP
ACA_NAME=$ACA_NAME
APP_NAME_SUFFIX=
EOF

if [[ "$USE_ACR" == "true" ]]; then
  echo "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER" >> "$ENV_FILE"
  echo "ACR_NAME=$ACR_NAME" >> "$ENV_FILE"
fi

# ─── Summary ────────────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo " Deployment Complete"
echo "========================================"
echo ""
echo "  ACA Endpoint:       https://$ACA_FQDN"
echo "  Messaging Endpoint: $MESSAGING_ENDPOINT"
echo "  Health Check:       https://$ACA_FQDN/api/health"
echo "  AOAI Endpoint:      $DEPLOYED_AOAI_ENDPOINT"
echo "  Env file:           $ENV_FILE"
echo ""
echo "Next steps:"
echo "  1. Publish Teams app: use M365 Agents Toolkit with m365agents.azure.yml"
echo "  2. Teams admin approval: see README.md for details"
echo ""
