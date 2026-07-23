"""Validate the GitHub MCP credential type and required repository access."""

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
ALLOWED_TOKEN_PREFIXES = ("github_pat_", "ghs_")
WRITE_PERMISSIONS = ("admin", "maintain", "push", "triage")
REQUIRED_READ_ENDPOINTS = (
    ("repository contents", "contents"),
    ("repository issues", "issues?per_page=1"),
    ("repository pull requests", "pulls?per_page=1"),
    ("repository Actions runs", "actions/runs?per_page=1"),
)


def validate_repository(repository: str) -> None:
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise ValueError("GITHUB_REPOSITORY must use the owner/repository format.")


def validate_token_type(token: str) -> None:
    if not token.startswith(ALLOWED_TOKEN_PREFIXES):
        raise ValueError(
            "Use a fine-grained personal access token or GitHub App "
            "installation token. Classic PAT and OAuth tokens are rejected."
        )


def validate_credential_metadata(
    repository_payload: Mapping[str, Any],
) -> None:
    permissions = repository_payload.get("permissions")
    if not isinstance(permissions, Mapping):
        raise ValueError("GitHub did not return repository permission details.")
    if permissions.get("pull") is not True:
        raise ValueError("The GitHub credential does not have repository read access.")

    granted_write_permissions = [
        permission for permission in WRITE_PERMISSIONS if permissions.get(permission) is True
    ]
    if granted_write_permissions:
        raise ValueError(
            "The GitHub credential has write-capable repository permissions: "
            + ", ".join(granted_write_permissions)
            + "."
        )


def request_github_json(url: str, token: str, description: str) -> Any:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "foundry-ai-gateway-sample",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"GitHub returned an unexpected {description} response."
        ) from exc
    except urllib.error.HTTPError as exc:
        raise ValueError(
            f"GitHub could not verify {description} read access (HTTP {exc.code})."
        ) from exc
    except urllib.error.URLError as exc:
        raise ValueError(
            f"GitHub could not verify {description} read access."
        ) from exc


def validate_credential(repository: str, token: str) -> None:
    validate_repository(repository)
    validate_token_type(token)
    repository_url = f"https://api.github.com/repos/{repository}"
    payload = request_github_json(repository_url, token, "repository metadata")

    if not isinstance(payload, Mapping):
        raise ValueError("GitHub returned an unexpected repository response.")
    validate_credential_metadata(payload)

    for description, path in REQUIRED_READ_ENDPOINTS:
        request_github_json(f"{repository_url}/{path}", token, description)


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: github_credential_validator.py owner/repository",
            file=sys.stderr,
        )
        return 2

    token = os.environ.get("GITHUB_MCP_TOKEN_TO_VALIDATE", "")
    if not token:
        print("GITHUB_MCP_TOKEN_TO_VALIDATE is required.", file=sys.stderr)
        return 2

    try:
        validate_credential(sys.argv[1], token)
    except ValueError as exc:
        print(f"GitHub MCP credential rejected: {exc}", file=sys.stderr)
        return 1

    print(
        "GitHub MCP credential has the required read access "
        "and no coarse write role on the target repository."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
