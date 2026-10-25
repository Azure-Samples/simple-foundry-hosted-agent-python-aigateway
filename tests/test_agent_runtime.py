from __future__ import annotations

import asyncio
import json
import os
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import httpx
import mcp
from agent_framework import Agent, FunctionInvocationContext
from agent_framework._tools import _validate_arguments_against_schema
from agent_framework.openai import OpenAIChatClient
from agent_framework_foundry_hosting import FoundryToolbox, ResponsesHostServer
from azure.ai.agentserver.responses import InMemoryResponseProvider
from mcp import types
from mcp.client.subscriptions import ListenNotSupportedError
from openai import AsyncOpenAI, Omit

from github_mcp_middleware import compact_github_results
import main
import repo_digest_agent


class AgentConstructionTests(unittest.TestCase):
    def test_build_agent_uses_configured_client_and_toolbox(self) -> None:
        client = OpenAIChatClient(model="gpt-latest", api_key="test-key")
        toolbox = FoundryToolbox(
            object(),
            url="http://localhost/toolbox",
            name="repo-digest-tools",
        )
        try:
            with (
                patch.object(repo_digest_agent, "_gateway_client", return_value=client),
                patch.object(repo_digest_agent, "_github_toolbox", return_value=toolbox),
            ):
                agent = repo_digest_agent.build_agent()

            self.assertIsInstance(agent, Agent)
            self.assertIs(agent.client, client)
            self.assertEqual(agent.default_options["store"], False)
            self.assertEqual(agent.default_options["max_tokens"], 2_048)
            self.assertIsInstance(agent.default_options["extra_headers"]["Authorization"], Omit)
            self.assertIn(toolbox, agent.mcp_tools)
        finally:
            asyncio.run(toolbox.close())

    def test_host_server_receives_agent_factory_and_history_source(self) -> None:
        server = Mock()
        with patch.object(main, "ResponsesHostServer", return_value=server) as host_server:
            main.main()

        host_server.assert_called_once_with(agent=main.build_runtime_agent, history_source="agent_server")
        server.run.assert_called_once_with()

    def test_build_runtime_agent_reloads_dotenv_locally(self) -> None:
        sentinel = object()
        with (
            patch.dict(os.environ, {}, clear=False),
            patch.object(main, "load_dotenv") as reload_dotenv,
            patch.object(main, "build_agent", return_value=sentinel) as build_agent,
        ):
            os.environ.pop("FOUNDRY_HOSTING_ENVIRONMENT", None)
            result = main.build_runtime_agent()

        self.assertIs(result, sentinel)
        reload_dotenv.assert_called_once_with(override=True)
        build_agent.assert_called_once_with()


class _UnsupportedListen:
    async def __aenter__(self) -> None:
        raise ListenNotSupportedError(None)

    async def __aexit__(self, *args: object) -> None:
        return None


class _FakeMCPClient:
    protocol_version = "2025-03-26"
    server_capabilities = types.ServerCapabilities(tools=types.ToolsCapability(listChanged=True))
    session = SimpleNamespace(initialize_result=None)

    def __init__(self) -> None:
        self.listen_calls = 0

    async def __aenter__(self) -> _FakeMCPClient:
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    def listen(self, **kwargs: object) -> _UnsupportedListen:
        self.listen_calls += 1
        return _UnsupportedListen()

    async def list_tools(self, *, cursor: str | None = None) -> types.ListToolsResult:
        return types.ListToolsResult(tools=[])


class FoundryToolboxConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def test_connect_loads_subscription_recovery_dependency(self) -> None:
        mcp_client = _FakeMCPClient()
        toolbox = FoundryToolbox(
            object(),
            url="http://localhost/toolbox",
            name="repo-digest-tools",
        )
        try:
            with patch.object(mcp, "Client", return_value=mcp_client):
                await toolbox.connect()

            self.assertTrue(toolbox.is_connected)
            self.assertEqual(mcp_client.listen_calls, 1)
        finally:
            await toolbox.close()


class GitHubActionsSchemaTests(unittest.IsolatedAsyncioTestCase):
    async def test_workflow_arguments_match_the_mcp_per_page_schema(self) -> None:
        mcp_tool = types.Tool(
            name="github_actions_list",
            inputSchema={
                "type": "object",
                "properties": {
                    "method": {"type": "string"},
                    "workflow_runs_filter": {"type": "object"},
                    "perPage": {"type": "integer"},
                    "page": {"type": "integer"},
                },
                "required": ["method"],
                "additionalProperties": False,
            },
        )
        context = FunctionInvocationContext(
            function=SimpleNamespace(name="aigw-github___github_actions_list"),
            arguments={
                "method": "get_workflow_run",
                "workflow_runs_filter": {"branch": "main"},
                "per_page": 25,
            },
        )

        async def validate_with_mcp_schema() -> None:
            context.arguments = _validate_arguments_against_schema(
                arguments=context.arguments,
                schema=mcp_tool.input_schema,
                tool_name=mcp_tool.name,
            )
            context.result = json.dumps({"workflow_runs": []})

        await compact_github_results(context, validate_with_mcp_schema)

        self.assertEqual(context.arguments["perPage"], 100)
        self.assertNotIn("per_page", context.arguments)
        self.assertEqual(context.arguments["method"], "list_workflow_runs")


