#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiled_template="$(mktemp)"
compiled_root_template="$(mktemp)"
trap 'rm -f "$compiled_template" "$compiled_root_template"' EXIT

az bicep build \
  --file "$repo_root/infra/ai-gateway/main.bicep" \
  --outfile "$compiled_template" \
  >/dev/null

actual="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models")
  | .properties.deployment.modelName
' "$compiled_template")"
expected="[last(split(parameters('foundryModels')[copyIndex()].resourceId, '/'))]"

if [ "$actual" != "$expected" ]; then
  echo "Gateway deployment.modelName must come from the Foundry deployment resource ID." >&2
  echo "Expected: $expected" >&2
  echo "Actual:   $actual" >&2
  exit 1
fi

actual_model_policies="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models")
  | .properties.policies
' "$compiled_template")"
if [ "$actual_model_policies" != "null" ]; then
  echo "Gateway model PUTs must omit inline policies for the live RP contract." >&2
  echo "Actual: $actual_model_policies" >&2
  exit 1
fi

gateway_sku="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways")
  | .sku.name
' "$compiled_template")"
if [ "$gateway_sku" != "Consumption" ]; then
  echo "AI Gateway must use the live RP Consumption SKU." >&2
  echo "Actual: $gateway_sku" >&2
  exit 1
fi

actual_aliases="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways/workspaces/aliases")
  | .properties.copy[]
  | select(.name == "backendModels")
  | .input
' "$compiled_template")"
for token in \
  "parameters('modelAliasesConfig')" \
  "Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models" \
  "priority" \
  "weight"; do
  if ! grep -Fq "$token" <<< "$actual_aliases"; then
    echo "Gateway aliases must reference gateway child models and preserve explicit priority and weight routing." >&2
    echo "Missing: $token" >&2
    echo "Actual: $actual_aliases" >&2
    exit 1
  fi
done

alias_has_selection_order="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways/workspaces/aliases")
  | .properties | has("selectionOrder")
' "$compiled_template")"
if [ "$alias_has_selection_order" != "false" ]; then
  echo "Live alias PUTs must omit selectionOrder." >&2
  exit 1
fi

az bicep build \
  --file "$repo_root/infra/main.bicep" \
  --outfile "$compiled_root_template" \
  >/dev/null

root_alias_input="$(jq -r '
  .. | objects
  | select(has("modelAliasesConfig"))
  | .modelAliasesConfig.value
  | select(. != null)
' "$compiled_root_template")"

if [[ "$root_alias_input" != *"modelArmName"* ||
  "$root_alias_input" != *"priority"* ||
  "$root_alias_input" != *"weight"* ||
  "$root_alias_input" != *"primary-router"* ]]; then
  echo "Root deployment must create a multi-model alias with explicit priority and weight routes." >&2
  echo "Actual: $root_alias_input" >&2
  exit 1
fi

default_alias_routes="$(jq -r '.variables.effectiveModelAliasBackends' "$compiled_root_template")"
for token in \
  "parameters('modelDeploymentName')" \
  "parameters('miniModelDeploymentName')" \
  "'priority', 0" \
  "'priority', 1" \
  "'weight', 100"; do
  if ! grep -Fq "$token" <<< "$default_alias_routes"; then
    echo "Default alias routes must configure primary/failover priority and explicit weight." >&2
    echo "Missing: $token" >&2
    echo "Actual: $default_alias_routes" >&2
    exit 1
  fi
done

root_model_input="$(jq -r '
  .. | objects
  | select(has("foundryModels"))
  | .foundryModels.copy[0].input
  | select(. != null)
' "$compiled_root_template")"
for token in \
  "OpenAIChatCompletions" \
  "/openai/v1/chat/completions" \
  "/openai/v1/responses"; do
  if ! grep -Fq "$token" <<< "$root_model_input"; then
    echo "Root model registrations must use the live RP API format and endpoint paths." >&2
    echo "Missing: $token" >&2
    echo "Actual: $root_model_input" >&2
    exit 1
  fi
done

mini_capacity="$(jq -r '.parameters.miniModelCapacity.defaultValue' "$compiled_root_template")"
if [ "$mini_capacity" != "200" ]; then
  echo "Mini deployment capacity must fit ghapp requests with built-in tool definitions." >&2
  echo "Expected: 200" >&2
  echo "Actual:   $mini_capacity" >&2
  exit 1
