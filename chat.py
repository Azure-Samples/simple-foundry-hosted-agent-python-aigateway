"""Console chat client for the Repo Digest hosted agent."""

import json
import os
import urllib.request

BASE_URL = os.environ.get("AGENT_URL", "http://localhost:8088").rstrip("/")
DEFAULT_PROMPT = "Create a concise daily repo digest for microsoft/agent-framework."


def _extract_response_text(response: object) -> str:
    if isinstance(response, dict):
        if response.get("output_text"):
            return str(response["output_text"])
        for item in response.get("output", []):
            for content in item.get("content", []):
                if content.get("type") in {"output_text", "text"} and content.get("text"):
                    return str(content["text"])
    return json.dumps(response)


print("=== Repo Digest Agent Chat ===")
print(f"Endpoint: {BASE_URL}/responses")
print(f"Press Enter to use: {DEFAULT_PROMPT}")
print("Type 'exit' or 'quit' to end.\n")

while True:
    message = input("You: ").strip()
    if message.lower() in {"exit", "quit"}:
        print("Goodbye!")
        break
    if not message:
        message = DEFAULT_PROMPT

    try:
        body = json.dumps({"input": message, "stream": False}).encode()
        request = urllib.request.Request(
            f"{BASE_URL}/responses",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request) as response:
            print(f"\nAgent: {_extract_response_text(json.loads(response.read().decode()))}\n")
    except Exception as exc:
        print(f"\nError: {exc}\n")
