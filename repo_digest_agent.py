"""Repo digest automation agent for the Foundry Hosted Agent sample."""

import os

from agent_framework import Agent
from agent_framework.openai import OpenAIChatClient
from agent_framework_foundry_hosting import FoundryToolbox
from azure.identity import DefaultAzureCredential

from github_mcp_middleware import compact_github_results

DEFAULT_REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "microsoft/agent-framework")
DEFAULT_GATEWAY_MODEL = "gpt-latest"
DEFAULT_MAX_OUTPUT_TOKENS = 2_048
OPENAI_NO_BEARER_AUTH = "workload-identity-auth"

INSTRUCTIONS = f"""
You create concise daily GitHub repository digests from live repository data.

- Always use the GitHub MCP tools before answering a repo digest request.
- The configured default repository is `{DEFAULT_REPOSITORY}`. Use it when the
  user does not provide a repository. The repository full name is already known,
  so do not call any repository search tool to look it up.
- For a daily digest, call the three GitHub tools below in the first tool round
  so they run in parallel. Report total counts from the tool results, then
  highlight the most relevant items.
- For pull requests, call aigw-github___github_list_pull_requests with state "all", sort
  "updated", direction "desc", perPage 100, and page 1. Tool middleware keeps
  only results updated in the last 24 hours and removes fields the digest does
  not use.
- For issues, call aigw-github___github_list_issues with owner and repo as separate
  arguments. Tool middleware sets orderBy "UPDATED_AT", direction "DESC", a
  since cutoff of the last 24 hours, and perPage 100. Do not pass a query
  string or a page number. This uses the core GitHub API, not the Search API.
- For workflows, call aigw-github___github_actions_list with method
  "list_workflow_runs" and
  workflow_runs_filter status "completed", per_page 100, and page 1. Do not use
  "failure" as a status. Tool middleware keeps only failed runs from the last
  24 hours and removes fields the digest does not use.
- Focus on what changed, what needs attention, and useful next actions.
- Return a one-line summary, PRs updated in the last 24 hours, issues updated
  in the last 24 hours, workflow failures, and suggested next actions.
- If a section has no items, say "None found".
- Do not invent activity that is not in the tool result.
"""


def _gateway_settings() -> tuple[str, str]:
    gateway_endpoint = os.environ.get("AZURE_AI_GATEWAY_ENDPOINT")
    if not gateway_endpoint:
        raise RuntimeError("Set AZURE_AI_GATEWAY_ENDPOINT to the AI Gateway endpoint.")

    gateway_key = os.environ.get("AZURE_AI_GATEWAY_API_KEY")
    if not gateway_key:
        raise RuntimeError("Set AZURE_AI_GATEWAY_API_KEY to an AI Gateway key.")

    return gateway_endpoint.rstrip("/"), gateway_key


def _gateway_client() -> OpenAIChatClient:
    gateway_endpoint, gateway_key = _gateway_settings()
    return OpenAIChatClient(
        model=os.environ.get("AZURE_AI_GATEWAY_MODEL", DEFAULT_GATEWAY_MODEL),
        base_url=gateway_endpoint + "/default/models/openai/v1/",
        # This OpenAI transport placeholder suppresses its Bearer header.
        api_key=OPENAI_NO_BEARER_AUTH,
        default_headers={"Api-Key": gateway_key},
    )


def _github_toolbox() -> FoundryToolbox:
    return FoundryToolbox(
        DefaultAzureCredential(
            exclude_managed_identity_credential=not bool(
                os.environ.get("FOUNDRY_HOSTING_ENVIRONMENT")
            )
        ),
        timeout=60,
    )


def build_agent() -> Agent:
    return Agent(
        client=_gateway_client(),
        name="daily-repo-digest",
        description="Creates daily GitHub repository digests through AI Gateway.",
        instructions=INSTRUCTIONS,
        tools=_github_toolbox(),
        default_options={"store": False, "max_tokens": DEFAULT_MAX_OUTPUT_TOKENS},
        middleware=[compact_github_results],
    )