fi

if ! jq -e '
  .resources[]
  | select(.type == "Microsoft.Resources/deployments" and .properties.parameters.gatewayApiKey != null)
  | . as $module
  | .properties.template as $template
  | .properties.parameters.gatewayApiKey.value as $key
  | ($module.resourceGroup == "[parameters('\''foundryAgentsResourceGroupName'\'')]")
    and ($module.properties.mode == "Incremental")
    and ($module.condition | contains("deployApimGatewayViaBicep") and contains("foundryAgentsProjectName"))
    and ($template.parameters.gatewayApiKey.type == "securestring")
    and ($key == "[listSecrets(resourceId('\''Microsoft.ApiManagement/aigateways/apiKeys'\'', parameters('\''gatewayName'\''), '\''default'\''), '\''2025-09-01-preview'\'').key]")
    and ($module.dependsOn | any(contains("Microsoft.ApiManagement/aigateways/apiKeys")))
    and ($template.resources | length == 1)
    and ($template.resources[0] |
      .type == "Microsoft.CognitiveServices/accounts/projects/connections"
      and .apiVersion == "2025-04-01-preview"
      and (.name | contains("aigw-github"))
      and .properties.category == "RemoteTool"
      and .properties.authType == "CustomKeys"
      and .properties.target == "[format('\''{0}/default/mcp/github/mcp'\'', variables('\''normalizedGatewayUrl'\''))]"
      and .properties.credentials.keys["Api-Key"] == "[parameters('\''gatewayApiKey'\'')]"
      and .properties.isSharedToAll == true
      and .properties.metadata.type == "custom_MCP")
' "$compiled_template" >/dev/null; then
  echo "GitHub connection must use a secure key parameter, the MCP route, and depend on the generated key." >&2
  exit 1
fi

if ! jq -e '
  .resources[]
  | select(.properties.parameters.foundryAgentsProjectName != null)
  | (.properties.parameters.foundryAgentsResourceGroupName.value == "[variables('\''effectiveFoundryAgentsResourceGroupName'\'')]")
    and (.properties.parameters.foundryAgentsAccountName.value | contains("outputs.aiServicesName.value"))
    and (.properties.parameters.foundryAgentsProjectName.value | contains("outputs.aiProjectName.value"))
    and (.dependsOn | any(contains("foundry-agents-")))
' "$compiled_root_template" >/dev/null; then
  echo "Gateway connection provisioning must wait for the Foundry agents project in its own resource group." >&2
  exit 1
fi

if ! jq -e '
  [.. | objects | .outputs? // {} | to_entries[]
   | select((.value.value | tostring | test("listSecrets|listValues|parameters\\('\''gatewayApiKey'\''\\)"))
            or (.key | test("(?i)^(gatewayApiKey|AI_GATEWAY_API_KEY|AZURE_AI_GATEWAY_API_KEY)$")))]
  | length == 0
' "$compiled_root_template" >/dev/null; then
  echo "Gateway API key values must never be emitted in deployment outputs." >&2
  exit 1
fi

for hook in "$repo_root/infra/scripts/configure-ai-gateway.sh" "$repo_root/infra/scripts/configure-ai-gateway.ps1"; do
  if grep -Eq 'azd[[:space:]]+ai[[:space:]]+connection[[:space:]]+create|--custom-key' "$hook"; then
    echo "Postprovision must not create the Bicep-owned connection or pass its key to a connection command." >&2
    exit 1
  fi
  for token in \
    '/apiKeys/default/listSecrets?' \
    '--query "key || primaryKey' \
    'azd env set AZURE_AI_GATEWAY_API_KEY' \
    'toolServers/github' \
    'GH_TOKEN' \
    'azd ai toolbox show' \
    'azd ai toolbox create'; do
    if ! grep -Fq -- "$token" "$hook"; then
      echo "Postprovision must preserve local key retrieval, GitHub registration, and Toolbox setup: $token" >&2
      exit 1
    fi
  done
done

if ! grep -Fq 'project_connection_id: aigw-github' "$repo_root/toolbox.yaml"; then
  echo "Toolbox must attach the Bicep-provisioned aigw-github connection." >&2
  exit 1
fi

echo "AI Gateway model registration test passed."
