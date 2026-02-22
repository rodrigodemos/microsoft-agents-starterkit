# Copyright (c) Microsoft. All rights reserved.

"""
In-memory token cache for Agent 365 Observability exporter authentication.
"""

import logging

logger = logging.getLogger(__name__)

_agentic_token_cache: dict[str, str] = {}


def cache_agentic_token(tenant_id: str, agent_id: str, token: str) -> None:
    key = f"{tenant_id}:{agent_id}"
    _agentic_token_cache[key] = token
    logger.debug(f"Cached agentic token for {key}")


def get_cached_agentic_token(tenant_id: str, agent_id: str) -> str | None:
    key = f"{tenant_id}:{agent_id}"
    token = _agentic_token_cache.get(key)
    if token:
        logger.debug(f"Retrieved cached agentic token for {key}")
    else:
        logger.debug(f"No cached token found for {key}")
    return token
