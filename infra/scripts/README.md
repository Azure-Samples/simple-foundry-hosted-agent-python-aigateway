# Infrastructure scripts

The scripts provide azd lifecycle hooks for safely recovering the AI Gateway
and finishing setup that requires a local GitHub credential. `azure.yaml`
invokes the matching PowerShell scripts on Windows and Bash scripts on POSIX.
Run commands below from the repository root.

## Gateway lifecycle

[`manage-ai-gateway-lifecycle.sh`](manage-ai-gateway-lifecycle.sh) and
[`manage-ai-gateway-lifecycle.ps1`](manage-ai-gateway-lifecycle.ps1) have two
modes:

- `prepare` is used before provisioning. It only recovers an environment-owned
  AI Gateway in a terminal failed state and waits for its managed-identity
  cleanup.
- `cleanup` completes an explicit teardown/recovery operation and waits for the
  Gateway resource and identity cleanup. The azd `postdown` hook invokes this
  after `azd down`.

Standalone usage:

```bash
bash ./infra/scripts/manage-ai-gateway-lifecycle.sh prepare
bash ./infra/scripts/manage-ai-gateway-lifecycle.sh cleanup
```

On Windows, use `./infra/scripts/manage-ai-gateway-lifecycle.ps1 prepare` or
`cleanup`. Polling intervals and the overall bound can be adjusted with
`APIM_LIFECYCLE_POLL_INITIAL_SECONDS`,
`APIM_LIFECYCLE_POLL_MAX_SECONDS`,
`APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS`, and
`APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS`.

## Postprovision Gateway configuration

[`configure-ai-gateway.sh`](configure-ai-gateway.sh) and
[`configure-ai-gateway.ps1`](configure-ai-gateway.ps1) have two uses:

- The `--prepare-bicep` mode runs lifecycle `prepare` and prepares the Gateway
  role assignment before Bicep provisioning. `azure.yaml` calls this from its
  preprovision hook.
- The default mode runs after provisioning. It retrieves `apiKeys/default`,
  registers the read-only GitHub MCP endpoint as the Gateway
  `toolServers/github`, creates the `aigw-github` project connection, and creates
  the Foundry Toolbox `repo-digest-tools`.

`azd provision` runs these hooks automatically. To run the postprovision step
manually after deploying the resources:

```bash
bash ./infra/scripts/configure-ai-gateway.sh
```

Use `./infra/scripts/configure-ai-gateway.ps1` on Windows. The configuration
step needs Azure CLI and azd access to the deployment, a GitHub CLI login
(`gh auth login`) or `GH_TOKEN`, and the provisioned Gateway, Foundry project,
and endpoint settings in the azd environment. The script verifies the Gateway
model route before saving the runtime key and creating the Toolbox connection.
It does not print or store the GitHub credential in Bicep outputs.

