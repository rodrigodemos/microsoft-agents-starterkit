# Environment Variables Reference

These are the environment variables used when deploying to Azure with `azd up`. You can pre-configure them with `azd env set` to skip interactive prompts.

## Bot Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `BOT_CLIENT_ID` | Entra ID app client ID | _(required)_ |
| `BOT_TENANT_ID` | Entra ID app tenant ID | _(required)_ |
| `BOT_CLIENT_SECRET` | App registration client secret | _(required)_ |

## Azure OpenAI

| Variable | Description | Default |
|----------|-------------|---------|
| `CREATE_AZURE_OPENAI` | `true` to create new, `false` for existing | `false` |
| `AZURE_OPENAI_ENDPOINT` | Existing AOAI endpoint URL | |
| `AZURE_OPENAI_RESOURCE_GROUP` | Resource group of existing AOAI | deployment RG |
| `AZURE_OPENAI_SUBSCRIPTION` | Subscription of existing AOAI (if different) | current |
| `AZURE_OPENAI_DEPLOYMENT` | Model deployment name | `gpt-4o-mini` |
| `AZURE_OPENAI_API_VERSION` | API version | `2024-12-01-preview` |
| `AZURE_OPENAI_NAME` | AOAI account name (new only) | `{env}-openai` |

## Container Registry

| Variable | Description | Default |
|----------|-------------|---------|
| `USE_ACR` | `true` to use ACR, `false` for source deploy | `false` |
| `CREATE_ACR` | `true` to create new ACR, `false` for existing | `true` |
| `ACR_NAME` | ACR name | |
| `ACR_SKU` | SKU for new ACR | `Basic` |
| `ACR_RESOURCE_GROUP` | Resource group of existing ACR | deployment RG |

## Container App

| Variable | Description | Default |
|----------|-------------|---------|
| `ACA_NAME` | Container App name | `{env}-app` |
| `ACA_ENVIRONMENT_NAME` | ACA Environment name | `{env}-env` |
| `ACA_CPU_CORES` | CPU cores | `0.25` |
| `ACA_MEMORY_SIZE` | Memory | `0.5Gi` |

## Log Analytics

| Variable | Description | Default |
|----------|-------------|---------|
| `LOG_ANALYTICS_NAME` | Log Analytics workspace name | `{env}-logs` |
| `USE_EXISTING_LOG_ANALYTICS` | `true` to use existing workspace | `false` |
| `LOG_ANALYTICS_RESOURCE_GROUP` | Resource group of existing workspace | deployment RG |
| `LOG_ANALYTICS_SUBSCRIPTION` | Subscription of existing workspace | current |
