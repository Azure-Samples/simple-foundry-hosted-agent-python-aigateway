import asyncio
import json
import unittest
from unittest.mock import patch
from datetime import datetime, timezone

from agent_framework import Content, FunctionInvocationContext

from github_mcp_middleware import (
    _compact_github_payload,
    _compact_github_text,
    _normalize_github_arguments,
    compact_github_results,
)


CUTOFF = datetime(2026, 7, 19, 16, 0, tzinfo=timezone.utc)


class CompactGitHubPayloadTests(unittest.TestCase):
    def test_normalizes_tool_arguments(self) -> None:
        cases = {
            "github_search_repositories": (
                {"minimal_output": False, "perPage": 100, "page": 8},
                {"minimal_output": True, "perPage": 1, "page": 1},
            ),
            "github_list_pull_requests": (
                {"state": "open", "page": 8},
                {
                    "state": "all",
                    "sort": "updated",
                    "direction": "desc",
                    "perPage": 100,
                    "page": 1,
                },
            ),
            "github_search_issues": (
                {"query": "updated:>=2025-01-01", "page": 8},
                {
                    "query": "is:issue updated:>=2026-07-19T16:00:00Z",
                    "sort": "updated",
                    "order": "desc",
                    "page": 1,
                },
            ),
            "github_actions_list": (
                {"method": "get_workflow_run", "workflow_runs_filter": {"branch": "main"}},
                {
                    "method": "list_workflow_runs",
                    "workflow_runs_filter": {"branch": "main", "status": "completed"},
                    "per_page": 100,
                    "page": 1,
                },
            ),
        }

        for tool_name, (arguments, expected) in cases.items():
            with self.subTest(tool_name=tool_name):
                _normalize_github_arguments(tool_name, arguments, cutoff=CUTOFF)
                self.assertEqual(arguments, expected)

    def test_compacts_repository_fields(self) -> None:
        payload = {
            "total_count": 1,
            "incomplete_results": False,
            "items": [
                {
                    "full_name": "microsoft/agent-framework",
                    "description": "Agents",
                    "html_url": "https://github.com/microsoft/agent-framework",
                    "stargazers_count": 100,
                    "default_branch": "main",
                    "owner": {"login": "microsoft"},
                }
            ],
        }

        compact = _compact_github_payload("github_search_repositories", payload, cutoff=CUTOFF)

        self.assertEqual(compact["items"][0]["full_name"], "microsoft/agent-framework")
        self.assertNotIn("owner", compact["items"][0])

    def test_filters_and_compacts_pull_requests(self) -> None:
        payload = [
            {
                "number": 2,
                "title": "Recent",
                "state": "open",
                "updated_at": "2026-07-20T12:00:00Z",
                "html_url": "https://github.com/microsoft/agent-framework/pull/2",
                "body": "large body",
                "user": {"login": "octocat"},
                "labels": [{"name": "bug"}],
            },
            {
                "number": 1,
                "title": "Old",
                "updated_at": "2026-07-18T12:00:00Z",
            },
        ]

        compact = _compact_github_payload("github_list_pull_requests", payload, cutoff=CUTOFF)

        self.assertEqual(compact["returned_count"], 1)
        self.assertEqual(compact["pull_requests"][0]["author"], "octocat")
        self.assertEqual(compact["pull_requests"][0]["labels"], ["bug"])
        self.assertNotIn("body", compact["pull_requests"][0])

    def test_compacts_issue_fields(self) -> None:
        payload = {
            "total_count": 1,
            "incomplete_results": False,
            "items": [
                {
                    "number": 3,
                    "title": "Issue",
                    "state": "open",
                    "updated_at": "2026-07-20T12:00:00Z",
                    "body": "large body",
                    "user": {"login": "octocat"},
                    "labels": [{"name": "help wanted"}],
                }
            ],
        }

        compact = _compact_github_payload("github_search_issues", payload, cutoff=CUTOFF)

        self.assertEqual(compact["items"][0]["author"], "octocat")
        self.assertEqual(compact["items"][0]["labels"], ["help wanted"])
        self.assertNotIn("body", compact["items"][0])

    def test_keeps_only_recent_failed_workflows(self) -> None:
        payload = {
            "workflow_runs": [
                {
                    "id": 3,
                    "name": "CI",
                    "conclusion": "failure",
                    "updated_at": "2026-07-20T12:00:00Z",
                    "html_url": "https://github.com/example/actions/runs/3",
                    "actor": {"login": "octocat"},
                    "head_commit": {"message": "large nested object"},
                },
                {
                    "id": 2,
                    "name": "CI",
                    "conclusion": "success",
                    "updated_at": "2026-07-20T12:00:00Z",
                },
                {
                    "id": 1,
                    "name": "CI",
                    "conclusion": "failure",
                    "updated_at": "2026-07-18T12:00:00Z",
                },
            ]
        }

        compact = _compact_github_payload("github_actions_list", payload, cutoff=CUTOFF)

        self.assertEqual(compact["returned_count"], 1)
        self.assertEqual(compact["workflow_runs"][0]["actor"], "octocat")
        self.assertNotIn("head_commit", compact["workflow_runs"][0])

    def test_preserves_non_json_tool_errors(self) -> None:
        text = "GitHub MCP returned an error"
        self.assertEqual(
            _compact_github_text("github_search_issues", text, cutoff=CUTOFF),
            text,
        )

    def test_middleware_preserves_content_metadata(self) -> None:
        content = Content.from_text(
            json.dumps(
                {
                    "total_count": 1,
                    "items": [{"number": 4, "title": "Issue", "body": "large body"}],
                }
            ),
            additional_properties={"_meta": {"ifc": "public"}},
        )
        context = FunctionInvocationContext(
            function=type(
                "Function",
                (),
                {"name": "aigw-github___github_search_issues"},
            )(),
            arguments={"query": "wrong", "page": 9},
        )

        async def call_next() -> None:
            context.result = [content]

        with patch(
            "github_mcp_middleware.datetime",
            wraps=datetime,
        ) as datetime_mock:
            datetime_mock.now.return_value = datetime(2026, 7, 20, 16, 0, tzinfo=timezone.utc)
            asyncio.run(compact_github_results(context, call_next))

        self.assertEqual(content.additional_properties["_meta"]["ifc"], "public")
        self.assertNotIn("large body", content.text or "")
        self.assertEqual(
            context.arguments["query"],
            "is:issue updated:>=2026-07-19T16:00:00Z",
        )
        self.assertEqual(context.arguments["page"], 1)


if __name__ == "__main__":
    unittest.main()
