# AI Gateway

Run the commands in this README from the `infra/ai-gateway/` directory.

[`main.bicep`](main.bicep) is a resource-group-scoped module for an AI Gateway
with Consumption SKU. With the default `deployApimGatewayViaBicep: true`, it
creates `Microsoft.ApiManagement/aigateways`, the
`Microsoft.Web/connectorGateways` Connector Namespace, and `apiKeys/default`.
When monitoring is enabled, it also provisions Log Analytics, Application
Insights, and the Gateway telemetry exporter.

When `deployFoundryProvider` is enabled, the module assigns the Gateway identity
the Foundry User role on each account in `foundryResourceIds`, registers the
supplied `foundryModels` under `modelProviders/foundry`, and creates the
configured aliases. The sample routes `gpt-latest` through three tiers:
`gpt-6.1-sol` → `gpt-6-sol` → `gpt-5.4-mini` (priorities 0, 1, and 2,
respectively, with weight 100 each). `gpt-mini-latest` targets the mini model
directly.

## Default Gateway policies

Each registered model receives a per-caller `tokenLimit` of 1,000 times its
deployment capacity per minute. With the sample capacities, `gpt-latest` and
`gpt-6-sol` allow 20,000 tokens per minute, while `gpt-mini-latest` allows
200,000. Each model also receives a `$10.00/month` `costLimit` per caller
identity (`id: monthly-caller-budget`) and `Medium` `contentSafety` thresholds
for Hate, Self-Harm, Sexual, and Violence. The postprovision configuration adds
the same `Medium` content-safety thresholds to the `toolServers/github` MCP
server. The `gpt-latest` alias routes through `gpt-6.1-sol` (priority 0),
`gpt-6-sol` (priority 1), and `gpt-5.4-mini` (priority 2).

## Gateway without a Foundry provider

Create a resource group, then deploy just the Gateway and Connector Namespace.
This minimal mode leaves `deployFoundryProvider` disabled, so it does not
register model catalog entries or aliases:

```bash
az group create --name rg-ai-gateway --location eastus2

az deployment group create \
  --resource-group rg-ai-gateway \
  --template-file ./main.bicep \
  --parameters location=eastus2 gatewayName=aigw-example
```

## Connect an existing Foundry model account

The existing account must already contain deployments named `gpt-latest`,
`gpt-6-sol`, and `gpt-mini-latest` (or update the model names below to match its
deployments). The following example gets the account ID and endpoint, creates a
parameters file, and deploys the Gateway with registrations and aliases. The
operator needs permission to create the Gateway and assign its identity the
Foundry User role on the account.

```bash
FOUNDRY_RESOURCE_GROUP=rg-foundry-models
FOUNDRY_ACCOUNT_NAME=aimodels-example
FOUNDRY_ACCOUNT_ID="$(az cognitiveservices account show \
  --resource-group "$FOUNDRY_RESOURCE_GROUP" \
  --name "$FOUNDRY_ACCOUNT_NAME" \
  --query id --output tsv)"
FOUNDRY_ENDPOINT="$(az cognitiveservices account show \
  --resource-group "$FOUNDRY_RESOURCE_GROUP" \
  --name "$FOUNDRY_ACCOUNT_NAME" \
  --query properties.endpoint --output tsv)"

az group create --name rg-ai-gateway --location eastus2

cat > /tmp/ai-gateway.parameters.json <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": {"value": "eastus2"},
    "gatewayName": {"value": "aigw-example"},
    "enableMonitoring": {"value": true},
    "appInsightsName": {"value": "aigw-example-insights"},
    "logAnalyticsWorkspaceName": {"value": "aigw-example-logs"},
    "deployFoundryProvider": {"value": true},
    "foundryEndpoint": {"value": "$FOUNDRY_ENDPOINT"},
    "foundryResourceIds": {"value": ["$FOUNDRY_ACCOUNT_ID"]},
    "foundryModels": {"value": [
      {
        "armName": "gpt-latest",
        "modelName": "gpt-6.1-sol",
        "modelVersion": "2026-09-29",
        "apiFormat": "OpenAIChatCompletions",
        "supportedEndpoints": ["/openai/v1/chat/completions", "/openai/v1/responses"],
        "resourceId": "$FOUNDRY_ACCOUNT_ID/deployments/gpt-latest"
      },
      {
        "armName": "gpt-6-sol",
        "modelName": "gpt-6-sol",
        "modelVersion": "2026-09-22",
        "apiFormat": "OpenAIChatCompletions",
        "supportedEndpoints": ["/openai/v1/chat/completions", "/openai/v1/responses"],
        "resourceId": "$FOUNDRY_ACCOUNT_ID/deployments/gpt-6-sol"
      },
      {
        "armName": "gpt-mini-latest",
        "modelName": "gpt-5.4-mini",
        "modelVersion": "2026-03-17",
        "apiFormat": "OpenAIChatCompletions",
        "supportedEndpoints": ["/openai/v1/chat/completions", "/openai/v1/responses"],
        "resourceId": "$FOUNDRY_ACCOUNT_ID/deployments/gpt-mini-latest"
      }
    ]},
    "modelAliasesConfig": {"value": [
      {
        "armName": "primary-router",
        "aliasName": "gpt-latest",
        "description": "Three-tier GPT model failover.",
        "backendModels": [
          {"modelArmName": "gpt-latest", "priority": 0, "weight": 100},
          {"modelArmName": "gpt-6-sol", "priority": 1, "weight": 100},
          {"modelArmName": "gpt-mini-latest", "priority": 2, "weight": 100}
        ]
      },
      {
        "armName": "mini-router",
        "aliasName": "gpt-mini-latest",
        "description": "Direct alias for the mini deployment.",
        "backendModels": [
          {"modelArmName": "gpt-mini-latest", "priority": 0, "weight": 100}
        ]
      }
    ]}
  }
}
EOF

az deployment group create \
  --resource-group rg-ai-gateway \
  --template-file ./main.bicep \
  --parameters @/tmp/ai-gateway.parameters.json
```

After the Gateway and Foundry project exist, run the postprovision configuration
script to add the GitHub MCP ToolServer and create the Foundry project
connection and `repo-digest-tools` Toolbox:

```bash
bash ../scripts/configure-ai-gateway.sh
```

See [the scripts README](../scripts/README.md) for required azd values and
GitHub authentication. A standalone Gateway deployment does not create the
Foundry project; deploy the
[Foundry agents module](../foundry-agents/README.md) as well before configuring
the Toolbox.
