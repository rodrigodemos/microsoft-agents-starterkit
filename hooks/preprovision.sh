#!/bin/bash
# preprovision.sh — Interactively prompts for configuration, sets defaults, and fetches cross-RG credentials
set -euo pipefail

echo "========================================"
echo " Microsoft Agents Starter Kit - Configure"
echo "========================================"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Helpers ─────────────────────────────────────────────────────────────────────

# Get azd env var (empty string if not set)
get_env() {
  azd env get-value "$1" 2>/dev/null || echo ""
}

# Read value from a dotenv file
read_env_file() {
  local file="$1" key="$2"
  if [[ -f "$file" ]]; then
    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | sed "s/^${key}=//" | xargs || echo ""
  else
    echo ""
  fi
}

# Prompt with default; if already set in azd env, use that as default
prompt() {
  local var_name="$1" prompt_text="$2" default="$3"
  local current
  current=$(get_env "$var_name")
  if [[ -n "$current" ]]; then
    default="$current"
  fi
  if [[ -n "$default" ]]; then
    read -rp "$prompt_text [$default]: " value
    value="${value:-$default}"
  else
    read -rp "$prompt_text: " value
  fi
  eval "$var_name=\"$value\""
  azd env set "$var_name" "$value"
}

# Prompt yes/no, returns "true" or "false"
prompt_yn() {
  local var_name="$1" prompt_text="$2" default="$3"
  local current
  current=$(get_env "$var_name")
  if [[ -n "$current" ]]; then
    if [[ "$current" == "true" ]]; then default="y"; else default="n"; fi
  fi
  read -rp "$prompt_text [$default]: " value
  value="${value:-$default}"
  if [[ "$value" =~ ^[yY] ]]; then
    eval "$var_name=true"
    azd env set "$var_name" "true"
  else
    eval "$var_name=false"
    azd env set "$var_name" "false"
  fi
}

# ─── Read defaults from env files ────────────────────────────────────────────────

ENV_LOCAL="$ROOT_DIR/env/.env.local"
DOT_ENV="$ROOT_DIR/.env"

DEFAULT_AOAI_ENDPOINT=$(read_env_file "$ENV_LOCAL" "AZURE_OPENAI_ENDPOINT")
DEFAULT_AOAI_DEPLOYMENT=$(read_env_file "$ENV_LOCAL" "AZURE_OPENAI_DEPLOYMENT")
DEFAULT_AOAI_API_VERSION=$(read_env_file "$ENV_LOCAL" "AZURE_OPENAI_API_VERSION")
DEFAULT_BOT_ID=$(read_env_file "$ENV_LOCAL" "BOT_ID")
DEFAULT_BOT_TENANT_ID=$(read_env_file "$ENV_LOCAL" "TEAMS_APP_TENANT_ID")
DEFAULT_BOT_SECRET=$(read_env_file "$DOT_ENV" "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET")

AZURE_ENV_NAME=$(get_env "AZURE_ENV_NAME")

# ─── Bot Registration ───────────────────────────────────────────────────────────

echo "--- Bot Registration ---"

BOT_CLIENT_ID=$(get_env "BOT_CLIENT_ID")
BOT_TENANT_ID=$(get_env "BOT_TENANT_ID")
BOT_CLIENT_SECRET=$(get_env "BOT_CLIENT_SECRET")

if [[ -z "$BOT_CLIENT_ID" && -n "$DEFAULT_BOT_ID" ]]; then
  echo "Found existing bot registration in env/.env.local:"
  echo "  BOT_ID:        $DEFAULT_BOT_ID"
  echo "  BOT_TENANT_ID: ${DEFAULT_BOT_TENANT_ID:-<not found>}"
  read -rp "Reuse this bot registration? (y/n) [y]: " reuse
  reuse="${reuse:-y}"
  if [[ "$reuse" =~ ^[yY] ]]; then
    BOT_CLIENT_ID="$DEFAULT_BOT_ID"
    BOT_TENANT_ID="${DEFAULT_BOT_TENANT_ID:-}"
    BOT_CLIENT_SECRET="${DEFAULT_BOT_SECRET:-}"
  fi
fi

if [[ -z "$BOT_CLIENT_ID" ]]; then
  echo "You need an Entra ID app registration for the bot."
  echo "Create one at https://portal.azure.com > App registrations."
  read -rp "Bot App registration client ID (GUID): " BOT_CLIENT_ID
  while [[ -z "$BOT_CLIENT_ID" ]]; do
    read -rp "Bot App registration client ID (GUID): " BOT_CLIENT_ID
  done
fi

if [[ -z "$BOT_TENANT_ID" ]]; then
  read -rp "Bot App registration tenant ID (GUID): " BOT_TENANT_ID
  while [[ -z "$BOT_TENANT_ID" ]]; do
    read -rp "Bot App registration tenant ID (GUID): " BOT_TENANT_ID
  done
fi