class ResponsesHostingTests(unittest.IsolatedAsyncioTestCase):
    async def test_stored_streaming_and_unstored_non_streaming_requests(self) -> None:
        model_requests: list[tuple[dict[str, object], httpx.Headers]] = []
        message = {
            "id": "msg_1",
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": "Hello", "annotations": []}],
        }
        completed_response = {
            "id": "resp_1",
            "object": "response",
            "created_at": 0,
            "model": "gpt-latest",
            "status": "completed",
            "output": [message],
            "parallel_tool_calls": True,
            "tool_choice": "auto",
            "tools": [],
        }
        events = [
            {
                "type": "response.created",
                "response": {**completed_response, "status": "in_progress", "output": []},
            },
            {
                "type": "response.in_progress",
                "response": {**completed_response, "status": "in_progress", "output": []},
            },
            {
                "type": "response.output_item.added",
                "output_index": 0,
                "item": {**message, "status": "in_progress"},
            },
            {
                "type": "response.content_part.added",
                "output_index": 0,
                "item_id": "msg_1",
                "content_index": 0,
                "part": {"type": "output_text", "text": "", "annotations": []},
            },
            {
                "type": "response.output_text.delta",
                "output_index": 0,
                "item_id": "msg_1",
                "content_index": 0,
                "delta": "Hello",
            },
            {
                "type": "response.output_text.done",
                "output_index": 0,
                "item_id": "msg_1",
                "content_index": 0,
                "text": "Hello",
            },
            {
                "type": "response.content_part.done",
                "output_index": 0,
                "item_id": "msg_1",
                "content_index": 0,
                "part": {
                    "type": "output_text",
                    "text": "Hello",
                    "annotations": [],
                },
            },
            {"type": "response.output_item.done", "output_index": 0, "item": message},
            {"type": "response.completed", "response": completed_response},
        ]
        for sequence_number, event in enumerate(events):
            event["sequence_number"] = sequence_number
        stream_body = "".join(f"data: {json.dumps(event)}\n\n" for event in events) + "data: [DONE]\n\n"

        async def model_handler(request: httpx.Request) -> httpx.Response:
            model_requests.append((json.loads(request.content), request.headers))
            return httpx.Response(
                200,
                text=stream_body,
                headers={"content-type": "text/event-stream"},
            )

        model_http_client = httpx.AsyncClient(transport=httpx.MockTransport(model_handler))
        agent_factory_calls = 0

        def create_test_chat_client(**kwargs: object) -> OpenAIChatClient:
            openai_client = AsyncOpenAI(
                api_key=kwargs["api_key"],
                base_url=kwargs["base_url"],
                default_headers=kwargs["default_headers"],
                http_client=model_http_client,
                max_retries=0,
            )
            return OpenAIChatClient(
                model=kwargs["model"],
                async_client=openai_client,
            )

        def build_test_agent() -> Agent:
            nonlocal agent_factory_calls
            agent_factory_calls += 1
            return repo_digest_agent.build_agent()

        try:
            with (
                patch.dict(
                    os.environ,
                    {
                        "AZURE_AI_GATEWAY_ENDPOINT": "https://mock.invalid/",
                        "AZURE_AI_GATEWAY_API_KEY": "test-gateway-key",
                        "AZURE_AI_GATEWAY_MODEL": "gpt-latest",
                    },
                ),
                patch.object(repo_digest_agent, "OpenAIChatClient", side_effect=create_test_chat_client),
                patch.object(repo_digest_agent, "_github_toolbox", return_value=None),
            ):
                server = ResponsesHostServer(
                    agent=build_test_agent,
                    history_source="agent_server",
                    response_store=InMemoryResponseProvider(),
                )
                async with httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=server),
                    base_url="http://test",
                ) as app:
                    stored = await app.post(
                        "/responses",
                        json={"input": "Say hello.", "store": True, "stream": True},
                    )
                    unstored = await app.post(
                        "/responses",
                        json={"input": "Say hello.", "store": False, "stream": False},
                    )

            self.assertEqual(stored.status_code, 200, stored.text)
            self.assertIn("event: response.completed", stored.text)
            self.assertEqual(unstored.status_code, 200, unstored.text)
            self.assertEqual(unstored.json()["status"], "completed")
            output_text = unstored.json()["output"][0]["content"][0]["text"]
            self.assertEqual(output_text, "Hello")
            self.assertEqual(agent_factory_calls, 2)
            self.assertEqual(len(model_requests), 2)
            for payload, headers in model_requests:
                self.assertIs(payload["store"], False)
                self.assertEqual(payload["model"], "gpt-latest")
                self.assertEqual(headers.get("api-key"), "test-gateway-key")
                self.assertIsNone(headers.get("authorization"))
        finally:
            await model_http_client.aclose()


if __name__ == "__main__":
    unittest.main()
