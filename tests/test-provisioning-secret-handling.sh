#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash_script="$repo_root/infra/scripts/configure-ai-gateway.sh"
powershell_script="$repo_root/infra/scripts/configure-ai-gateway.ps1"
implementation_notes="$repo_root/IMPLEMENTATION_NOTES.md"

require_text() {
  local file="$1"
  local text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    echo "Expected $file to contain: $text" >&2
    exit 1
  fi
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    echo "Expected $file not to contain: $text" >&2
    exit 1
  fi
}

require_text "$powershell_script" 'function New-PrivateTempFile'
require_text "$powershell_script" '$tempFile = New-PrivateTempFile'
require_text "$powershell_script" '[IO.UnixFileMode]::UserRead'
require_text "$powershell_script" 'icacls.exe'
require_text "$powershell_script" 'azd env set --file $azdSecretFile'
reject_text "$powershell_script" 'azd env set AZURE_AI_GATEWAY_API_KEY'

require_text "$bash_script" 'umask 077'
require_text "$bash_script" '--config -'
require_text "$bash_script" 'azd env set --file "$azd_secret_file"'
reject_text "$bash_script" 'azd env set AZURE_AI_GATEWAY_API_KEY'
reject_text "$bash_script" '-H "Api-Key:'

require_text "$implementation_notes" 'custom credentials only'
require_text "$implementation_notes" 'trusted machine'

echo "Provisioning secret-handling tests passed."
