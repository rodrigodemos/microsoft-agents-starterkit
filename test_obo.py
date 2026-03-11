# test_obo.py — Test OBO token exchange directly, without Teams or Bot Service
#
# Tests the Agent Identity Blueprint's ability to exchange a user token
# for a Graph token via the standard OAuth 2.0 OBO flow.
#
# Usage: uv run python test_obo.py

import asyncio
import os
import sys

import httpx
import msal
from dotenv import load_dotenv

load_dotenv()

# ─── Configuration ───────────────────────────────────────────────────────────────

# The bot app acts as the "client" (like Teams would) to get a user token
BOT_CLIENT_ID = os.getenv("BOT_CLIENT_ID") or os.getenv("CLIENT_ID") or os.getenv("BOT_ID", "")
TENANT_ID = os.getenv("TENANT_ID") or os.getenv("BOT_TENANT_ID", "")

# The Blueprint does the OBO exchange
BLUEPRINT_CLIENT_ID = os.getenv("AGENT_BLUEPRINT_CLIENT_ID", "")
BLUEPRINT_CLIENT_SECRET = os.getenv("AGENT_BLUEPRINT_CLIENT_SECRET", "")

GRAPH_SCOPES = ["https://graph.microsoft.com/User.Read"]
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"


def print_config():
    print("=== OBO Test (Agent Identity Blueprint) ===")
    print(f"  Bot Client ID (client):    {BOT_CLIENT_ID}")
    print(f"  Blueprint Client ID (OBO): {BLUEPRINT_CLIENT_ID}")
    print(f"  Blueprint Secret:          {'set' if BLUEPRINT_CLIENT_SECRET else 'NOT SET'}")
    print(f"  Tenant ID:                 {TENANT_ID}")
    print()

    missing = []
    if not BOT_CLIENT_ID: missing.append("BOT_CLIENT_ID (or CLIENT_ID)")
    if not BLUEPRINT_CLIENT_ID: missing.append("AGENT_BLUEPRINT_CLIENT_ID")
    if not BLUEPRINT_CLIENT_SECRET: missing.append("AGENT_BLUEPRINT_CLIENT_SECRET")
    if not TENANT_ID: missing.append("TENANT_ID")
    if missing:
        print("ERROR: Missing env vars: " + ", ".join(missing))
        sys.exit(1)


# ─── Step 1: Get a user token via bot app (simulates Teams SSO) ──────────────────

def get_user_token() -> str:
    """Get a user token using the bot app as the public client,
    requesting the Blueprint's access_agent scope (same as Teams would)."""
    print("--- Step 1: Get user token via bot app (simulates Teams) ---")

    # Bot app acts as the client (like Teams)
    app = msal.PublicClientApplication(
        client_id=BOT_CLIENT_ID,
        authority=AUTHORITY,
    )

    # Request a token for the Blueprint's scope
    scopes = [f"api://{BLUEPRINT_CLIENT_ID}/access_agent"]
    print(f"  Client app:  {BOT_CLIENT_ID}")
    print(f"  Target scope: {scopes[0]}")

    flow = app.initiate_device_flow(scopes=scopes)
    if "user_code" not in flow:
        print(f"  ERROR: {flow.get('error_description', 'Could not start device flow')}")
        print()
        print("  The bot app may need public client flows enabled:")
        print(f"    az ad app update --id {BOT_CLIENT_ID} --is-fallback-public-client true")
        sys.exit(1)

    print(f"  {flow['message']}")
    result = app.acquire_token_by_device_flow(flow)

    if "access_token" not in result:
        print(f"  ERROR: {result.get('error_description', 'unknown')}")
        sys.exit(1)

    print(f"  User token acquired (length: {len(result['access_token'])})")
    return result["access_token"]


# ─── Step 2: Two-step Agent Identity OBO exchange ────────────────────────────────

AGENT_IDENTITY_CLIENT_ID = os.getenv("AGENT_IDENTITY_CLIENT_ID", "")


def obo_exchange(user_token: str) -> str | None:
    """Two-step OBO per the Agent Identity protocol:
    Step A: Blueprint → client_credentials + fmi_path → T1
    Step B: Agent Identity → jwt-bearer OBO with T1 + user_token → resource token
    """
    print("\n--- Step 2a: Blueprint → client_credentials + fmi_path → T1 ---")

    if not AGENT_IDENTITY_CLIENT_ID:
        print("  ERROR: AGENT_IDENTITY_CLIENT_ID not set")
        return None

    import requests

    token_url = f"{AUTHORITY}/oauth2/v2.0/token"

    # Step A: Get T1 from Blueprint using client_credentials with fmi_path
    step_a_body = {
        "client_id": BLUEPRINT_CLIENT_ID,
        "scope": "api://AzureADTokenExchange/.default",
        "fmi_path": AGENT_IDENTITY_CLIENT_ID,
        "client_secret": BLUEPRINT_CLIENT_SECRET,
        "grant_type": "client_credentials",
    }

    resp = requests.post(token_url, data=step_a_body)
    if resp.status_code != 200:
        print(f"  FAILED ({resp.status_code}): {resp.json().get('error_description', resp.text[:300])}")
        return None

    t1 = resp.json().get("access_token")
    print(f"  T1 acquired (length: {len(t1)})")

    # Step B: Agent Identity does OBO with T1 (as client_assertion) + user token
    print("\n--- Step 2b: Agent Identity → OBO with T1 + user token → Graph ---")
    step_b_body = {
        "client_id": AGENT_IDENTITY_CLIENT_ID,
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": t1,
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": user_token,
        "requested_token_use": "on_behalf_of",
        "scope": " ".join(GRAPH_SCOPES),
    }

    resp = requests.post(token_url, data=step_b_body)
    if resp.status_code != 200:
        print(f"  FAILED ({resp.status_code}): {resp.json().get('error_description', resp.text[:300])}")
        return None

    graph_token = resp.json().get("access_token")
    print(f"  OBO SUCCESS (token length: {len(graph_token)})")
    return graph_token


# ─── Step 3: Call Graph /me ──────────────────────────────────────────────────────

async def call_graph(token: str):
    """Call Graph /me with the OBO token."""
    print("\n--- Step 3: Call Graph /me ---")
    async with httpx.AsyncClient() as client:
        response = await client.get(
            "https://graph.microsoft.com/v1.0/me",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10.0,
        )
        if response.status_code == 200:
            profile = response.json()
            print(f"  User:  {profile.get('displayName', '?')}")
            print(f"  Email: {profile.get('mail', '?')}")
            print(f"  Job:   {profile.get('jobTitle', '?')}")
        else:
            print(f"  Graph error: {response.status_code} {response.text[:300]}")


# ─── Main ────────────────────────────────────────────────────────────────────────

async def main():
    print_config()
    user_token = get_user_token()
    graph_token = obo_exchange(user_token)
    if graph_token:
        await call_graph(graph_token)
    else:
        print("\n  Possible fixes:")
        print("  - Grant admin consent for User.Read on the Blueprint")
        print("  - Ensure the Blueprint has the access_agent scope configured")
        print("  - Check the client secret is correct")


if __name__ == "__main__":
    asyncio.run(main())
