# Copyright (c) Microsoft. All rights reserved.

"""
Entry point — starts the M365 host server with the OrchestratorAgent.
"""

import sys

try:
    from agents import OrchestratorAgent
    from host_agent_server import create_and_run_host
except ImportError as e:
    print(f"Import error: {e}")
    print("Please ensure dependencies are installed: uv pip install -e . --prerelease=allow")
    sys.exit(1)


def main():
    try:
        print("Starting Orchestrator Agent...")
        print()
        create_and_run_host(OrchestratorAgent)
    except Exception as e:
        print(f"❌ Failed to start server: {e}")
        import traceback
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    exit(main())
