# Implementation Notes

These notes describe the public architecture, preview contracts, security
boundaries, configuration, and validation steps for the sample.

## Runtime shape

This repository contains a Foundry Hosted Agent. It does not include an Azure
Functions application.

- `main.py` starts an Agent Framework `ResponsesHostServer`.
- `repo_digest_agent.py` creates the agent, calls the AI Gateway model route,
  and connects to Foundry Toolbox.
- `github_mcp_middleware.py` bounds GitHub tool arguments and compacts results
  before the follow-up model call.
- `github_credential_validator.py` performs an advisory (non-blocking) check of
  the selected credential and warns when it is broader than a fine-grained,
  read-only, repository-scoped token.
- `toolbox.yaml` declares the Foundry Toolbox GitHub MCP source.
- `agent.yaml` describes the hosted agent.
- `azure.yaml` declares the Foundry project, hosted agent, scheduled routine,
  Bicep provider, and deployment hooks.
- `infra/main.bicep` is the subscription-scope deployment entry point.
- `infra/foundry-models/main.bicep` creates the model-serving Foundry account
  and deployments.
- `infra/foundry-agents/main.bicep` creates the agent project, storage,
  Container Registry, monitoring, connections, and RBAC.
- `infra/ai-gateway/main.bicep` creates AI Gateway, its Connector Namespace,
  model provider, model registrations, runtime key, and monitoring.
- `chat.py` is a local console client for the Responses endpoint.

The scheduled routine is named `daily-repo-digest`. It runs at 9 AM in the
configured timezone and asks the agent for a digest of
`microsoft/agent-framework`. The Responses API also supports interactive
requests.

## Request path

```mermaid
flowchart LR
  operator["Operator"]
  agent["Foundry Hosted Agent"]
  toolbox["Foundry Toolbox"]
  gateway["AI Gateway"]
  models["Foundry model deployments"]
  github["GitHub MCP server"]

  operator --> agent
  agent -->|"model request and Api-Key"| gateway
  agent -->|"Entra identity"| toolbox
  toolbox -->|"project connection and Api-Key"| gateway
  gateway -->|"managed identity and Foundry User RBAC"| models
  gateway -->|"repository-scoped read-only credential"| github
```

Model requests use
`<gateway>/default/models/openai/v1/chat/completions` or the corresponding
Responses route. Tool requests use
`<gateway>/default/toolservers/github/mcp`.

The agent does not call a Foundry model endpoint directly. This keeps model
traffic behind AI Gateway policies. `FoundryChatClient` is intentionally not
used for model inference.

## Foundry Toolbox

The tool path is:

```text
Agent -> Foundry Toolbox -> AI Gateway -> GitHub MCP
```

`toolbox.yaml` declares one MCP source backed by the `aigw-github` project
connection. The postprovision hook stores the AI Gateway `Api-Key` in that
connection. `FoundryToolbox` authenticates the agent-to-Toolbox request with
Entra identity.

The GitHub source sets `require_approval: "never"` because all three exposed
operations are read-only and the scheduled routine cannot pause for approval.
AI Gateway also injects:

- `X-MCP-Readonly: true`
- `X-MCP-Tools: list_pull_requests,list_issues,actions_list`
- `failureMode: failClosed`

Tool Search is not enabled. The agent has only three known tools and calls all
three in one parallel tool round, so discovery would add latency without
reducing the initial schema enough to help.

## GitHub credential boundary

The recommended GitHub backend credential is a fine-grained personal access
token or GitHub App installation token limited to the repository being
summarized, with read-only access for:

- Metadata
- Actions
- Contents
- Issues
- Pull requests

Avoid repository write, administration, organization administration, workflow
write, or classic `repo` scope where possible.

During postprovision, the hook obtains the credential from GitHub CLI. `GH_TOKEN`
can supply an ephemeral token for local or CI deployment. A dedicated GitHub
CLI account can be selected with `GITHUB_MCP_GH_USER`.

Before storing the credential in the ToolServer, the validator runs an advisory,
non-blocking check that:

1. Requires `GITHUB_REPOSITORY` to use `owner/repository` syntax.
2. Warns when the token is not a `github_pat_` fine-grained personal access
   token or a `ghs_` GitHub App installation access token, and links to the docs
   for creating one.
3. For fine-grained and installation tokens, calls the GitHub repository API and
   warns if it lacks read access or exposes `admin`, `maintain`, `push`, or
   `triage` repository permissions, and exercises the Contents, Issues, Pull
   requests, and Actions runs endpoints.

