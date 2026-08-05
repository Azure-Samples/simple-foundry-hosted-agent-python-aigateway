#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiled_template="$(mktemp)"
temp_root="$(mktemp -d)"
trap 'rm -f "$compiled_template"; rm -rf "$temp_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

az bicep build \
  --file "$repo_root/infra/main.bicep" \
  --outfile "$compiled_template" \
  >/dev/null

[ "$(jq -r '.parameters.gatewayDeploymentMode.defaultValue' "$compiled_template")" = "managed" ] ||
  fail "managed must remain the default deployment mode"
[ "$(jq -c '.parameters.gatewayDeploymentMode.allowedValues' "$compiled_template")" = '["managed","existing"]' ] ||
  fail "deployment mode must allow exactly managed and existing"

for resource_name in \
  "effectiveGatewayResourceGroupName" \
  "effectiveFoundryModelsResourceGroupName" \
  "foundry-models-" \
  "ai-gateway-"; do
  condition="$(jq -r --arg name "$resource_name" '
    .resources[]
    | select((.name | tostring) | contains($name))
    | .condition
  ' "$compiled_template")"
  [ "$condition" = "[variables('deployManagedGateway')]" ] ||
    fail "$resource_name must be disabled in existing mode, found condition: $condition"
done

for module_name in "foundry-models-" "ai-gateway-"; do
  module_scope="$(jq -r --arg name "$module_name" '
    .resources[]
    | select((.name | tostring) | contains($name))
    | .resourceGroup // ""
  ' "$compiled_template")"
  [ -n "$module_scope" ] ||
    fail "$module_name must remain scoped to its managed resource group"
done

agent_module_condition="$(jq -r '
  .resources[]
  | select((.name | tostring) | contains("foundry-agents-"))
  | .condition // ""
' "$compiled_template")"
[ -z "$agent_module_condition" ] ||
  fail "Foundry hosted-agent resources must be deployed in both modes"

assert_contains "$repo_root/azure.yaml" 'category: CustomKeys'
assert_contains "$repo_root/azure.yaml" 'value: ${{connections.ai-gateway-model.target}}'
assert_contains "$repo_root/azure.yaml" 'value: ${{connections.ai-gateway-model.credentials.Api-Key}}'
if grep -Fq 'value: ${AZURE_AI_GATEWAY_API_KEY}' "$repo_root/azure.yaml"; then
  fail "Gateway keys must not use ordinary hosted-agent azd environment substitution"
fi

python3 - "$repo_root/infra/scripts/manage-ai-gateway-lifecycle.ps1" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected = """    return ""
}

$gatewayDeploymentMode = First-Value"""
if expected not in text:
    raise SystemExit(
        "PowerShell existing-mode guard must be at top level after First-Value."
    )
PY

stub_bin="$temp_root/bin"
mkdir -p "$stub_bin"
az_log="$temp_root/az.log"
azd_log="$temp_root/azd.log"

cat > "$stub_bin/az" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_AZ_LOG:?}"
if [ "${1:-}" != "rest" ]; then
  echo "unexpected az command: $*" >&2
  exit 2
fi
uri=""
query=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --uri) uri="$2"; shift 2 ;;
    --query) query="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$uri" in
  *"/apiKeys?"*)
    printf '%s\n' "default"
    ;;
  *"/apiKeys/default/listSecrets?"*)
    printf '%s\n' "test-gateway-key"
    ;;
  *)
    echo "unexpected az rest URI: $uri (query: $query)" >&2
    exit 2
    ;;
esac
STUB

cat > "$stub_bin/azd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_AZD_LOG:?}"
if [ "${1:-}" = "env" ] && [ "${2:-}" = "get-value" ]; then
  exit 1
fi
if [ "${1:-}" = "env" ] && [ "${2:-}" = "set" ]; then
  exit 0
fi
if [ "${1:-}" = "ai" ] && [ "${2:-}" = "connection" ] && [ "${3:-}" = "create" ]; then
  exit 0
fi
if [ "${1:-}" = "ai" ] && [ "${2:-}" = "toolbox" ] && [ "${3:-}" = "show" ]; then
  printf '%s\n' '{"name":"repo-digest-tools"}'
  exit 0
fi
echo "unexpected azd command: $*" >&2
exit 2
STUB

cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
output_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output_file="$2"; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
[ -z "$output_file" ] || printf '%s' '{}' > "$output_file"
printf '%s' '200'
STUB

chmod +x "$stub_bin/az" "$stub_bin/azd" "$stub_bin/curl"

gateway_resource_id="/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/shared-gateway/providers/Microsoft.ApiManagement/service/shared-aigw"
gateway_endpoint="https://shared.example.ai.gateway-current.azure.com/"
github_mcp_endpoint="${gateway_endpoint}default/toolservers/github/mcp"

env \
  PATH="$stub_bin:$PATH" \
  STUB_AZ_LOG="$az_log" \
  STUB_AZD_LOG="$azd_log" \
  GATEWAY_DEPLOYMENT_MODE=existing \
  AZURE_ENV_NAME=test-existing \
  EXISTING_AI_GATEWAY_RESOURCE_ID="$gateway_resource_id" \
  AZURE_AI_GATEWAY_ENDPOINT="$gateway_endpoint" \
  AZURE_AI_GATEWAY_GITHUB_MCP_ENDPOINT="$github_mcp_endpoint" \
  AZURE_AI_GATEWAY_MODEL=gpt-shared \
  AZURE_AI_GATEWAY_MINI_MODEL=gpt-shared-mini \
  FOUNDRY_PROJECT_ENDPOINT=https://foundry.example.com/api/projects/sample \
  "$repo_root/infra/scripts/configure-ai-gateway.sh" \
  >"$temp_root/configure.out"

if grep -Eiq '(^|[[:space:]])(put|delete)([[:space:]]|$)|deletedservices|toolServers/github|modelProviders' "$az_log"; then
  fail "existing mode attempted to mutate or manage the existing Gateway: $(cat "$az_log")"
fi
assert_contains "$azd_log" "ai connection create aigw-github"
assert_contains "$azd_log" "--target $github_mcp_endpoint"
assert_contains "$azd_log" "env set TOOLBOX_ENDPOINT https://foundry.example.com/api/projects/sample/toolboxes/repo-digest-tools/mcp?api-version=v1"

: > "$azd_log"
env \
  PATH="$stub_bin:$PATH" \
  STUB_AZD_LOG="$azd_log" \
  "$repo_root/scripts/configure-existing-gateway.sh" \
  "$repo_root/.ai-gateway-studio.example.json" \
  >"$temp_root/bootstrap.out"

assert_contains "$azd_log" "env set GATEWAY_DEPLOYMENT_MODE existing"
assert_contains "$azd_log" "env set EXISTING_AI_GATEWAY_RESOURCE_ID"
assert_contains "$azd_log" "env set AZURE_AI_GATEWAY_GITHUB_MCP_ENDPOINT"
assert_contains "$temp_root/bootstrap.out" "No Azure resources were provisioned or modified."

echo "Deployment mode tests passed."
