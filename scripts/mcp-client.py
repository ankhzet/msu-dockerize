#!/usr/bin/env python3
"""
Generic MSUI MCP client — minimal reference using only `requests`.

Usage:
    pip install requests
    MSUI_TOKEN=tk_xxx python3 scripts/mcp-client.py home_status
    MSUI_TOKEN=tk_xxx python3 scripts/mcp-client.py ra_list_online

Exits 0 on success, non-zero on failure. Prints the result envelope as JSON.
"""
import json
import os
import sys

import requests

URL = os.environ.get("MCP_URL", "http://localhost:5000/mcp")
TOKEN = os.environ.get("MSUI_TOKEN", "")
HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}
if TOKEN:
    HEADERS["Authorization"] = f"Bearer {TOKEN}"


def call(tool_name: str, arguments: dict | None = None) -> dict:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": arguments or {}},
    }
    resp = requests.post(URL, headers=HEADERS, json=payload, timeout=30)
    resp.raise_for_status()
    return resp.json()


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    tool = sys.argv[1]
    args = {}
    # Positional args after the tool name become `arguments.foo`, `arguments.bar`, ...
    for i, a in enumerate(sys.argv[2:]):
        args[f"arg{i}"] = a

    try:
        result = call(tool, args)
    except requests.HTTPError as e:
        print(f"HTTP {e.response.status_code}: {e.response.text}", file=sys.stderr)
        return 1
    except requests.RequestException as e:
        print(f"request failed: {e}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