The check never blocks deployment; it only surfaces warnings. GitHub does not
return the complete selected-repository boundary or every granular write
permission through the coarse repository role flags, so for least privilege the
operator should still scope the token to only that repository with the
documented read-only permissions.

The GitHub credential is used only to configure the AI Gateway ToolServer. It
is not written to Bicep outputs, the azd environment, `.env`, or hosted-agent
environment variables. The target repository in the agent prompt is
configuration, not an authorization boundary.

## Tighten the GitHub credential to least privilege

If `azd up` prints a warning that the GitHub credential is a broad,
account-wide OAuth or classic token, provisioning still succeeds, but the
postprovision hook stores that credential in the cloud AI Gateway ToolServer.
Replace it with a fine-grained, repository-scoped, read-only token by following
both parts below: create the token in the GitHub portal, then re-apply it from
the command line.

> **Seeing `403 Forbidden` or empty MCP results for a public repo you do not
> own (for example `microsoft/agent-framework`)?** The token was applied, but it
> is being refused. Two common causes:
>
> - **Enterprise token-lifetime policy.** The repo owner's enterprise can cap
>   fine-grained token lifetimes. The **Microsoft Open Source** enterprise
>   forbids fine-grained tokens whose lifetime is **greater than 8 days** and
>   returns `403` on every call (the body names the enterprise and links to your
>   token's settings). Regenerate the token with an **expiration of 7 days or
>   less** (step 3 below).
> - **Missing public-repo scope.** A fine-grained token cannot read a repository
>   you do not own unless it is scoped with **Repository access → Public
>   repositories (read-only)** (step 5 below). "Only select repositories" cannot
>   include a repo you do not administer, so it yields no read access.
>
> Confirm the exact reason by reading the response body:
>
> ```bash
> curl -sS -H "Authorization: Bearer $GH_TOKEN" \
>   -H "Accept: application/vnd.github+json" \
>   https://api.github.com/repos/microsoft/agent-framework
> ```

### 1. Create the token in the GitHub portal

1. Open <https://github.com/settings/personal-access-tokens/new>. This is
   **Settings → Developer settings → Personal access tokens → Fine-grained
   tokens → Generate new token**.
2. **Token name**: for example `foundry-ai-gateway-repo-digest`.
3. **Expiration**: choose the shortest window that fits your rotation policy. If
   the repository owner belongs to an enterprise that caps fine-grained token
   lifetimes, you must stay within that cap or every API call returns `403`. The
   **Microsoft Open Source** enterprise (which owns `microsoft/agent-framework`)
   forbids fine-grained tokens with a lifetime greater than **8 days**, so pick
   **7 days** for that and other Microsoft-owned public repositories.
4. **Resource owner**: select the account or organization that owns the
   repository being summarized. For a public repository you do not own, select
   your own account.
5. **Repository access**:
   - For a repository you own or administer, choose **Only select
     repositories** and pick that single repository.
   - For a public repository you do not own, choose **Public repositories
     (read-only)**. This grants the read-only `pull` permission with no
     repository-permission selection required; skip to step 7.
6. **Repository permissions** (only when you selected a specific repository) —
   set each of these to **Read-only** and leave everything else at **No
   access**:
   - Metadata (required; auto-selected)
   - Actions
   - Contents
   - Issues
   - Pull requests
7. Click **Generate token** and copy the `github_pat_...` value. You cannot view
   it again after leaving the page.

Avoid repository write, administration, organization administration, workflow
write, or classic `repo` scope.

### 2. Apply the token from the command line

Re-run provisioning with the fine-grained token exported as `GH_TOKEN`. The hook
prefers `GH_TOKEN` over the account-wide GitHub CLI login and writes the tighter
credential into the ToolServer.

macOS or Linux (bash):

```bash
read -rsp "Fine-grained GitHub token: " GH_TOKEN && echo
export GH_TOKEN
azd provision
```

macOS (zsh — the default macOS shell). The `read` prompt syntax differs from
bash: the prompt goes *inside* the variable spec as `VAR?prompt`, and `-p` must
not be used (in zsh `-p` reads from a coprocess, so no prompt appears). Paste
one line at a time so `read` does not consume the following lines as input:

```zsh
read -rs "GH_TOKEN?Fine-grained GitHub token: " && echo
export GH_TOKEN
azd provision
```

Shell-agnostic alternative (hidden entry, works in both bash and zsh):

```bash
export GH_TOKEN="$(python3 -c 'import getpass; print(getpass.getpass("Fine-grained GitHub token: "))')"
azd provision
```

Windows (PowerShell 7):

```powershell
$GH_TOKEN = Read-Host -Prompt "Fine-grained GitHub token" -AsSecureString
$env:GH_TOKEN = [System.Net.NetworkCredential]::new("", $GH_TOKEN).Password
azd provision
```

`azd up` also works in place of `azd provision`. A GitHub App installation
access token (`ghs_...`) is an equally accepted least-privilege credential.

### 3. Confirm the warning is gone

Re-running provisioning with the fine-grained token should print
`Using the active GitHub CLI login for GitHub MCP.` with no credential warning.
To check the token before provisioning:

```bash
GITHUB_MCP_TOKEN_TO_VALIDATE="$GH_TOKEN" \
  python3 github_credential_validator.py "$GITHUB_REPOSITORY"
```

A clean token prints that it has the required read access and no coarse write
role. GitHub does not return the complete selected-repository boundary or every
granular write permission through the coarse repository role flags, so the
advisory check cannot certify least privilege on its own; scoping the token in
the portal as above is what enforces it.

## AI Gateway Bicep contracts

The root deployment creates three resource groups:

- `foundryagents` for the Foundry project, agent hosting, storage, Container
  Registry, and hosted-agent monitoring.
- `foundrymodels` for the separate Foundry model account and deployments.
- `gateway` for AI Gateway, Connector Namespace, Gateway monitoring, model
  provider, and model registrations.

The only cross-group runtime authorization is the AI Gateway system identity's
Foundry User role assignment on the model account. The public Azure
role-definition ID used by the template is
`53ca6127-db72-4b80-b1b0-d745d6d5456d`.

The AI Gateway module uses these preview contracts:

- `Microsoft.ApiManagement/service@2025-09-01-preview`
- SKU `AIGateway` with capacity `1`
- `Microsoft.ApiManagement/service/workspaces/modelProviders@2025-09-01-preview`
- `Microsoft.ApiManagement/service/workspaces/modelProviders/models@2025-09-01-preview`
- `Microsoft.ApiManagement/service/workspaces/toolServers@2025-09-01-preview`
- `Microsoft.ApiManagement/service/apiKeys@2025-09-01-preview`
- `Microsoft.Web/connectorGateways@2026-05-01-preview`

The Connector Namespace uses the same name, resource group, and location as
the APIM AI Gateway service. It is a separate resource from the GitHub MCP
ToolServer and supports connector-backed scenarios.

The default workspace is implicit for control-plane child resources. The
postprovision hook waits for the workspace child collection before configuring
the GitHub ToolServer.

The Foundry model provider uses:

- `kind: Foundry`
- The model account endpoint returned by Azure
- Foundry account and deployment resource IDs
- `authentication.kind: ManagedIdentity`
- Token resource `https://cognitiveservices.azure.com/`

Each model registration includes:

- `apiFormat: OpenAIChatCompletions`
- `/openai/v1/chat/completions`
- `/openai/v1/responses`
- A token-limit policy derived from deployment capacity
- `deployment.modelName` set to the Foundry deployment name from the final
  segment of the deployment resource ID

The deployment name, not the backing catalog model name, is the OpenAI `model`
value sent through AI Gateway.

## Regions and model defaults

The default split is:

- Foundry, storage, Container Registry, and monitoring: `eastus2`
- AI Gateway and Connector Namespace: `eastus2`

The Foundry region allowlist is:

- `eastus`
- `eastus2`
- `westus`
- `northcentralus`
- `swedencentral`
- `japaneast`

The AI Gateway preview region allowlist is:

- `westus2`
- `westus3`
- `eastus`
- `westcentralus`
- `swedencentral`
- `eastus2`

The model defaults are:

| Purpose | Gateway deployment | Backing model | Version | Capacity |
| --- | --- | --- | --- | --- |
| Full | `gpt-latest` | `gpt-5.6-sol` | `2026-07-09` | 20 |
| Mini | `gpt-mini-latest` | `gpt-5.4-mini` | `2026-03-17` | 200 |

If `gpt-5.6-sol` is unavailable, set `modelName=gpt-5.5` and
`modelVersion=2026-04-24`.

Global Standard capacity maps to the Gateway token limit at 1,000 tokens per
minute per capacity unit. Capacity 20 therefore registers 20,000 tokens per
minute for the full deployment. Mini capacity 200 accommodates requests from
the GitHub Copilot app, also called ghapp, when built-in tool definitions make
the prompt substantially larger.

The agent caps each response at 2,048 output tokens. Azure quota evaluation
uses an estimate based on the prompt and requested maximum output, so this cap
reduces avoidable reservation pressure on the follow-up call after MCP tool
execution.

## Runtime key handling

Bicep creates `apiKeys/default`. The postprovision hook retrieves the Gateway
key through `listSecrets` and retains `listValues` as a preview-contract
fallback. It can reuse the saved azd environment value when a later
reprovision cannot retrieve the value again.

The Gateway key is sent in the explicit `Api-Key` header. It is not sent as
`Authorization: Bearer`. The backing Foundry account has local authentication
disabled, and provisioning does not call the Foundry `listKeys` action.

The runtime fails when the Gateway endpoint or key is missing. It has no direct
Foundry fallback.

## AI Gateway deletion lifecycle

APIM deletion can include a live service phase, a soft-deleted service phase,
and an identity cleanup interval. Name availability alone does not prove that
identity cleanup has completed.

`azure.yaml` invokes the lifecycle scripts in two paths:

- Preprovision preserves a succeeded Gateway and removes only a terminal
  failed Gateway that matches the current azd environment ownership markers.
- Postdown completes the explicit teardown, waits for the live resource to
  disappear, purges the soft-deleted APIM service, and waits for identity
  cleanup.

The scripts use bounded exponential polling. Defaults are:

- Initial interval: 5 seconds
- Maximum interval: 30 seconds
- Identity quiet window: 180 seconds
- Total operation bound: 900 seconds

Tests can override these values with:

- `APIM_LIFECYCLE_POLL_INITIAL_SECONDS`
- `APIM_LIFECYCLE_POLL_MAX_SECONDS`
- `APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS`
- `APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS`

The nonsecret `.azure/<environment>/apim-lifecycle.state` marker contains only
environment and resource identity, location, lifecycle state, time, and a
deployment or resource failure identifier.

Relevant public documentation:

- [Azure API Management soft-delete](https://learn.microsoft.com/azure/api-management/soft-delete)
- [Deleted Services - Get By Name](https://learn.microsoft.com/rest/api/apimanagement/deleted-services/get-by-name?view=rest-apimanagement-2024-05-01)
- [Deleted Services - Purge](https://learn.microsoft.com/rest/api/apimanagement/deleted-services/purge?view=rest-apimanagement-2024-05-01)

## Hosted-agent image and monitoring

The hosted agent uses `language: docker` and `docker.remoteBuild: true`. The
Foundry module creates a Premium Container Registry with admin credentials
disabled, grants the Foundry project identity `AcrPull`, and creates a
project-scoped managed-identity Container Registry connection.

The developer running a remote build needs Container Registry Tasks
Contributor or an inherited broader role on the registry.

The agent and Gateway use separate Log Analytics workspaces and workspace-based
Application Insights components. Gateway payload capture is disabled. Each
platform boundary owns its telemetry.

## Environment variables

The azd environment contains deployment metadata. Do not distribute its
`.azure/<environment>/.env` file.

Create the smaller local development file with:

```bash
./scripts/create-dev-env.sh
```

or:

```powershell
pwsh ./scripts/create-dev-env.ps1
```

The scripts refuse to overwrite `.env` unless explicitly forced, restrict the
file to the current user, and do not print the Gateway key.

The local file contains:

```bash
AZURE_AI_GATEWAY_ENDPOINT="https://<gateway-host-name>/"
AZURE_AI_GATEWAY_API_KEY="<gateway-api-key>"
AZURE_AI_GATEWAY_MODEL="gpt-latest"
AZURE_AI_GATEWAY_MINI_MODEL="gpt-mini-latest"

TOOLBOX_ENDPOINT="https://<foundry-toolbox-endpoint>"
TOOLBOX_NAME="repo-digest-tools"

GITHUB_REPOSITORY="<owner>/<repository>"
```

For direct local execution, `main.py` disables only Microsoft OpenTelemetry SDK
self-telemetry when the Foundry hosting marker is absent. Hosted observability
remains enabled in Foundry.

## Validation

Run:

```bash
git diff --check
uv sync --frozen
uv run python -m compileall -q .
uv run python -m unittest discover -s tests
bash tests/test-apim-lifecycle.sh
bash tests/test-ai-gateway-model-registration.sh
az bicep build --file infra/foundry-agents/main.bicep
az bicep build --file infra/ai-gateway/main.bicep
az bicep build --file infra/foundry-models/main.bicep
az bicep build --file infra/main.bicep
docker build .
```
