"""Bound and compact GitHub MCP results for daily repository digests."""

import json
import logging
from collections.abc import Awaitable, Callable, Mapping, Sequence
from datetime import datetime, timedelta, timezone
from typing import Any

from agent_framework import Content, FunctionInvocationContext, function_middleware

logger = logging.getLogger(__name__)

GITHUB_MCP_TOOLS = {
    "github_actions_list",
    "github_list_pull_requests",
    "github_search_issues",
    "github_search_repositories",
}


def _source_tool_name(tool_name: str) -> str:
    return tool_name.rsplit("___", maxsplit=1)[-1]


def _select_fields(source: Mapping[str, Any], fields: Sequence[str]) -> dict[str, Any]:
    return {field: source[field] for field in fields if field in source}


def _login(value: Any) -> str | None:
    return value.get("login") if isinstance(value, Mapping) else None


def _label_names(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [
        name
        for label in value
        if isinstance(label, Mapping) and isinstance((name := label.get("name")), str)
    ]


def _is_recent(value: Any, cutoff: datetime) -> bool:
    if not isinstance(value, str):
        return True
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        logger.warning("Keeping GitHub item with an invalid timestamp: %s", value)
        return True
    return timestamp >= cutoff


def _normalize_github_arguments(
    tool_name: str,
    arguments: dict[str, Any],
    *,
    cutoff: datetime,
) -> None:
    if tool_name == "github_search_repositories":
        arguments.update(minimal_output=True, perPage=1, page=1)
        return

    if tool_name == "github_list_pull_requests":
        arguments.update(
            state="all",
            sort="updated",
            direction="desc",
            perPage=100,
            page=1,
        )
        return

    if tool_name == "github_search_issues":
        cutoff_text = cutoff.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        arguments.update(
            query=f"is:issue updated:>={cutoff_text}",
            sort="updated",
            order="desc",
            page=1,
        )
        return

    if tool_name == "github_actions_list":
        workflow_filter = arguments.get("workflow_runs_filter")
        normalized_filter = dict(workflow_filter) if isinstance(workflow_filter, Mapping) else {}
        normalized_filter["status"] = "completed"
        arguments.update(
            method="list_workflow_runs",
            workflow_runs_filter=normalized_filter,
            per_page=100,
            page=1,
        )


def _compact_repository(item: Mapping[str, Any]) -> dict[str, Any]:
    return _select_fields(
        item,
        (
            "full_name",
            "description",
            "html_url",
            "language",
            "stargazers_count",
            "forks_count",
            "open_issues_count",
            "updated_at",
            "default_branch",
            "archived",
        ),
    )


def _compact_pull_request(item: Mapping[str, Any]) -> dict[str, Any]:
    compact = _select_fields(
        item,
        ("number", "title", "state", "draft", "merged", "created_at", "updated_at", "html_url"),
    )
    compact["author"] = _login(item.get("user"))
    compact["labels"] = _label_names(item.get("labels"))
    return compact


def _compact_issue(item: Mapping[str, Any]) -> dict[str, Any]:
    compact = _select_fields(
        item,
        ("number", "title", "state", "state_reason", "comments", "created_at", "updated_at", "closed_at", "html_url"),
    )
    compact["author"] = _login(item.get("user"))
    compact["labels"] = _label_names(item.get("labels"))
    return compact


def _compact_workflow_run(item: Mapping[str, Any]) -> dict[str, Any]:
    compact = _select_fields(
        item,
        (
            "id",
            "name",
            "display_title",
            "event",
            "head_branch",
            "head_sha",
            "run_number",
            "run_attempt",
            "status",
            "conclusion",
            "created_at",
            "updated_at",
            "html_url",
        ),
    )
    compact["actor"] = _login(item.get("actor"))
    return compact


def _require_mapping_list(payload: Any, key: str | None = None) -> list[Mapping[str, Any]]:
    value = payload if key is None else payload.get(key) if isinstance(payload, Mapping) else None
    if not isinstance(value, list) or not all(isinstance(item, Mapping) for item in value):
        location = "root" if key is None else key
        raise ValueError(f"Expected a list of objects at {location}.")
    return value


def _compact_github_payload(
    tool_name: str,
    payload: Any,
    *,
    cutoff: datetime,
) -> dict[str, Any]:
    if tool_name == "github_search_repositories":
        items = _require_mapping_list(payload, "items")
        return {
            "total_count": payload.get("total_count"),
            "incomplete_results": payload.get("incomplete_results"),
            "items": [_compact_repository(item) for item in items],
        }

    if tool_name == "github_list_pull_requests":
        items = _require_mapping_list(payload)
        recent = [item for item in items if _is_recent(item.get("updated_at"), cutoff)]
        return {
            "returned_count": len(recent),
            "pull_requests": [_compact_pull_request(item) for item in recent],
        }

    if tool_name == "github_search_issues":
        items = _require_mapping_list(payload, "items")
        return {
            "total_count": payload.get("total_count"),
            "incomplete_results": payload.get("incomplete_results"),
            "items": [_compact_issue(item) for item in items],
        }

    if tool_name == "github_actions_list":
        items = _require_mapping_list(payload, "workflow_runs")
        failures = [
            item
            for item in items
            if item.get("conclusion") == "failure"
            and _is_recent(item.get("updated_at") or item.get("created_at"), cutoff)
        ]
        return {
            "returned_count": len(failures),
            "workflow_runs": [_compact_workflow_run(item) for item in failures],
        }

    raise ValueError(f"Unsupported GitHub MCP tool: {tool_name}")


def _compact_github_text(tool_name: str, text: str, *, cutoff: datetime) -> str:
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        logger.warning("Keeping non-JSON result from GitHub MCP tool %s.", tool_name)
        return text

    try:
        compact = _compact_github_payload(tool_name, payload, cutoff=cutoff)
    except ValueError as exc:
        logger.warning("Keeping unexpected result from GitHub MCP tool %s: %s", tool_name, exc)
        return text
    return json.dumps(compact, separators=(",", ":"), sort_keys=True)


@function_middleware
async def compact_github_results(
    context: FunctionInvocationContext,
    call_next: Callable[[], Awaitable[None]],
) -> None:
    tool_name = _source_tool_name(context.function.name)
    if tool_name not in GITHUB_MCP_TOOLS:
        await call_next()
        return

    cutoff = datetime.now(timezone.utc) - timedelta(days=1)
    if isinstance(context.arguments, dict):
        _normalize_github_arguments(tool_name, context.arguments, cutoff=cutoff)
    else:
        logger.warning(
            "Could not normalize arguments of type %s for GitHub MCP tool %s.",
            type(context.arguments).__name__,
            tool_name,
        )

    await call_next()
    if isinstance(context.result, str):
        context.result = _compact_github_text(tool_name, context.result, cutoff=cutoff)
        return

    if isinstance(context.result, list):
        for item in context.result:
            if isinstance(item, Content) and item.type == "text" and item.text is not None:
                item.text = _compact_github_text(tool_name, item.text, cutoff=cutoff)
        return

    logger.warning(
        "Keeping unsupported result type %s from GitHub MCP tool %s.",
        type(context.result).__name__,
        tool_name,
    )
