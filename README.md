# Daily Repo Digest with AI Gateway

This sample demonstrates a **hub-and-spoke governance architecture** for Foundry Hosted Agents using **AI Gateway** as the central hub. The Microsoft Agent Framework repo-digest agent runs in an isolated Foundry project spoke (`infra/foundry-agents/`) with zero model deployments and no direct credentials to backing models or external MCP servers. All model inference (`gpt-latest` three-tier failover across `gpt-6.1-sol` → `gpt-6-sol` → `gpt-5.4-mini`, plus `gpt-mini-latest`) and read-only GitHub MCP tool calls (via Foundry Toolbox) are routed **exclusively through AI Gateway (`infra/ai-gateway/`)** — there is no other access path from the agent to the model account (`infra/foundry-models/`) or to GitHub MCP.

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

`azd up` and `azd provision` automatically generate `.env` from the active azd environment. You can also refresh `.env` manually at any time:

```bash
# macOS or Linux
./scripts/create-dev-env.sh --force

# Windows
pwsh ./scripts/create-dev-env.ps1 -Force
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

Run the zero-auth container smoke test after building the image:

```bash
docker build -t daily-repo-digest .
python tests/container_smoke.py --image daily-repo-digest
```

With an existing Azure login and selected azd environment, verify the deployed
agent without redeploying, or optionally deploy first:

```bash
bash tests/test-azd-smoke.sh
bash tests/test-azd-smoke.sh --deploy
# Or provision and deploy first:
bash tests/test-azd-smoke.sh --up
```

## Deploy

```bash
azd up
azd ai agent invoke "Create a concise daily repo digest for microsoft/agent-framework."
```

If Azure leaves a failed AI Gateway after an activation or managed-identity conflict, rerun `azd up`. The preprovision hook deletes only the terminal-Failed `Microsoft.ApiManagement/aigateways` resource tagged for the current azd environment and waits for identity cleanup. `azd down` performs the same bounded settle process in its postdown hook. If the bound expires, follow the exact retry guidance printed by the hook rather than relying on name availability alone.

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

- **Hub (`infra/ai-gateway/`)**: Standalone AI Gateway (`Microsoft.ApiManagement/aigateways`) that enforces central routing, per-caller token limits and a `0.00/month` cost budget per caller identity on each model, Medium content-safety policies, failover (`gpt-latest`), and MCP tool brokering (`toolServers/github`). Only AI Gateway's managed identity receives cross-resource runtime access to the model account through the configured Foundry User RBAC assignment. Only AI Gateway holds the GitHub MCP token.
- **Agent Spoke (`infra/foundry-agents/`)**: Hosts the Foundry project, ACR, Storage, and Hosted Agent runtime. Its project account has no model deployments and no RBAC assignment on the separate model account, ensuring the agent cannot bypass AI Gateway to call models or GitHub MCP directly.
- **Model Spoke (`infra/foundry-models/`)**: Dedicated model-only Azure AI Services account (`allowProjectManagement: false`, `disableLocalAuth: true`) hosting `gpt-6.1-sol`, `gpt-6-sol`, and `gpt-5.4-mini`, accessible to the agent only through AI Gateway.

See [`IMPLEMENTATION_NOTES.md`](IMPLEMENTATION_NOTES.md), including the [GitHub credential boundary](IMPLEMENTATION_NOTES.md#github-credential-boundary) and [how to tighten the GitHub credential to least privilege](IMPLEMENTATION_NOTES.md#tighten-the-github-credential-to-least-privilege), for architecture, authentication, AI Gateway contracts, security boundaries, configuration, monitoring, and deployment details.
