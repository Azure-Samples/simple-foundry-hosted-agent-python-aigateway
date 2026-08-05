#!/usr/bin/env bash
set -euo pipefail

contract_file="${1:-.ai-gateway-studio.json}"

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [path-to-.ai-gateway-studio.json]" >&2
  exit 2
fi
if [ ! -f "$contract_file" ]; then
  echo "Existing AI Gateway handoff file not found: $contract_file" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required to validate $contract_file." >&2
  exit 1
fi
if ! command -v azd >/dev/null 2>&1; then
  echo "Azure Developer CLI is required to select the existing gateway profile." >&2
  exit 1
fi

IFS=$'\t' read -r \
  gateway_resource_id \
  gateway_endpoint \
  github_mcp_endpoint \
  gateway_model \
  gateway_mini_model < <(python3 - "$contract_file" <<'PY'
import json
import pathlib
import re
import sys
from urllib.parse import urlparse

path = pathlib.Path(sys.argv[1])
try:
    contract = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Invalid AI Gateway handoff file {path}: {exc}")

if contract.get("schemaVersion") != 1:
    raise SystemExit("schemaVersion must be 1.")
if contract.get("gatewayDeploymentMode") != "existing":
    raise SystemExit("gatewayDeploymentMode must be existing.")

resource_id = contract.get("gatewayResourceId", "")
resource_pattern = re.compile(
    r"^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/"
    r"Microsoft\.ApiManagement/(?:service|aigateways)/[^/]+$",
    re.IGNORECASE,
)
if not isinstance(resource_id, str) or not resource_pattern.fullmatch(resource_id):
    raise SystemExit(
        "gatewayResourceId must be a full Microsoft.ApiManagement/service "
        "or Microsoft.ApiManagement/aigateways ARM resource ID."
    )

def require_https_url(name: str, value: object) -> str:
    if not isinstance(value, str) or any(char in value for char in "\t\r\n"):
        raise SystemExit(f"{name} must be a single-line HTTPS URL.")
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit(f"{name} must be an absolute HTTPS URL.")
    return value

gateway_endpoint = require_https_url("gatewayEndpoint", contract.get("gatewayEndpoint"))
gateway_endpoint = gateway_endpoint.rstrip("/") + "/"
github_endpoint = require_https_url(
    "githubMcpEndpoint", contract.get("githubMcpEndpoint")
).rstrip("/")
if not re.search(r"/default/toolservers/[^/]+/mcp$", github_endpoint):
    raise SystemExit(
        "githubMcpEndpoint must end in /default/toolservers/<name>/mcp."
    )

aliases = contract.get("modelAliases")
if not isinstance(aliases, dict):
    raise SystemExit("modelAliases must be an object.")
models = []
for name in ("default", "mini"):
    value = aliases.get(name, "")
    if (
        not isinstance(value, str)
        or not value.strip()
        or any(char in value for char in "\t\r\n")
    ):
        raise SystemExit(f"modelAliases.{name} must be a nonempty single-line string.")
    models.append(value)

print("\t".join([resource_id, gateway_endpoint, github_endpoint, *models]))
PY
)

azd_set() {
  AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd env set "$1" "$2"
}

azd_set GATEWAY_DEPLOYMENT_MODE existing
azd_set EXISTING_AI_GATEWAY_RESOURCE_ID "$gateway_resource_id"
azd_set AZURE_AI_GATEWAY_ENDPOINT "$gateway_endpoint"
azd_set AZURE_AI_GATEWAY_GITHUB_MCP_ENDPOINT "$github_mcp_endpoint"
azd_set AZURE_AI_GATEWAY_MODEL "$gateway_model"
azd_set AZURE_AI_GATEWAY_MINI_MODEL "$gateway_mini_model"

echo "Selected the existing AI Gateway deployment profile from $contract_file."
echo "No Azure resources were provisioned or modified."
