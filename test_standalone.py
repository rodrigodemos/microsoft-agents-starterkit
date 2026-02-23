# Copyright (c) Microsoft. All rights reserved.

"""
Standalone test — runs the orchestrator agent with the DevUI web chat interface.
No Teams, no Bot Framework, no authentication required.

Usage:
    uv run python test_standalone.py
"""

import os

from dotenv import load_dotenv
from azure.identity import ChainedTokenCredential, ManagedIdentityCredential, AzureCliCredential
from agent_framework import Agent
from agent_framework.azure import AzureOpenAIChatClient
from agent_framework_devui import serve

from agents.comedian import create_comedian_agent
from agents.orchestrator import ORCHESTRATOR_INSTRUCTIONS

load_dotenv()

endpoint = os.getenv("AZURE_OPENAI_ENDPOINT")
deployment = os.getenv("AZURE_OPENAI_DEPLOYMENT")
api_version = os.getenv("AZURE_OPENAI_API_VERSION")

if not all([endpoint, deployment, api_version]):
    print("Error: AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_DEPLOYMENT, and AZURE_OPENAI_API_VERSION must be set in .env")
    exit(1)

credential = ChainedTokenCredential(
    ManagedIdentityCredential(),
    AzureCliCredential(),
)

client = AzureOpenAIChatClient(
    endpoint=endpoint,
    credential=credential,
    deployment_name=deployment,
    api_version=api_version,
)

comedian = create_comedian_agent(client)

agent = Agent(
    name="Orchestrator",
    client=client,
    instructions=ORCHESTRATOR_INSTRUCTIONS,
    tools=[comedian.as_tool()],
)

print("Starting DevUI on http://localhost:8080")
serve(entities=[agent], port=8080)
