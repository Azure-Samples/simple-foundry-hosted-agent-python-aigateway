# Daily Repo Digest with AI Gateway

This sample runs a Microsoft Agent Framework repo-digest agent in Foundry Hosted Agents. Its model calls use AI Gateway, and Foundry Toolbox routes read-only GitHub MCP calls through AI Gateway.

## Prerequisites

- Python 3.13+ and [uv](https://docs.astral.sh/uv/getting-started/installation/)
- [Azure Developer CLI 1.27.0+](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)
- [GitHub CLI](https://cli.github.com/)
- [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) on Windows or when using the PowerShell helper scripts
- An Azure subscription with Foundry Hosted Agents access
- An Azure subscription enabled for the preview AI Gateway SKU
- A fine-grained GitHub token or GitHub App installation token limited to the repository being summarized

Install the Foundry azd extension:

```bash
azd ext install microsoft.foundry
```

## Set up

Create a dedicated GitHub credential with access to only the target repository.
Grant read-only Metadata, Actions, Contents, Issues, and Pull requests
permissions. Do not grant write or administration permissions.

For a one-time deployment, expose the credential to GitHub CLI only for the
`azd up` process:

```bash
read -rsp "Repository-scoped GitHub token: " GH_TOKEN && echo
export GH_TOKEN
azd up
unset GH_TOKEN
uv sync
```

The postprovision hook asks GitHub CLI for the selected credential, accepts only
fine-grained personal access token and GitHub App installation token formats,
rejects coarse write access to the configured repository, and verifies each
required read endpoint. GitHub does not expose the complete selected-repository
boundary or all granular permissions in the REST response, so you must still
create the token with only the permissions and repository access listed above.

You can instead use a dedicated GitHub CLI login. If more than one account is
configured, select it explicitly:

```bash
gh auth status --hostname github.com
GITHUB_MCP_GH_USER="your-github-login" azd up
```

The usual GitHub CLI OAuth login often carries the classic `repo` scope and is
intentionally rejected. Use a fine-grained token or GitHub App installation
token for this sample.

## Use the Gateway from the GitHub Copilot app

Configure the GitHub Copilot app custom model provider with:

- Base URL: `<AZURE_AI_GATEWAY_ENDPOINT>/default/models/openai/v1`
- Model: the `AZURE_AI_GATEWAY_MODEL` deployment name, `gpt-latest` by default
- Custom header: `Api-Key: <AZURE_AI_GATEWAY_API_KEY>`

Pass the Gateway key through the explicit `Api-Key` custom header. Do not rely on an API key field that converts the value to `Authorization: Bearer`; the AI Gateway runtime does not accept bearer-wrapped Gateway API keys.

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

See [`IMPLEMENTATION_NOTES.md`](IMPLEMENTATION_NOTES.md), including the [GitHub MCP read-only guardrails](IMPLEMENTATION_NOTES.md#github-mcp-read-only-guardrails), for architecture, authentication, AI Gateway contracts, security boundaries, configuration, monitoring, and deployment details.
