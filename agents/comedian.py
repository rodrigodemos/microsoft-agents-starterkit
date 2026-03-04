# Copyright (c) Microsoft. All rights reserved.

"""
Comedian sub-agent — tells jokes and funny stories on any topic.
Uses Microsoft Graph to personalize humor based on the user's profile.
Used as a tool by the orchestrator agent.
"""

from agent_framework import Agent, tool
from agent_framework.azure import AzureOpenAIChatClient

from agents.graph_user_profile import RequestContext, fetch_user_profile

COMEDIAN_INSTRUCTIONS = """You are a world-class stand-up comedian assistant.
Your job is to make people laugh. When asked to tell a joke or be funny:
- FIRST, call the get_user_profile tool to learn about the user
- Use the user's profile (job title, location, department, etc.) to craft personalized, relevant humor
- Tell clever, witty jokes appropriate for a workplace setting
- You can do puns, one-liners, observational humor, or short funny stories
- Tailor your humor to the topic the user mentions AND their profile context
- Keep it clean and professional
- If the user profile is not available, tell a great generic joke instead
- If asked for a specific type of humor, adapt accordingly
- Always be upbeat and entertaining"""


def create_comedian_agent(client: AzureOpenAIChatClient, request_context: RequestContext):
    """Create the comedian agent with a user profile tool for personalized jokes."""

    @tool(name="get_user_profile", description="Get the current user's profile (name, job title, location, department) to personalize jokes.")
    async def get_user_profile() -> str:
        """Retrieve the signed-in user's profile from Microsoft Graph."""
        return await fetch_user_profile(request_context)

    return Agent(
        client=client,
        name="Comedian",
        description="An agent that tells jokes and funny stories on any topic. Use this when the user wants humor, jokes, or something funny.",
        instructions=COMEDIAN_INSTRUCTIONS,
        tools=[get_user_profile],
    )
