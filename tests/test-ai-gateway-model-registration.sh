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
  | select(.type == "Microsoft.ApiManagement/service/workspaces/modelProviders/models")
  | .properties.deployment.modelName
' "$compiled_template")"
expected="[last(split(parameters('foundryModels')[copyIndex()].resourceId, '/'))]"

if [ "$actual" != "$expected" ]; then
  echo "Gateway deployment.modelName must come from the Foundry deployment resource ID." >&2
  echo "Expected: $expected" >&2
  echo "Actual:   $actual" >&2
  exit 1
fi

actual_token_limit="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/service/workspaces/modelProviders/models")
  | .properties.policies
' "$compiled_template")"
expected_token_limit="coalesce(tryGet(parameters('foundryModels')[copyIndex()], 'tokenLimit'), 10000)"

if [[ "$actual_token_limit" != *"$expected_token_limit"* ]]; then
  echo "Gateway token limit must use the quota supplied for the Foundry deployment." >&2
  echo "Expected expression containing: $expected_token_limit" >&2
  echo "Actual:   $actual_token_limit" >&2
  exit 1
fi

expected_counter_key="'counterKey', createArray('identity')"

if [[ "$actual_token_limit" != *"$expected_counter_key"* ]]; then
  echo "Gateway token limit counterKey must use the current array contract." >&2
  echo "Expected expression containing: $expected_counter_key" >&2
  echo "Actual:   $actual_token_limit" >&2
  exit 1
fi

alias_properties="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/service/workspaces/aliases")
  | .properties
' "$compiled_template")"
expected_alias_name="last(split(parameters('foundryModels')[copyIndex()].resourceId, '/'))"
expected_backend_model="Microsoft.ApiManagement/service/workspaces/modelProviders/models"

if [[ "$alias_properties" != *"$expected_alias_name"* ]]; then
  echo "Gateway model alias must use the Foundry deployment name." >&2
  echo "Expected expression containing: $expected_alias_name" >&2
  echo "Actual: $alias_properties" >&2
  exit 1
fi

if [[ "$alias_properties" != *"$expected_backend_model"* ]]; then
  echo "Gateway model alias must target the registered provider model." >&2
  echo "Actual: $alias_properties" >&2
  exit 1
fi

az bicep build \
  --file "$repo_root/infra/main.bicep" \
  --outfile "$compiled_root_template" \
  >/dev/null

root_model_input="$(jq -r '
  .. | objects
  | select(has("foundryModels"))
  | .foundryModels.copy[0].input
  | select(. != null)
' "$compiled_root_template")"

if [[ "$root_model_input" != *"'tokenLimit', mul("*".capacity, 1000)"* ]]; then
  echo "Root deployment must derive each Gateway token limit from model capacity." >&2
  echo "Actual: $root_model_input" >&2
  exit 1
fi

mini_capacity="$(jq -r '.parameters.miniModelCapacity.defaultValue' "$compiled_root_template")"
if [ "$mini_capacity" != "200" ]; then
  echo "Mini deployment capacity must fit ghapp requests with built-in tool definitions." >&2
  echo "Expected: 200" >&2
  echo "Actual:   $mini_capacity" >&2
  exit 1
fi

echo "AI Gateway model registration test passed."
