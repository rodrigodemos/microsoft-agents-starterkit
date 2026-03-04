# Copyright (c) Microsoft. All rights reserved.

"""
Microsoft Graph user profile retrieval for personalizing agent responses.
Uses the OBO (On-Behalf-Of) flow to call the Graph /me endpoint
on behalf of the signed-in user.
"""

import logging
from dataclasses import dataclass, field
from typing import Optional

import httpx

logger = logging.getLogger(__name__)

GRAPH_ME_URL = "https://graph.microsoft.com/v1.0/me"
GRAPH_SCOPES = ["https://graph.microsoft.com/.default"]

# Fields to extract from the Graph /me response
PROFILE_FIELDS = [
    "displayName",
    "givenName",
    "surname",
    "jobTitle",
    "department",
    "officeLocation",
    "city",
    "state",
    "country",
    "mail",
    "aboutMe",
]


@dataclass
class RequestContext:
    """Mutable holder for per-request auth state.

    Set by the orchestrator before each agent.run() so that tool functions
    (created once at init time) can access the current request's auth context.
    """

    auth: Optional[object] = None
    auth_handler_name: Optional[str] = None
    turn_context: Optional[object] = None

    def set(self, auth, auth_handler_name, turn_context):
        self.auth = auth
        self.auth_handler_name = auth_handler_name
        self.turn_context = turn_context

    @property
    def is_available(self) -> bool:
        return all([self.auth, self.auth_handler_name, self.turn_context])


async def fetch_user_profile(request_ctx: RequestContext) -> str:
    """Fetch the signed-in user's profile from Microsoft Graph.

    Returns a formatted string with profile fields, or a fallback message
    if auth is unavailable or the Graph call fails.
    """
    if not request_ctx.is_available:
        logger.debug("Auth context not available, skipping profile fetch")
        return "User profile not available (no auth context)."

    try:
        token_response = await request_ctx.auth.exchange_token(
            request_ctx.turn_context,
            scopes=GRAPH_SCOPES,
            auth_handler_id=request_ctx.auth_handler_name,
        )

        async with httpx.AsyncClient() as client:
            response = await client.get(
                GRAPH_ME_URL,
                headers={"Authorization": f"Bearer {token_response.token}"},
                timeout=10.0,
            )
            response.raise_for_status()
            profile = response.json()

        parts = []
        for key in PROFILE_FIELDS:
            value = profile.get(key)
            if value:
                parts.append(f"{key}: {value}")

        if not parts:
            return "User profile retrieved but no details were populated."

        return "User profile:\n" + "\n".join(parts)

    except Exception as e:
        logger.warning(f"Failed to fetch user profile from Graph: {e}")
        return f"User profile not available ({type(e).__name__})."