if [[ -z "$BOT_CLIENT_SECRET" ]]; then
  echo "  Client secret not found — run a local debug (F5) first, or copy from Azure Portal > App registrations > Certificates & secrets."
  read -rp "Bot App registration client secret: " BOT_CLIENT_SECRET
  while [[ -z "$BOT_CLIENT_SECRET" ]]; do
    read -rp "Bot App registration client secret: " BOT_CLIENT_SECRET
  done
fi

azd env set BOT_CLIENT_ID "$BOT_CLIENT_ID"
azd env set BOT_TENANT_ID "$BOT_TENANT_ID"
azd env set BOT_CLIENT_SECRET "$BOT_CLIENT_SECRET"

# ─── Azure OpenAI ────────────────────────────────────────────────────────────────

echo ""
echo "--- Azure OpenAI ---"
prompt_yn CREATE_AZURE_OPENAI "Create a new Azure OpenAI resource? (y/n)" "n"

AZURE_OPENAI_ENDPOINT=""
AZURE_OPENAI_RESOURCE_NAME=""
AZURE_OPENAI_RESOURCE_GROUP=""
AZURE_OPENAI_SUBSCRIPTION=""
AZURE_OPENAI_NAME=""

if [[ "$CREATE_AZURE_OPENAI" == "false" ]]; then
  aoai_default="${DEFAULT_AOAI_ENDPOINT:-}"
  current_ep=$(get_env "AZURE_OPENAI_ENDPOINT")
  if [[ -n "$current_ep" ]]; then aoai_default="$current_ep"; fi
  prompt AZURE_OPENAI_ENDPOINT "Azure OpenAI endpoint URL" "$aoai_default"

  # Derive resource name from endpoint
  DERIVED_NAME=$(echo "$AZURE_OPENAI_ENDPOINT" | sed -E 's|https://([^.]+)\.openai\.azure\.com/?|\1|')
  prompt AZURE_OPENAI_RESOURCE_NAME "Azure OpenAI resource name" "$DERIVED_NAME"

  AZURE_RG=$(get_env "AZURE_RESOURCE_GROUP")
  prompt AZURE_OPENAI_RESOURCE_GROUP "Azure OpenAI resource group (for role assignment)" "${AZURE_RG:-}"
  if [[ -n "$AZURE_OPENAI_RESOURCE_GROUP" && "$AZURE_OPENAI_RESOURCE_GROUP" != "$AZURE_RG" ]]; then
    prompt AZURE_OPENAI_SUBSCRIPTION "Azure OpenAI subscription (ID or name, leave blank if same)" ""
  else
    azd env set AZURE_OPENAI_SUBSCRIPTION ""
  fi
else
  prompt AZURE_OPENAI_NAME "Azure OpenAI account name" "${AZURE_ENV_NAME}-openai"
  azd env set AZURE_OPENAI_ENDPOINT ""
  azd env set AZURE_OPENAI_RESOURCE_NAME ""
  azd env set AZURE_OPENAI_RESOURCE_GROUP ""
  azd env set AZURE_OPENAI_SUBSCRIPTION ""
fi

deploy_default="${DEFAULT_AOAI_DEPLOYMENT:-gpt-4o-mini}"
prompt AZURE_OPENAI_DEPLOYMENT "Azure OpenAI deployment name" "$deploy_default"

api_default="${DEFAULT_AOAI_API_VERSION:-2024-12-01-preview}"
prompt AZURE_OPENAI_API_VERSION "Azure OpenAI API version" "$api_default"

# Compute AOAI_SAME_RESOURCE_GROUP
AZURE_RG=$(get_env "AZURE_RESOURCE_GROUP")
AOAI_RG=$(get_env "AZURE_OPENAI_RESOURCE_GROUP")
if [[ "$CREATE_AZURE_OPENAI" == "true" || -z "$AOAI_RG" || "$AOAI_RG" == "$AZURE_RG" ]]; then
  azd env set AOAI_SAME_RESOURCE_GROUP "true"
else
  azd env set AOAI_SAME_RESOURCE_GROUP "false"
fi

# ─── Container Registry ─────────────────────────────────────────────────────────

echo ""
echo "--- Container Registry ---"
echo "Container Registry options:"
echo "  1) Create new ACR"
echo "  2) Use existing ACR"
echo "  3) No ACR (ACA source deploy)"

current_use_acr=$(get_env "USE_ACR")
current_create_acr=$(get_env "CREATE_ACR")
if [[ "$current_use_acr" == "true" && "$current_create_acr" == "false" ]]; then
  acr_default="2"
elif [[ "$current_use_acr" == "true" ]]; then
  acr_default="1"
else
  acr_default="3"
fi

read -rp "Choice [$acr_default]: " ACR_CHOICE
ACR_CHOICE="${ACR_CHOICE:-$acr_default}"

