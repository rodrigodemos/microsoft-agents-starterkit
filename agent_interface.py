# Copyright (c) Microsoft. All rights reserved.

"""
Abstract base class that any hosted agent must implement.
The generic host server uses this interface to interact with agents.
"""

from abc import ABC, abstractmethod
from typing import Optional

from microsoft_agents.hosting.core import Authorization, TurnContext


class AgentInterface(ABC):

    @abstractmethod
    async def initialize(self) -> None:
        """Initialize the agent and any required resources."""
        pass

    @abstractmethod
    async def process_user_message(
        self, message: str, auth: Authorization, auth_handler_name: Optional[str], context: TurnContext
    ) -> str:
        """Process a user message and return a response string."""
        pass

    @abstractmethod
    async def cleanup(self) -> None:
        """Clean up any resources used by the agent."""
        pass


def check_agent_inheritance(agent_class) -> bool:
    """Validate that an agent class inherits from AgentInterface."""
    if not issubclass(agent_class, AgentInterface):
        print(f"Agent {agent_class.__name__} does not inherit from AgentInterface")
        return False
    return True
