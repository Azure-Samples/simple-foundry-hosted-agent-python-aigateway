"""Foundry hosted-agent-compatible entry point for the AI Gateway digest agent."""

import os

from dotenv import load_dotenv

load_dotenv()

# SDKStats probes Azure VM metadata to classify the host, which is irrelevant locally.
if not os.environ.get("FOUNDRY_HOSTING_ENVIRONMENT"):
    os.environ.setdefault("MICROSOFT_OTEL_SDKSTATS_DISABLED", "true")

from agent_framework_foundry_hosting import ResponsesHostServer
from repo_digest_agent import build_agent


def main() -> None:
    ResponsesHostServer(build_agent()).run()


if __name__ == "__main__":
    main()