case "$ACR_CHOICE" in
  1)
    azd env set USE_ACR "true"
    azd env set CREATE_ACR "true"
    DEFAULT_ACR_NAME=$(echo "${AZURE_ENV_NAME}acr" | tr -d '-')
    prompt ACR_NAME "ACR name (globally unique, alphanumeric)" "$DEFAULT_ACR_NAME"
    prompt ACR_SKU "ACR SKU (Basic/Standard/Premium)" "Basic"
    azd env set ACR_RESOURCE_GROUP ""
    ;;
  2)
    azd env set USE_ACR "true"
    azd env set CREATE_ACR "false"
    prompt ACR_NAME "Existing ACR name" ""
    AZURE_RG=$(get_env "AZURE_RESOURCE_GROUP")
    prompt ACR_RESOURCE_GROUP "ACR resource group" "${AZURE_RG:-}"
    azd env set ACR_SKU "Basic"
    echo "  Using existing ACR: ${ACR_NAME}.azurecr.io"
    ;;
  *)
    azd env set USE_ACR "false"
    azd env set CREATE_ACR "false"
    azd env set ACR_NAME ""
    azd env set ACR_SKU "Basic"
    azd env set ACR_RESOURCE_GROUP ""
    echo "  No ACR — will use ACA source deploy."
    ;;
esac

# ─── Container App ──────────────────────────────────────────────────────────────

echo ""
echo "--- Container App ---"
prompt ACA_NAME "Container App name" "${AZURE_ENV_NAME}-app"

echo "Container App size:"
echo "  1) Small  - 0.25 CPU, 0.5 Gi (default)"
echo "  2) Medium - 0.5 CPU, 1 Gi"
echo "  3) Large  - 1 CPU, 2 Gi"
read -rp "Choice [1]: " SIZE_CHOICE
SIZE_CHOICE="${SIZE_CHOICE:-1}"
case "$SIZE_CHOICE" in
  2|Medium) azd env set ACA_CPU_CORES "0.5"; azd env set ACA_MEMORY_SIZE "1Gi" ;;
  3|Large) azd env set ACA_CPU_CORES "1"; azd env set ACA_MEMORY_SIZE "2Gi" ;;
  *) azd env set ACA_CPU_CORES "0.25"; azd env set ACA_MEMORY_SIZE "0.5Gi" ;;
esac

# ─── Log Analytics / ACA Environment ────────────────────────────────────────────

echo ""
echo "--- Log Analytics & ACA Environment ---"
prompt_yn USE_EXISTING_LOG_ANALYTICS "Use an existing Log Analytics workspace? (y/n)" "n"
prompt LOG_ANALYTICS_NAME "Log Analytics workspace name" "${AZURE_ENV_NAME}-logs"

EXISTING_LOG_CUSTOMER_ID=""
EXISTING_LOG_SHARED_KEY=""

if [[ "$USE_EXISTING_LOG_ANALYTICS" == "true" ]]; then
  AZURE_RG=$(get_env "AZURE_RESOURCE_GROUP")
  prompt LOG_ANALYTICS_RESOURCE_GROUP "Log Analytics resource group" "${AZURE_RG:-}"
  LOG_RG=$(get_env "LOG_ANALYTICS_RESOURCE_GROUP")
  if [[ -n "$LOG_RG" && "$LOG_RG" != "$AZURE_RG" ]]; then
    prompt LOG_ANALYTICS_SUBSCRIPTION "Log Analytics subscription (ID or name, leave blank if same)" ""
    LOG_SUB=$(get_env "LOG_ANALYTICS_SUBSCRIPTION")
    LOG_NAME=$(get_env "LOG_ANALYTICS_NAME")
    SUB_ARG=""
    if [[ -n "$LOG_SUB" ]]; then SUB_ARG="--subscription $LOG_SUB"; fi
    echo "  Fetching workspace credentials from $LOG_RG..."
    EXISTING_LOG_CUSTOMER_ID=$(az monitor log-analytics workspace show \
      --workspace-name "$LOG_NAME" --resource-group "$LOG_RG" --query customerId -o tsv $SUB_ARG)
    EXISTING_LOG_SHARED_KEY=$(az monitor log-analytics workspace get-shared-keys \
      --workspace-name "$LOG_NAME" --resource-group "$LOG_RG" --query primarySharedKey -o tsv $SUB_ARG)
    echo "  Log Analytics credentials fetched successfully."
  fi
else
  azd env set LOG_ANALYTICS_RESOURCE_GROUP ""
  azd env set LOG_ANALYTICS_SUBSCRIPTION ""
fi

azd env set EXISTING_LOG_CUSTOMER_ID "${EXISTING_LOG_CUSTOMER_ID:-}"
azd env set EXISTING_LOG_SHARED_KEY "${EXISTING_LOG_SHARED_KEY:-}"

prompt ACA_ENVIRONMENT_NAME "Container App Environment name" "${AZURE_ENV_NAME}-env"

# ─── Set remaining defaults ─────────────────────────────────────────────────────

# Ensure AZURE_OPENAI_NAME has a value even when not creating
CURRENT_AOAI_NAME=$(get_env "AZURE_OPENAI_NAME")
if [[ -z "$CURRENT_AOAI_NAME" ]]; then
  azd env set AZURE_OPENAI_NAME "${AZURE_ENV_NAME}-openai"
fi

echo ""
echo "=== Configuration complete ==="

