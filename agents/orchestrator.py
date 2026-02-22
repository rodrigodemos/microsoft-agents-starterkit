# Copyright (c) Microsoft. All rights reserved.

"""
Orchestrator agent — the main agent that receives user messages and delegates
to specialist sub-agents registered as tools.

To add a new sub-agent:
  1. Create a new file in agents/ with a create_*_agent(client) factory function
  2. Import it below and call .as_tool() to register it
  3. Add the tool to the TOOLS list
"""

import logging
import os
from typing import Optional

from dotenv import load_dotenv

from agent_framework import Agent
from agent_framework.azure import AzureOpenAIChatClient
from azure.identity import ChainedTokenCredential, ManagedIdentityCredential, AzureCliCredential

from agent_interface import AgentInterface
from agents.comedian import create_comedian_agent
from microsoft_agents.hosting.core import Authorization, TurnContext
from microsoft_agents_a365.observability.extensions.agentframework.trace_instrumentor import (
    AgentFrameworkInstrumentor,
)

load_dotenv()
logger = logging.getLogger(__name__)

ORCHESTRATOR_INSTRUCTIONS = """You are a helpful AI assistant that orchestrates specialist agents.

You have access to the following specialist agents as tools:
- **Comedian**: Tell jokes and funny stories. Use this when the user asks for humor, jokes, or entertainment.

ROUTING RULES:
- If the user asks for a joke, something funny, or humor → delegate to the Comedian tool.
- For general questions, answer directly using your own knowledge.
- You can combine your own response with a specialist's output when appropriate.
- Always be helpful, friendly, and professional.

IMPORTANT: When delegating to a specialist, pass the user's full request as the input."""


class OrchestratorAgent(AgentInterface):
    """Orchestrator agent that delegates to specialist sub-agents."""

    def __init__(self):
        self.logger = logging.getLogger(self.__class__.__name__)

        self._enable_instrumentation()
        self._create_client()
        self._create_agents()
        self._initialize_services()
        self.mcp_servers_initialized = False

    def _enable_instrumentation(self):
        try:
            AgentFrameworkInstrumentor().instrument()
            logger.info("✅ Instrumentation enabled")
        except Exception as e:
            logger.warning(f"⚠️ Instrumentation failed: {e}")

    def _create_client(self):
        """Create the shared Azure OpenAI chat client using Entra ID (MI → CLI chain)."""
        endpoint = os.getenv("AZURE_OPENAI_ENDPOINT")
        deployment = os.getenv("AZURE_OPENAI_DEPLOYMENT")
        api_version = os.getenv("AZURE_OPENAI_API_VERSION")

        if not endpoint:
            raise ValueError("AZURE_OPENAI_ENDPOINT is required")
        if not deployment:
            raise ValueError("AZURE_OPENAI_DEPLOYMENT is required")
        if not api_version:
            raise ValueError("AZURE_OPENAI_API_VERSION is required")

        # Chained credential: try Managed Identity first, fall back to Azure CLI
        credential = ChainedTokenCredential(
            ManagedIdentityCredential(),
            AzureCliCredential(),
        )
        logger.info("Using Entra ID authentication (ManagedIdentity → AzureCLI)")

        self.chat_client = AzureOpenAIChatClient(
            endpoint=endpoint,
            credential=credential,
            deployment_name=deployment,
            api_version=api_version,
        )
        logger.info("✅ AzureOpenAIChatClient created")

    def _create_agents(self):
        """Create the orchestrator and register sub-agents as tools."""
        # --- Create sub-agents ---
        comedian = create_comedian_agent(self.chat_client)

        # --- Register sub-agents as tools ---
        # To add a new agent: import its factory, create it, call .as_tool(), add to this list
        tools = [
            comedian.as_tool(),
        ]

        # --- Create the orchestrator agent ---
        self.agent = Agent(
            client=self.chat_client,
            instructions=ORCHESTRATOR_INSTRUCTIONS,
            tools=tools,
        )
        logger.info(f"✅ Orchestrator created with {len(tools)} sub-agent tool(s)")

    def _initialize_services(self):
        try:
            from microsoft_agents_a365.tooling.extensions.agentframework.services.mcp_tool_registration_service import (
                McpToolRegistrationService,
            )
            self.tool_service = McpToolRegistrationService()
            logger.info("✅ MCP tool service initialized")
        except Exception as e:
            logger.warning(f"⚠️ MCP tool service failed: {e}")
            self.tool_service = None

    async def setup_mcp_servers(self, auth: Authorization, auth_handler_name: Optional[str], context: TurnContext):
        """Set up MCP servers using agentic auth (OBO) so tools execute on behalf of the user."""
        if self.mcp_servers_initialized:
            return
        try:
            if not self.tool_service:
                return

            # Always use agentic auth — user identity flows through to tools via OBO
            self.agent = await self.tool_service.add_tool_servers_to_agent(
                chat_client=self.chat_client,
                agent_instructions=ORCHESTRATOR_INSTRUCTIONS,
                initial_tools=[],
                auth=auth,
                auth_handler_name=auth_handler_name,
                turn_context=context,
            )

            if self.agent:
                logger.info("✅ MCP setup completed (agentic auth / OBO)")
                self.mcp_servers_initialized = True
        except Exception as e:
            logger.error(f"MCP setup error: {e}")

    # --- AgentInterface implementation ---

    async def initialize(self):
        logger.info("Orchestrator agent initialized")

    async def process_user_message(
        self, message: str, auth: Authorization, auth_handler_name: Optional[str], context: TurnContext
    ) -> str:
        try:
            await self.setup_mcp_servers(auth, auth_handler_name, context)
            result = await self.agent.run(message)
            return self._extract_result(result) or "I couldn't process your request at this time."
        except Exception as e:
            logger.error(f"Error processing message: {e}")
            return f"Sorry, I encountered an error: {str(e)}"

    async def cleanup(self) -> None:
        try:
            if hasattr(self, "tool_service") and self.tool_service:
                await self.tool_service.cleanup()
            logger.info("Orchestrator cleanup completed")
        except Exception as e:
            logger.error(f"Cleanup error: {e}")

    def _extract_result(self, result) -> str:
        if not result:
            return ""
        if hasattr(result, "contents"):
            return str(result.contents)
        elif hasattr(result, "text"):
            return str(result.text)
        elif hasattr(result, "content"):
            return str(result.content)
        return str(result)
