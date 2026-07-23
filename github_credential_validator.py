"""Advisory check for the GitHub MCP credential used by the AI Gateway ToolServer.

This never blocks provisioning. It prints a warning when the selected GitHub
credential is broader than the recommended least-privilege token, so the
documented ``gh auth status; azd up`` flow keeps working while still nudging
operators toward a fine-grained, repository-scoped, read-only token.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections.abc import Mapping
from typing import Any

REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
LEAST_PRIVILEGE_TOKEN_PREFIXES = ("github_pat_", "ghs_")
WRITE_PERMISSIONS = ("admin", "maintain", "push", "triage")
REQUIRED_READ_ENDPOINTS = (
    ("repository contents", "contents"),
    ("repository issues", "issues?per_page=1"),
    ("repository pull requests", "pulls?per_page=1"),
    ("repository Actions runs", "actions/runs?per_page=1"),
)
LEAST_PRIVILEGE_FIX_DOC = (
    "IMPLEMENTATION_NOTES.md#tighten-the-github-credential-to-least-privilege"
)


def request_github_json(url: str, token: str) -> Any:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "foundry-ai-gateway-sample",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def evaluate_credential(repository: str, token: str) -> list[str]:
    """Return advisory warnings. An empty list means no concerns were found."""
    warnings: list[str] = []

    if not token.startswith(LEAST_PRIVILEGE_TOKEN_PREFIXES):
        warnings.append(
            "Using a broad, account-wide GitHub credential (OAuth or classic "
            "token). It works, but the postprovision hook stores it in the "
            "cloud AI Gateway ToolServer. For the least-privilege fix (GitHub "
            f"portal and command-line steps), open {LEAST_PRIVILEGE_FIX_DOC}"
        )
        return warnings

    repository_url = f"https://api.github.com/repos/{repository}"
    try:
        payload = request_github_json(repository_url, token)
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        warnings.append(
            f"Could not verify repository read access for {repository} ({exc}). "
            "Provisioning continues."
        )
        return warnings

    if isinstance(payload, Mapping):
        permissions = payload.get("permissions")
        if isinstance(permissions, Mapping):
            if permissions.get("pull") is not True:
                warnings.append(
                    f"The GitHub credential may not have read access to {repository}."
                )
            granted_write = [p for p in WRITE_PERMISSIONS if permissions.get(p) is True]
            if granted_write:
                warnings.append(
                    "The GitHub credential has write-capable repository "
                    "permissions (" + ", ".join(granted_write) + "). Prefer a "
                    f"read-only token; see {LEAST_PRIVILEGE_FIX_DOC}"
                )

    for description, path in REQUIRED_READ_ENDPOINTS:
        try:
            request_github_json(f"{repository_url}/{path}", token)
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            warnings.append(f"Could not verify {description} read access ({exc}).")

    return warnings


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: github_credential_validator.py owner/repository",
            file=sys.stderr,
        )
        return 2

    repository = sys.argv[1]
    if not REPOSITORY_PATTERN.fullmatch(repository):
        print("GITHUB_REPOSITORY must use the owner/repository format.", file=sys.stderr)
        return 1

    token = os.environ.get("GITHUB_MCP_TOKEN_TO_VALIDATE", "")
    if not token:
        print("GITHUB_MCP_TOKEN_TO_VALIDATE is required.", file=sys.stderr)
        return 1

    warnings = evaluate_credential(repository, token)
    for warning in warnings:
        print(f"Warning: {warning}", file=sys.stderr)

    if warnings:
        print(
            "Continuing with the selected GitHub credential. See the warnings "
            "above to tighten it to least privilege."
        )
    else:
        print(
            "GitHub MCP credential has the required read access and no coarse "
            "write role on the target repository."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
