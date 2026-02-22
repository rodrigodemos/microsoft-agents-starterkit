# Microsoft Agents Starter Kit

A multi-agent orchestrator starter kit built with the [Microsoft Agent Framework](https://github.com/microsoft/agent-framework) (Python), hosted in **Microsoft Teams** via the **M365 Agents SDK**.

## Architecture

```
User (Teams) ──► M365 Host Server (aiohttp) ──► Orchestrator Agent
       │              SSO / OBO                       │
       │         (user identity flows)                ├──► Comedian Agent (as tool)
       └──────────────────────────────────────────────└──► [Add your agents here...]
                                                           (tools execute OBO user)
```

The **Orchestrator** is the main agent that receives user messages. It has specialist sub-agents registered as **tools** — the LLM decides when to delegate based on user intent.

**Authentication**: All Azure services use **Entra ID** with chained credentials (Managed Identity → Azure CLI). No API keys. **SSO flows end-to-end**: user identity is passed from Teams → M365 → Orchestrator → Tools via On-Behalf-Of (OBO), so tools execute with delegated user access.

Currently includes:

| Agent | Description |
|-------|-------------|
| **Orchestrator** | Main agent that routes requests to specialists or answers directly |
| **Comedian** | Tells jokes and funny stories on any topic |

## Prerequisites

- **Python 3.11+**
- **[uv](https://pypi.org/project/uv/)** package manager: `pip install uv`
- **Azure OpenAI** resource with a deployed model (e.g., `gpt-4o-mini`) — your identity must have the **Cognitive Services OpenAI User** role
- **Azure CLI** installed and authenticated: `az login`
- **Azure subscription** — needed for the Bot Framework registration (free, no cost)
- **[Microsoft 365 Agents Toolkit](https://learn.microsoft.com/en-us/microsoftteams/platform/toolkit/overview-agents-toolkit)** VS Code extension (for Teams deployment)

## Setup

### 1. Clone and install dependencies

```bash
git clone <this-repo-url>
cd microsoft-agents-starterkit
uv sync --prerelease=allow
```

`uv sync` automatically creates a `.venv` virtual environment and installs all dependencies from `pyproject.toml`. No manual venv activation needed — `uv run` (used below) always runs inside the managed venv.

### 2. Configure Azure OpenAI

Edit `env/.env.local` and fill in your Azure OpenAI settings:

```env
AZURE_OPENAI_ENDPOINT=https://<your-resource>.openai.azure.com/
AZURE_OPENAI_DEPLOYMENT=gpt-4o-mini
AZURE_OPENAI_API_VERSION=2024-12-01-preview
```

Authentication uses **chained credentials**: Managed Identity (in Azure) → Azure CLI (local dev). Ensure `az login` is done for local development.

> **Note:** The `.env.template` file is provided as a reference for all available environment variables. You do not need to copy it — the toolkit auto-generates `.env` at debug time.

### 3. Debug in Teams

All the Agents Toolkit files are already included in this starter kit (`m365agents.local.yml`, `m365agents.yml`, `appPackage/`, `.vscode/`, `env/`).

1. Install the **Microsoft 365 Agents Toolkit** extension in VS Code
2. Open the project folder in VS Code — the toolkit auto-detects `m365agents.local.yml` and shows the agent
3. In the Agents Toolkit panel, select **Local** environment → click **Debug** (or press F5)
4. On first debug, the toolkit **auto-provisions**:
   - An **Entra ID app registration** (BOT_ID)
   - A **Bot Framework registration** on dev.botframework.com with Teams channel
   - A **dev tunnel** to expose your local server to Teams
5. The deploy step auto-generates `.env` in the project root with all runtime variables (CLIENT_ID, TENANT_ID, Azure OpenAI, SSO/OBO settings). **Do not edit `.env` directly** — update values in `env/.env.local` instead.

### 4. Test with Agents Playground (offline)

Use the playground environment for offline testing without a Teams tenant:

1. In the Agents Toolkit panel, select **Playground** environment
2. Click **Debug** — this installs the test tool and starts your agent locally

### 5. Run standalone (without Teams)

```bash
uv run python start.py
```

The server starts on `http://localhost:3978/api/messages`. Useful for testing with REST clients.

## How to Add a New Agent

Adding a new specialist agent is a **2-step process**:

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
    weather.as_tool(),   # ← Add this line
]
```

Update the orchestrator's system prompt to mention the new agent so the LLM knows when to use it.

That's it! The orchestrator will now route weather-related questions to your new agent.

## Project Structure

```
microsoft-agents-starterkit/
├── pyproject.toml                      # Dependencies and project config
├── .env.template                       # Environment variable template
├── README.md                           # This file
├── start.py                            # Entry point
├── agent_interface.py                  # Abstract base class for hosted agents
├── host_agent_server.py                # M365-compatible aiohttp host server
├── local_authentication_options.py     # Local auth config helper
├── token_cache.py                      # Token caching for observability
├── agents/
│   ├── __init__.py                     # Exports OrchestratorAgent
│   ├── comedian.py                     # Comedian sub-agent
│   └── orchestrator.py                 # Orchestrator (main agent)
├── appPackage/
│   ├── manifest.json                   # Teams app manifest (variable placeholders)
│   ├── color.png                       # App icon (color, 192x192)
│   └── outline.png                     # App icon (outline, 32x32)
├── m365agents.yml                      # Agents Toolkit — project config
├── m365agents.local.yml                # Agents Toolkit — local debug workflow
├── m365agents.playground.yml           # Agents Toolkit — offline playground testing
├── env/
│   └── .env.local                      # Local debug env (auto-filled by toolkit)
└── .vscode/
    ├── launch.json                     # Debug configurations
    └── tasks.json                      # Build/provision tasks
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
