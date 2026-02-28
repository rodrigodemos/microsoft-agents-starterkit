# Microsoft Agents Starter Kit

A ready-to-go multi-agent orchestrator built with the [Microsoft Agent Framework](https://github.com/microsoft/agent-framework) (Python) and hosted in **Microsoft Teams** via the **M365 Agents SDK**. Clone it, add your own agents, and deploy, everything is wired up.

## Architecture

```
User (Teams) ──► M365 Host Server (aiohttp) ──► Orchestrator Agent
       │              SSO / OBO                       │
       │         (user identity flows)                ├──► Comedian Agent (as tool)
       └──────────────────────────────────────────────└──► [Add your agents here...]
                                                            (tools execute OBO user)
```

The **Orchestrator** is the main agent that receives user messages. It has specialist sub-agents registered as **tools**, the LLM decides when to delegate based on user intent.

**Authentication**: All Azure services use **Entra ID** with chained credentials (Managed Identity → Azure CLI). No API keys. **SSO flows end-to-end**: user identity is passed from Teams → M365 → Orchestrator → Tools via On-Behalf-Of (OBO), so tools execute with delegated user access.

The kit ships with two agents to get you started:

| Agent | Description |
|-------|-------------|
| **Orchestrator** | Main agent that routes requests to specialists or answers directly |
| **Comedian** | Tells jokes and funny stories on any topic |

## Prerequisites

- **Python 3.11+**
- **[uv](https://pypi.org/project/uv/)** package manager: `pip install uv`
- **Azure subscription**
- **Microsoft Foundry** or **Azure OpenAI** with a deployed model (e.g., `gpt-4o-mini`)
- **Cognitive Services OpenAI User** role for your identity
- **Azure CLI** installed and authenticated: `az login`

You will also need the following depending on how you run the project:

| Tool | Local standalone | Teams debug | Deploy to Azure |
|------|:---:|:---:|:---:|
| **[Microsoft 365 Agents Toolkit](https://learn.microsoft.com/en-us/microsoftteams/platform/toolkit/overview-agents-toolkit)** (VS Code extension) | | x | x |
| **[Azure Developer CLI (`azd`)](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)** | | | x |
| **Docker** (if using ACR) | | | x |
| **Entra ID app registration** with a client secret | | | x |

## Getting Started

There are two ways to work with this project: **run locally** (with or without Teams) for development, or **deploy to Azure**.

### 1. Clone and install dependencies

```bash
git clone <this-repo-url>
cd microsoft-agents-starterkit
uv sync --prerelease=allow
```

`uv sync` automatically creates a `.venv` virtual environment and installs all dependencies from `pyproject.toml`. No manual venv activation needed, `uv run` (used below) always runs inside the managed venv.

### 2. Configure your environment

Copy the example environment file and fill in your Azure OpenAI settings:

```bash
cp env/.env.local.example env/.env.local
```

Then edit `env/.env.local` with your values:

```env
AZURE_OPENAI_ENDPOINT=https://<your-resource>.openai.azure.com/
AZURE_OPENAI_DEPLOYMENT=gpt-4o-mini
AZURE_OPENAI_API_VERSION=2024-12-01-preview
```

Authentication uses **chained credentials**: Managed Identity (in Azure) → Azure CLI (local dev). Make sure you have run `az login` for local development.

> **Note:** When debugging in Teams, the toolkit auto-generates a `.env` file in the project root from `m365agents.local.yml`. Do not edit `.env` directly, always update values in `env/.env.local` instead.

### 3. Run locally (without Teams)

The fastest way to try things out. The Agent Framework DevUI gives you a built-in web chat interface, no Teams account or Bot Framework setup needed:

```bash
uv run python test_standalone.py
```

This opens a browser at `http://localhost:8080` with a chat UI connected directly to the orchestrator agent (with the comedian tool). Just the agent framework and Azure OpenAI.

> **Note:** SSO/OBO is not available in standalone mode. For full end-to-end testing with user identity, use the Teams debug flow below.

### 4. Run locally in Teams

If you want to test the full Teams experience locally, all the Agents Toolkit files are already included (`m365agents.local.yml`, `m365agents.yml`, `appPackage/`, `.vscode/`, `env/`).

1. Install the **Microsoft 365 Agents Toolkit** extension in VS Code
2. Open the project folder in VS Code, the toolkit auto-detects `m365agents.local.yml` and shows the agent
3. In the Agents Toolkit panel, select **Local** environment → click **Debug** (or press F5)
4. On first debug, the toolkit **auto-provisions**:
   - An **Entra ID app registration** (BOT_ID)
   - A **Bot Framework registration** on dev.botframework.com with Teams channel
   - A **dev tunnel** to expose your local server to Teams
5. The deploy step auto-generates `.env` in the project root with all runtime variables (CLIENT_ID, TENANT_ID, Azure OpenAI, SSO/OBO settings). **Do not edit `.env` directly**, update values in `env/.env.local` instead.

## Deploy to Azure

### Deploy with `azd up` (recommended)

```bash
# Authenticate with Azure Developer CLI (one-time)
azd auth login

# Deploy, prompts for all configuration on first run
azd up
```

On first run, `azd up` prompts for:
1. **Environment name** (e.g., `dev`, `staging`, `prod`)
2. **Azure subscription** and **location**
3. **Bot credentials** (client ID, tenant ID, secret, auto-detects from `env/.env.local` if available)
4. **Azure OpenAI** create new or use existing (endpoint, resource group, subscription)
5. **Container Registry** create new, use existing, or none
6. **Container App** name and size
7. **Log Analytics** create new or use existing

All values are stored in `.azure/<env>/.env`. On subsequent runs, `azd up` reuses stored config and only updates changed resources, no prompts.

**Multiple environments:**
```bash
azd env new staging        # create a staging environment
azd up                     # prompts for config, deploys to separate resource group

azd env select dev         # switch back to dev
azd up                     # updates dev (no prompts)
```

**Pre-configure with `azd env set`** (optional, skips prompts for those values):
```bash
azd env set BOT_CLIENT_ID "your-client-id"
azd env set AZURE_OPENAI_ENDPOINT "https://my-openai.openai.azure.com/"
azd up
```

For a full list of environment variables and their defaults, see [ENVIRONMENT_VARIABLES.md](ENVIRONMENT_VARIABLES.md).

### Deploy with scripts (alternative)

The deployment scripts interactively prompt for all resource names, regions, and configuration:

**Bash:**
```bash
chmod +x infra/deploy.sh
./infra/deploy.sh
```

**PowerShell:**
```powershell
.\infra\deploy.ps1
```

The script will:
1. Create (or reuse) a resource group
2. Deploy infrastructure via Bicep: ACA environment, Container App, and optionally ACR and Azure OpenAI
3. Build and deploy the container image
4. Generate `env/.env.azure` with deployed resource values

### What gets deployed

| Resource | Purpose |
|----------|---------|
| Container App Environment | Hosting environment (Consumption tier) |
| Container App | Runs the agent (scale to zero, system-assigned MI) |
| Container Registry | Stores container images (optional) |
| Azure OpenAI | LLM provider (optional, can use existing) |
| Azure Bot Service | Bot Framework registration with Teams + M365 channels |
| Log Analytics | Monitoring and logs |
| Role Assignment | Cognitive Services OpenAI User for ACA managed identity |

### Publish Teams app

After infrastructure deployment, publish the Teams app using M365 Agents Toolkit:

1. Update `env/.env.azure` with the deployed ACA endpoint (auto-generated by the deploy script)
2. In VS Code, open the Agents Toolkit panel
3. Select **Azure** environment
4. Click **Provision** this creates the Teams app registration and bot framework registration
5. The toolkit publishes the app to your organization's app catalog

### Teams admin approval

1. Go to [Teams Admin Center](https://admin.teams.microsoft.com/) > **Teams apps** > **Manage apps**
2. Search for your app name (e.g., "AgentsStarterKit")
3. Click the app > **Publish** to approve it for your organization
4. Optionally, go to **Setup policies** to pin the app for specific users

### M365 Copilot availability

To make the agent available as a plugin in M365 Copilot:

1. The `manifest.json` already includes `copilotAgents` configuration with `declarativeAgents`
2. The Bot Service deployment includes the `M365Extensions` channel
3. After Teams admin approval, the agent appears as a Copilot plugin
4. Users can invoke it from M365 Copilot by mentioning the agent name

### CI/CD with GitHub Actions

The included workflow (`.github/workflows/deploy.yml`) auto-deploys on push to `main`:

1. **Configure GitHub secrets** (Settings > Secrets and variables > Actions):
   - `AZURE_CLIENT_ID`
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`

2. **Configure GitHub variables** (Settings > Secrets and variables > Actions > Variables):
   - `AZURE_RESOURCE_GROUP`
   - `ACR_LOGIN_SERVER` (e.g., `myacr.azurecr.io`)
   - `ACR_NAME`
   - `ACA_NAME` Container App name

3. Push to `main` triggers build and deploy. Adding a new agent just requires a push.

4. Manual deploys: use **Actions** > **Deploy to Azure** > **Run workflow**.

## How to Add a New Agent

Adding a new specialist agent is a **2-step process** locally, then push to deploy:

### Step 1: Create the agent file

Create a new file in `agents/`, e.g. `agents/weather.py`:

```python
from agent_framework.azure import AzureOpenAIChatClient


WEATHER_INSTRUCTIONS = """You are a weather information assistant.
Provide weather forecasts and current conditions for requested locations."""


def create_weather_agent(client: AzureOpenAIChatClient):
    return client.as_agent(
        name="Weather",
        description="An agent that provides weather information. Use when the user asks about weather.",
        instructions=WEATHER_INSTRUCTIONS,
    )
```

### Step 2: Register it in the orchestrator

Edit `agents/orchestrator.py`:

```python
# Add the import
from agents.weather import create_weather_agent

# In _create_agents(), add the agent and its tool:
weather = create_weather_agent(self.chat_client)

tools = [
    comedian.as_tool(),
    weather.as_tool(),   # Add this line
]
```

Update the orchestrator's system prompt to mention the new agent so the LLM knows when to use it.

### Step 3: Test locally

1. **DevUI** (quick iteration): `uv run python test_standalone.py` opens http://localhost:8080
2. **Teams** (full E2E): Press F5 in VS Code to debug in Teams

### Step 4: Deploy

Push to `main` GitHub Actions automatically rebuilds and redeploys the container.

Or redeploy manually:
```bash
# With azd
azd deploy

# Or with ACR directly
az acr build --registry <acr-name> --resource-group <rg> --image agent:latest .
az containerapp update --name <aca-name> --resource-group <rg> --image <acr>.azurecr.io/agent:latest
```

## Key Concepts

- **Agent-as-tool pattern**: Sub-agents are converted to function tools via `.as_tool()` and provided to the orchestrator. The LLM decides when to delegate.
- **Entra ID authentication**: All Azure services use `ChainedTokenCredential(ManagedIdentityCredential(), AzureCliCredential())`. No API keys anywhere.
- **SSO / On-Behalf-Of (OBO)**: User identity flows end-to-end: User → Teams → M365 → Orchestrator → Tools. MCP tools and external services execute with the user's delegated access via the `AGENTIC` auth handler and OBO token exchange.
- **Microsoft Agent Framework**: Provides `Agent`, `ChatAgent`, and `AzureOpenAIChatClient` for building AI agents with tool support, multi-turn conversations, and streaming.
- **M365 Agents SDK**: Provides `CloudAdapter`, `AgentApplication`, and `AgentNotification` for hosting agents in Teams, Outlook, and other M365 surfaces.
- **Agent 365 Observability**: Built-in tracing and telemetry via `AgentFrameworkInstrumentor`.

## Testing

- **Agents Playground**: Test locally without a Teams tenant using the [Agent 365 CLI](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/agent-365-cli)
- **Teams**: Deploy via the Agents Toolkit for end-to-end testing in Teams

## References

- [Microsoft Agent Framework](https://github.com/microsoft/agent-framework)
- [Agent Framework Documentation](https://learn.microsoft.com/en-us/agent-framework/)
- [Agent-as-tool Pattern](https://learn.microsoft.com/en-us/agent-framework/agents/tools/#using-an-agent-as-a-function-tool)
- [Agent 365 Quickstart (Python)](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/quickstart-python-agent-framework)
- [M365 Agents Toolkit](https://learn.microsoft.com/en-us/microsoftteams/platform/toolkit/overview-agents-toolkit)
