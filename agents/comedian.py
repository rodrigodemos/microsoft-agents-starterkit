# Copyright (c) Microsoft. All rights reserved.

"""
Comedian sub-agent — tells jokes and funny stories on any topic.
Used as a tool by the orchestrator agent.
"""

from agent_framework.azure import AzureOpenAIChatClient

COMEDIAN_INSTRUCTIONS = """You are a world-class stand-up comedian assistant.
Your job is to make people laugh. When asked to tell a joke or be funny:
- Tell clever, witty jokes appropriate for a workplace setting
- You can do puns, one-liners, observational humor, or short funny stories
- Tailor your humor to the topic the user mentions
- Keep it clean and professional
- If asked for a specific type of humor, adapt accordingly
- Always be upbeat and entertaining"""


def create_comedian_agent(client: AzureOpenAIChatClient):
    """Create the comedian agent from a shared Azure OpenAI client."""
    return client.as_agent(
        name="Comedian",
        description="An agent that tells jokes and funny stories on any topic. Use this when the user wants humor, jokes, or something funny.",
        instructions=COMEDIAN_INSTRUCTIONS,
    )
