# Daily Repo Digest with AI Gateway

This sample runs a Microsoft Agent Framework repo-digest agent in Foundry Hosted Agents. Model calls use AI Gateway, and Foundry Toolbox routes read-only GitHub MCP calls through AI Gateway.

The sample supports two deployment profiles:

| Profile | `GATEWAY_DEPLOYMENT_MODE` | Ownership |
| --- | --- | --- |
| Full-stack managed | `managed` (default) | The sample creates and manages the Foundry model account and deployments, AI Gateway, Gateway monitoring, runtime key, provider and model catalog, Connector Namespace, Foundry hosted-agent project, secure connections, and Toolbox. |
| Existing AI Gateway | `existing` | The sample creates only the Foundry hosted-agent project and its storage, registry, monitoring, secure connections, agent, routine, and Toolbox. It consumes the supplied AI Gateway without creating, recovering, deleting, purging, or updating any Gateway resource, model, provider, key, or GitHub ToolServer. |

## Prerequisites

- Python 3.13+ and [uv](https://docs.astral.sh/uv/getting-started/installation/)
- [Azure Developer CLI 1.27.0+](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [GitHub CLI](https://cli.github.com/) for managed mode
- PowerShell 7 on Windows or when using the PowerShell helper scripts
- An Azure subscription and a GitHub account

Install the Foundry azd extension:

```bash
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd ext install microsoft.foundry
```

## Deploy the full stack

Managed mode remains the default. Sign in with GitHub CLI, then deploy:

```bash
gh auth status --hostname github.com
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd up
uv sync
```

The hook reuses your GitHub CLI login for the read-only GitHub MCP tools. Any login works for a quick test; it only warns, and never fails, if the credential is broader than recommended. **For production and safety, strongly prefer a read-only, repo-scoped fine-grained token.** Your CLI login is account-wide, and the managed-mode hook stores the credential in the cloud AI Gateway ToolServer.

To create the token and apply it correctly, including the exact GitHub portal settings that grant read access to a public repository you do not own and fix `403 Forbidden` or empty MCP results on `microsoft/agent-framework`, follow [Set up the GitHub credential](IMPLEMENTATION_NOTES.md#tighten-the-github-credential-to-least-privilege).

## Deploy with an existing AI Gateway

AI Gateway Studio or another administrator supplies a nonsecret `.ai-gateway-studio.json`. Copy the documented shape and replace every example value:

```bash
cp .ai-gateway-studio.example.json .ai-gateway-studio.json
```

The contract is:

```json
{
  "schemaVersion": 1,
  "gatewayDeploymentMode": "existing",
  "gatewayResourceId": "/subscriptions/<subscription>/resourceGroups/<resource-group>/providers/Microsoft.ApiManagement/service/<gateway-name>",
  "gatewayEndpoint": "https://<gateway-host>/",
  "githubMcpEndpoint": "https://<gateway-host>/default/toolservers/<github-toolserver>/mcp",
  "modelAliases": {
    "default": "<full-model-alias>",
    "mini": "<mini-model-alias>"
  }
}
```

`gatewayResourceId` can use `Microsoft.ApiManagement/service` or `Microsoft.ApiManagement/aigateways`. The endpoints and model aliases are nonsecret. Do not put an API key in this file.

Validate the file and select the existing profile without provisioning Azure:

```bash
# macOS or Linux
./scripts/configure-existing-gateway.sh

# Windows
pwsh ./scripts/configure-existing-gateway.ps1
```

The bootstrap writes only local azd environment settings. It does not call `azd provision`, `azd deploy`, or an Azure write operation.

Deploy the sample-owned Foundry resources:

```bash
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd up
uv sync
```

During `azd up`, the postprovision hook reads an active Gateway key with the Gateway `listSecrets` action. The Foundry deployment creates or updates only these project objects:

- `aigw-github`, a `RemoteTool` connection whose target is `githubMcpEndpoint` and whose `Api-Key` header is stored by Foundry
- `ai-gateway-model`, a `CustomKeys` connection whose target is `gatewayEndpoint` and whose `Api-Key` credential is resolved by the hosted platform
- `repo-digest-tools`, a Toolbox that references `aigw-github`

Existing mode never sends a Gateway `PUT`, `DELETE`, or purge request. It never changes the existing GitHub ToolServer. The caller needs permission to read an active Gateway key and create connections and Toolbox versions in the new Foundry project.

## Secret boundary

Gateway API keys are not Bicep parameters or outputs. The hosted agent does not receive the key through an ordinary `${VAR}` substitution. `azure.yaml` uses the official Foundry connection placeholders:

```yaml
AZURE_AI_GATEWAY_ENDPOINT: ${{connections.ai-gateway-model.target}}
AZURE_AI_GATEWAY_API_KEY: ${{connections.ai-gateway-model.credentials.Api-Key}}
```

Foundry resolves these values from the `CustomKeys` project connection when the hosted container starts. Toolbox sends the same key from its separate `RemoteTool` connection. The agent sends the key only in the `Api-Key` header.

For local development, the postprovision hook retains the key in the selected, gitignored azd environment. The helper copies it to a gitignored `.env`, creates the file with mode `600` on POSIX systems or a current-user ACL on Windows, and never prints the key.

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

## Invoke the deployed agent

```bash
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd ai agent invoke \
  "Create a concise daily repo digest for microsoft/agent-framework."
```

Managed mode can recover a failed sample-owned Gateway. If Azure leaves it in a terminal failed state after an activation or managed-identity conflict, rerun `AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd up`. The preprovision hook deletes only the `AIGateway` tagged for the current azd environment, purges its APIM soft-delete record, and waits for identity cleanup. `AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd down` performs the same bounded purge and settle process in its postdown hook. Existing mode disables all of those lifecycle actions.

Run the scheduled digest immediately:

```bash
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd ai routine dispatch daily-repo-digest
```

## Change the agent default repository

```bash
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd env set GITHUB_REPOSITORY "owner/repo"
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd provision
```

The default is `microsoft/agent-framework`. The included scheduled routine keeps its explicit `microsoft/agent-framework` prompt.

## How it works

Start with [`repo_digest_agent.py`](repo_digest_agent.py). It connects the Agent Framework agent directly to the AI Gateway model route and uses Foundry Toolbox for the AI Gateway GitHub MCP route. [`github_mcp_middleware.py`](github_mcp_middleware.py) keeps GitHub results bounded, and [`main.py`](main.py) hosts the agent in Foundry.

See [`IMPLEMENTATION_NOTES.md`](IMPLEMENTATION_NOTES.md) for architecture, authentication, deployment contracts, security boundaries, monitoring, lifecycle behavior, and validation.
