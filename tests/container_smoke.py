#!/usr/bin/env python3
"""Run the container against local mock AI Gateway and Foundry Toolbox endpoints."""

from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

GATEWAY_PATH = "/default/models/openai/v1/responses"
TOOLBOX_PATH = "/api/projects/mock-project/toolboxes/mock-toolbox/versions/1/mcp"


def _event(event_type: str, sequence_number: int, **values: Any) -> dict[str, Any]:
    return {"type": event_type, "sequence_number": sequence_number, **values}


def _model_response() -> tuple[dict[str, Any], str]:
    message = {
        "id": "msg_mock",
        "type": "message",
        "status": "completed",
        "role": "assistant",
        "content": [
            {
                "type": "output_text",
                "text": (
                    "Summary: Mock daily digest for microsoft/agent-framework.\n"
                    "Pull requests: None found.\n"
                    "Issues: None found.\n"
                    "Workflow failures: None found.\n"
                    "Suggested next actions: Review repository activity tomorrow."
                ),
                "annotations": [],
            }
        ],
    }
    response = {
        "id": "resp_mock",
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
        _event(
            "response.created",
            0,
            response={**response, "status": "in_progress", "output": []},
        ),
        _event(
            "response.in_progress",
            1,
            response={**response, "status": "in_progress", "output": []},
        ),
        _event(
            "response.output_item.added",
            2,
            output_index=0,
            item={**message, "status": "in_progress"},
        ),
        _event(
            "response.content_part.added",
            3,
            output_index=0,
            item_id="msg_mock",
            content_index=0,
            part={"type": "output_text", "text": "", "annotations": []},
        ),
        _event(
            "response.output_text.delta",
            4,
            output_index=0,
            item_id="msg_mock",
            content_index=0,
            delta=message["content"][0]["text"],
        ),
        _event(
            "response.output_text.done",
            5,
            output_index=0,
            item_id="msg_mock",
            content_index=0,
            text=message["content"][0]["text"],
        ),
        _event(
            "response.content_part.done",
            6,
            output_index=0,
            item_id="msg_mock",
            content_index=0,
            part=message["content"][0],
        ),
        _event("response.output_item.done", 7, output_index=0, item=message),
        _event("response.completed", 8, response=response),
    ]
    body = "".join(f"data: {json.dumps(event)}\n\n" for event in events) + "data: [DONE]\n\n"
    return response, body


class _MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    model_response, model_stream = _model_response()
    requests: list[tuple[str, dict[str, Any]]] = []
    session_closed = threading.Event()

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _send_json(self, status: int, payload: dict[str, Any], *, session: bool = False) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if session:
            self.send_header("Mcp-Session-Id", "mock-session")
            self.send_header("MCP-Protocol-Version", "2025-03-26")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _send_empty(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        self.requests.append((self.path, payload))

        if self.path == GATEWAY_PATH:
            if payload.get("model") != "gpt-latest" or payload.get("store") is not False:
                self._send_json(400, {"error": {"message": "Unexpected model request options."}})
                return
            body = self.model_stream.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith(TOOLBOX_PATH):
            if payload.get("method") == "initialize":
                self.session_closed.clear()
                self._send_json(
                    200,
                    {
                        "jsonrpc": "2.0",
                        "id": payload.get("id"),
                        "result": {
                            "protocolVersion": "2025-03-26",
                            "capabilities": {"tools": {"listChanged": False}},
                            "serverInfo": {"name": "ci-mock-toolbox", "version": "1.0.0"},
                        },
                    },
                    session=True,
                )
            elif payload.get("method") == "ping":
                self._send_json(
                    200,
                    {"jsonrpc": "2.0", "id": payload.get("id"), "result": {}},
                    session=True,
                )
            elif payload.get("method") == "tools/list":
                self._send_json(
                    200,
                    {
                        "jsonrpc": "2.0",
                        "id": payload.get("id"),
                        "result": {
                            "tools": [
                                {
                                    "name": "github_list_issues",
                                    "description": "Return mock repository issues.",
                                    "inputSchema": {"type": "object", "properties": {}},
                                }
                            ]
                        },
                    },
                    session=True,
                )
            elif not payload.get("id"):
                self._send_empty(202)
            else:
                self._send_json(
                    400,
                    {
                        "error": {
                            "message": f"Unexpected MCP method: {payload.get('method')!r}",
                        }
                    },
                )
            return

        self._send_json(404, {"error": {"message": "Unexpected mock endpoint."}})

    def do_GET(self) -> None:
        if not self.path.startswith(TOOLBOX_PATH):
            self._send_json(404, {"error": {"message": "Unexpected mock endpoint."}})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.flush()
        try:
            self.session_closed.wait(timeout=30)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def do_DELETE(self) -> None:
        if not self.path.startswith(TOOLBOX_PATH):
            self._send_json(404, {"error": {"message": "Unexpected mock endpoint."}})
            return
        self.session_closed.set()
        self._send_empty(200)


def _available_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def _wait_for_readiness(url: str, container: str) -> None:
    deadline = time.monotonic() + 90
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["docker", "inspect", "--format", "{{.State.Running}}", container],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.stdout.strip() != "true":
            logs = subprocess.run(
                ["docker", "logs", container],
                check=False,
                capture_output=True,
                text=True,
            )
            raise RuntimeError(f"Agent container exited during startup:\n{logs.stdout}{logs.stderr}")
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError) as exc:
            last_error = exc
            time.sleep(1)
    raise TimeoutError(f"Agent readiness did not return 200: {last_error}")


