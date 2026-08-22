#!/usr/bin/env python3
"""
A two-tool stdio MCP server, for testing the client against something real.

`echo` returns its argument; `explode` reports a tool-level failure. Both matter: the second is
how a caller learns that a failing tool is a *result* the agent reads and works around, not an
exception that ends the run.
"""

import json
import sys

TOOLS = [
    {
        "name": "echo",
        "description": "Return the text you were given.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string", "description": "Text to echo."}},
            "required": ["text"],
        },
    },
    {
        "name": "explode",
        "description": "Always fails, on purpose.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def reply(rid, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method, rid = msg.get("method"), msg.get("id")
    if method == "initialize":
        reply(rid, {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                    "serverInfo": {"name": "echo", "version": "1"}})
    elif method == "tools/list":
        reply(rid, {"tools": TOOLS})
    elif method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        if name == "echo":
            reply(rid, {"content": [{"type": "text", "text": args.get("text", "")}]})
        elif name == "explode":
            reply(rid, {"content": [{"type": "text", "text": "a deliberate failure"}],
                        "isError": True})
        else:
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "id": rid,
                "error": {"code": -32601, "message": f"no tool named {name}"}}) + "\n")
            sys.stdout.flush()
    elif rid is not None:
        reply(rid, {})
