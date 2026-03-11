# Copyright (c) Microsoft. All rights reserved.

"""
Microsoft Graph user profile retrieval for personalizing agent responses.
Uses the Agent Identity OBO flow (Blueprint → T1 → Agent Identity OBO → Graph)
to call the Graph /me endpoint on behalf of the signed-in user.
"""

import logging
import os
from dataclasses import dataclass
from typing import Optional

import httpx

logger = logging.getLogger(__name__)

GRAPH_ME_URL = "https://graph.microsoft.com/v1.0/me"
GRAPH_SCOPES = "https://graph.microsoft.com/User.Read"

# Agent Identity configuration (from environment)
BLUEPRINT_CLIENT_ID = os.getenv("AGENT_BLUEPRINT_CLIENT_ID", "")
BLUEPRINT_CLIENT_SECRET = os.getenv(
    "CONNECTIONS__BLUEPRINT_CONNECTION__SETTINGS__CLIENTSECRET", ""
)
AGENT_IDENTITY_CLIENT_ID = os.getenv("AGENT_IDENTITY_CLIENT_ID", "")
TENANT_ID = os.getenv("TENANT_ID", "")
TOKEN_URL = f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token"

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


async def _agent_identity_obo(user_token: str) -> str | None:
    """Two-step Agent Identity OBO flow:
    1. Blueprint → client_credentials + fmi_path → T1
    2. Agent Identity → jwt-bearer OBO with T1 + user_token → Graph token
    """
    async with httpx.AsyncClient() as client:
        # Step 1: Blueprint → T1
        t1_response = await client.post(
            TOKEN_URL,
            data={
                "client_id": BLUEPRINT_CLIENT_ID,
                "scope": "api://AzureADTokenExchange/.default",
                "fmi_path": AGENT_IDENTITY_CLIENT_ID,
                "client_secret": BLUEPRINT_CLIENT_SECRET,
                "grant_type": "client_credentials",
            },
            timeout=10.0,
        )
        if t1_response.status_code != 200:
            error = t1_response.json().get("error_description", t1_response.text[:200])
            logger.warning(f"Blueprint → T1 failed: {error}")
            return None

        t1 = t1_response.json()["access_token"]
        logger.info("Agent Identity: T1 acquired from Blueprint")

        # Step 2: Agent Identity OBO with T1 + user token → resource token
        obo_response = await client.post(
            TOKEN_URL,
            data={
                "client_id": AGENT_IDENTITY_CLIENT_ID,
                "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion": t1,
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": user_token,
                "requested_token_use": "on_behalf_of",
                "scope": GRAPH_SCOPES,
            },
            timeout=10.0,
        )
        if obo_response.status_code != 200:
            error = obo_response.json().get("error_description", obo_response.text[:200])
            logger.warning(f"Agent Identity OBO failed: {error}")
            return None

        logger.info("Agent Identity: OBO token acquired for Graph")
        return obo_response.json()["access_token"]


def _has_agent_identity() -> bool:
    return all([BLUEPRINT_CLIENT_ID, BLUEPRINT_CLIENT_SECRET, AGENT_IDENTITY_CLIENT_ID, TENANT_ID])


async def fetch_user_profile(request_ctx: RequestContext) -> str:
    """Fetch the signed-in user's profile from Microsoft Graph.

    Uses the Agent Identity OBO flow if configured, otherwise falls back
    to the SDK's exchange_token method.
    """
    if not request_ctx.is_available:
        logger.debug("Auth context not available, skipping profile fetch")
        return "User profile not available (no auth context)."

    try:
        graph_token = None
        user_token = None

        # Get the user's SSO token via the SDK's OAuth flow
        # (UserAuthorization handler with AZUREBOTOAUTHCONNECTIONNAME returns raw user token
        # when OBOCONNECTIONNAME is not set)
        token_response = await request_ctx.auth.exchange_token(
            request_ctx.turn_context,
            scopes=[GRAPH_SCOPES],
            auth_handler_id=request_ctx.auth_handler_name,
        )
        if token_response and token_response.token:
            user_token = token_response.token
            logger.info("User SSO token acquired via SDK exchange_token")

        # Use the user token with the two-step Agent Identity OBO flow
        if user_token and _has_agent_identity():
            graph_token = await _agent_identity_obo(user_token)

        # Fallback: try security_token directly (for non-Teams scenarios)
        if not graph_token and _has_agent_identity():
            security_token = getattr(
                getattr(request_ctx.turn_context, "identity", None), "security_token", None
            )
            if security_token and security_token != user_token:
                logger.debug("Trying security_token as fallback for OBO")
                graph_token = await _agent_identity_obo(security_token)

        if not graph_token:
            logger.warning("No OBO token available (Agent Identity and SDK fallback both failed)")
            return "User profile not available (no OBO token)."

        async with httpx.AsyncClient() as client:
            response = await client.get(
                GRAPH_ME_URL,
                headers={"Authorization": f"Bearer {graph_token}"},
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