def _post_response(url: str, *, store: bool, stream: bool) -> str:
    payload = json.dumps(
        {
            "input": "Create a concise daily repo digest for microsoft/agent-framework.",
            "store": store,
            "stream": stream,
        }
    ).encode()
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        if response.status != 200:
            raise RuntimeError(f"POST /responses returned HTTP {response.status}")
        body = response.read().decode()
    if stream:
        if "event: response.completed" not in body or "Mock daily digest" not in body:
            raise RuntimeError(f"Streaming response was not a completed digest:\n{body}")
        return body
    response_body = json.loads(body)
    if response_body.get("status") != "completed":
        raise RuntimeError(f"Non-streaming response did not complete: {body}")
    output = json.dumps(response_body.get("output", []))
    if "Mock daily digest" not in output:
        raise RuntimeError(f"Non-streaming response did not contain the digest: {body}")
    return body


def _write_credential_stub(directory: Path) -> None:
    (directory / "sitecustomize.py").write_text(
        "from azure.core.credentials import AccessToken\n"
        "import azure.identity\n"
        "\n"
        "class MockCredential:\n"
        "    def __init__(self, *args, **kwargs):\n"
        "        pass\n"
        "\n"
        "    def get_token(self, *scopes, **kwargs):\n"
        "        return AccessToken('ci-mock-token', 4102444800)\n"
        "\n"
        "    def close(self):\n"
        "        pass\n"
        "\n"
        "azure.identity.DefaultAzureCredential = MockCredential\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, help="Built container image tag.")
    args = parser.parse_args()

    _MockHandler.requests = []
    _MockHandler.session_closed = threading.Event()
    mock_server = ThreadingHTTPServer(("0.0.0.0", 0), _MockHandler)
    mock_thread = threading.Thread(target=mock_server.serve_forever, daemon=True)
    mock_thread.start()
    mock_port = mock_server.server_address[1]
    container_name = f"agent-ci-smoke-{uuid.uuid4().hex[:12]}"
    host_port = _available_port()
    try:
        with tempfile.TemporaryDirectory(prefix="agent-ci-smoke-") as stub_directory:
            _write_credential_stub(Path(stub_directory))
            run_command = [
                "docker",
                "run",
                "--detach",
                "--name",
                container_name,
                "--publish",
                f"127.0.0.1:{host_port}:8088",
                "--add-host",
                "host.docker.internal:host-gateway",
                "--mount",
                f"type=bind,source={stub_directory},target=/ci-stubs,readonly",
                "--env",
                "PYTHONPATH=/ci-stubs",
                "--env",
                "AZURE_AI_GATEWAY_ENDPOINT=http://host.docker.internal:"
                f"{mock_port}/",
                "--env",
                "AZURE_AI_GATEWAY_MODEL=gpt-latest",
                "--env",
                "AZURE_AI_GATEWAY_API_KEY=ci-mock-key",
                "--env",
                "TOOLBOX_ENDPOINT=http://host.docker.internal:"
                f"{mock_port}{TOOLBOX_PATH}?api-version=v1",
                "--env",
                "TOOLBOX_NAME=mock-toolbox",
                "--env",
                "GITHUB_REPOSITORY=microsoft/agent-framework",
                "--env",
                "OTEL_SDK_DISABLED=true",
                "--env",
                "MICROSOFT_OTEL_SDKSTATS_DISABLED=true",
                args.image,
            ]
            subprocess.run(run_command, check=True, capture_output=True, text=True)
            _wait_for_readiness(f"http://127.0.0.1:{host_port}/readiness", container_name)
            _post_response(f"http://127.0.0.1:{host_port}/responses", store=True, stream=True)
            _post_response(f"http://127.0.0.1:{host_port}/responses", store=False, stream=False)

            gateway_requests = [
                payload for path, payload in _MockHandler.requests if path == GATEWAY_PATH
            ]
            toolbox_methods = [
                payload.get("method")
                for path, payload in _MockHandler.requests
                if path.startswith(TOOLBOX_PATH)
            ]
            if len(gateway_requests) != 2 or not {"initialize", "tools/list"}.issubset(toolbox_methods):
                raise RuntimeError(
                    "The container did not exercise both mocked services: "
                    f"gateway_requests={len(gateway_requests)}, toolbox_methods={toolbox_methods}"
                )
        print("Container smoke test passed: readiness and both Responses modes completed.")
    except Exception:
        logs = subprocess.run(
            ["docker", "logs", container_name],
            check=False,
            capture_output=True,
            text=True,
        )
        if logs.stdout or logs.stderr:
            print(logs.stdout, end="")
            print(logs.stderr, end="", file=sys.stderr)
        raise
    finally:
        subprocess.run(["docker", "rm", "--force", container_name], check=False, capture_output=True)
        mock_server.shutdown()
        mock_server.server_close()
        mock_thread.join(timeout=2)


if __name__ == "__main__":
    main()
