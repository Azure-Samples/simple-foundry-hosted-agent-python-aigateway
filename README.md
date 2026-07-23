# Daily Repo Digest with AI Gateway

This sample runs a Microsoft Agent Framework repo-digest agent in Foundry Hosted Agents. Its model calls use AI Gateway, and Foundry Toolbox routes read-only GitHub MCP calls through AI Gateway.

## Prerequisites

- Python 3.13+ and [uv](https://docs.astral.sh/uv/getting-started/installation/)
- [Azure Developer CLI 1.27.0+](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)
- [GitHub CLI](https://cli.github.com/)
- [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) on Windows or when using the PowerShell helper scripts
- An Azure subscription and a Github account

Install the Foundry azd extension:

```bash
azd ext install microsoft.foundry
```

## Set up

Sign in with GitHub CLI, then deploy:

```bash
gh auth status --hostname github.com
azd up
uv sync
```

The hook reuses your GitHub CLI login for the read-only GitHub MCP tools. Any
login works for a quick test; it only warns (never fails) if the credential is
broader than recommended. **For production and safety, strongly prefer a
read-only, repo-scoped fine-grained token** — your CLI login is account-wide and
the hook stores the credential in the cloud AI Gateway ToolServer.

To create the token and apply it correctly — including the exact GitHub portal
settings that grant read access to a public repository you do not own (the fix
for a `403 Forbidden` / empty MCP results on `microsoft/agent-framework`) —
follow **[Set up the GitHub credential](IMPLEMENTATION_NOTES.md#tighten-the-github-credential-to-least-privilege)**.

## Run locally

Create the local `.env` from the selected azd environment:

```bash
# macOS or Linux
./scripts/create-dev-env.sh

# Windows
pwsh ./scripts/create-dev-env.ps1
```

Start the agent:

```bash
uv run python main.py
```

In another terminal, request a digest:

```bash
curl -sS -X POST http://localhost:8088/responses \
  -H "Content-Type: application/json" \
  -d '{"input": "Create a concise daily repo digest for microsoft/agent-framework.", "stream": false}'
```

Or use the console:

```bash
uv run chat.py
```

## Deploy

```bash
azd up
azd ai agent invoke "Create a concise daily repo digest for microsoft/agent-framework."
```

If Azure leaves a failed AI Gateway after an activation or managed-identity conflict, rerun `azd up`. The preprovision hook deletes only the terminal-Failed `AIGateway` tagged for the current azd environment, purges its APIM soft-delete record, and waits for identity cleanup. `azd down` performs the same bounded purge and settle process in its postdown hook. If the bound expires, follow the exact retry guidance printed by the hook rather than relying on name availability alone.

Run the scheduled digest immediately:

```bash
azd ai routine dispatch daily-repo-digest
```

## Change the agent default repository

```bash
azd env set GITHUB_REPOSITORY "owner/repo"
azd provision
```

The default is `microsoft/agent-framework`. The included scheduled routine keeps its explicit `microsoft/agent-framework` prompt.

## How it works

**Start with [`repo_digest_agent.py`](repo_digest_agent.py).** It connects the Agent Framework agent directly to the AI Gateway model route and uses Foundry Toolbox for the AI Gateway GitHub MCP route. [`github_mcp_middleware.py`](github_mcp_middleware.py) keeps GitHub results bounded, and [`main.py`](main.py) hosts the agent in Foundry.

See [`IMPLEMENTATION_NOTES.md`](IMPLEMENTATION_NOTES.md), including the [GitHub credential boundary](IMPLEMENTATION_NOTES.md#github-credential-boundary) and [how to tighten the GitHub credential to least privilege](IMPLEMENTATION_NOTES.md#tighten-the-github-credential-to-least-privilege), for architecture, authentication, AI Gateway contracts, security boundaries, configuration, monitoring, and deployment details.
