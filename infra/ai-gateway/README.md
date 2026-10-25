# AI Gateway provisioning

The subscription entry point, `../main.bicep`, deploys this module into the
gateway resource group after the Foundry project and model resources are ready.
This module creates the gateway and `apiKeys/default`, then deploys
`../foundry-agents/github-connection.bicep` into the agents resource group.

The `aigw-github` project connection uses
`Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview`,
category `RemoteTool`, authentication `CustomKeys`, and target
`https://<gateway-host>/default/mcp/github/mcp`. It is shared with the project
and has `metadata.type: custom_MCP`.

The gateway's `2025-09-01-preview` key is read with
`runtimeApiKey.listSecrets().key` and passed only through the connection
module's `@secure()` `gatewayApiKey` parameter. ARM waits for key creation
before evaluating the nested deployment. No deployment output contains the
secret. The deployment identity needs key-listing permission in the gateway
resource group and connection-write permission in the agents resource group.
Stable names and incremental deployment keep repeat provisioning idempotent.

The POSIX and PowerShell postprovision hooks no longer create the connection.
They still register the GitHub ToolServer using the local `GH_TOKEN` or GitHub
CLI credential, verify model-route readiness, save `AZURE_AI_GATEWAY_API_KEY`
to the local azd environment for development, and create the
`repo-digest-tools` Toolbox through the Foundry data-plane API.
`toolbox.yaml` references `project_connection_id: aigw-github`.
Failed-resource recovery remains in the lifecycle hooks.

Do not enable shell tracing or debug logging when handling keys. Local
environment files are private deployment state, not source configuration.

From the repository root, validate the compiled contract with:

```bash
bash tests/test-ai-gateway-model-registration.sh
bash tests/test-apim-lifecycle.sh
```

Live verification requires Azure credentials: run `azd up` on a fresh
environment, confirm Toolbox resolves `aigw-github`, and repeat `azd up` to
check idempotency. The focused tests verify generated ARM, not live preview
responses.
