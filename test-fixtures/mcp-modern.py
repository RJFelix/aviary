#!/usr/bin/env python3
"""
A stateless 2026-07-28 MCP server, for testing the client against a real modern one.

The point of it is strictness. It refuses any request that does not carry the per-request
`_meta` the revision requires, and it never sees an `initialize` — so a client that only
pretends to speak the new protocol fails here rather than silently working by accident.

`whoami` reports back the protocol version and client identity it was handed, which is the
only way to prove from the outside that the metadata actually crossed the wire.
`needs_input` returns an MRTR interim result, which this client cannot satisfy.
"""

import base64
import json
import struct
import sys
import zlib

VERSION = "2026-07-28"
SERVER_INFO = {"name": "modern-fixture", "version": "1"}

TOOLS = [
    {"name": "whoami", "description": "Report the request metadata.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "needs_input", "description": "Always asks for more.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "shot", "description": "Return a picture as the answer.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "broken_shot", "description": "Return a picture that is not one.",
     "inputSchema": {"type": "object", "properties": {}}},
]


def make_png(width, height):
    """A real PNG, generated rather than embedded.

    Deliberately larger than the client's downscale threshold: an MCP server is somebody
    else's program and the size of what it returns is its choice, so the interesting case is
    the one where the client has to do something about it.
    """
    rows = b"".join(
        b"\x00" + bytes([(x * 7) % 256, (y * 11) % 256, 120][k % 3]
                        for x in range(width) for k in range(3))
        for y in range(height))

    def chunk(tag, body):
        payload = tag + body
        return (struct.pack(">I", len(body)) + payload
                + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b""))


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def result(rid, fields, kind="complete"):
    body = dict(fields)
    body["resultType"] = kind
    meta = body.get("_meta", {})
    meta["io.modelcontextprotocol/serverInfo"] = SERVER_INFO
    body["_meta"] = meta
    send({"jsonrpc": "2.0", "id": rid, "result": body})


def error(rid, code, message, data=None):
    body = {"code": code, "message": message}
    if data is not None:
        body["data"] = data
    send({"jsonrpc": "2.0", "id": rid, "error": body})


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method, rid = msg.get("method"), msg.get("id")
    params = msg.get("params") or {}
    meta = params.get("_meta") or {}
    version = meta.get("io.modelcontextprotocol/protocolVersion")

    if method == "initialize":
        # A modern-only server SHOULD name what it speaks, because a legacy client has no
        # fall-forward mechanism and this message is the only diagnostic it can show.
        error(rid, -32022, "This server speaks only " + VERSION,
              {"supported": [VERSION], "requested": params.get("protocolVersion")})
        continue

    if method is not None and method.startswith("notifications/"):
        continue

    # Required on every request; a request without it is malformed.
    if version is None:
        error(rid, -32602, "missing io.modelcontextprotocol/protocolVersion in _meta")
        continue
    if "io.modelcontextprotocol/clientCapabilities" not in meta:
        error(rid, -32602, "missing io.modelcontextprotocol/clientCapabilities in _meta")
        continue
    if version != VERSION:
        error(rid, -32022, "Unsupported protocol version",
              {"supported": [VERSION], "requested": version})
        continue

    if method == "server/discover":
        result(rid, {"supportedVersions": [VERSION],
                     "capabilities": {"tools": {}},
                     "instructions": "A fixture.",
                     "ttlMs": 60000, "cacheScope": "private"})
    elif method == "tools/list":
        result(rid, {"tools": TOOLS, "ttlMs": 60000, "cacheScope": "private"})
    elif method == "tools/call":
        name = params.get("name")
        if name == "whoami":
            info = meta.get("io.modelcontextprotocol/clientInfo") or {}
            result(rid, {"content": [{"type": "text",
                                      "text": version + " " + str(info.get("name"))}]})
        elif name == "shot":
            png = base64.b64encode(make_png(2400, 1200)).decode()
            result(rid, {"content": [
                {"type": "text", "text": "here is the screen"},
                {"type": "image", "data": png, "mimeType": "image/png"}]})
        elif name == "broken_shot":
            result(rid, {"content": [
                {"type": "image", "data": "bm90IGFuIGltYWdl", "mimeType": "image/png"}]})
        elif name == "needs_input":
            result(rid, {"inputRequests": [{"method": "sampling/createMessage"}]},
                   kind="input_required")
        else:
            error(rid, -32601, "no tool named " + str(name))
    elif rid is not None:
        error(rid, -32601, "no such method: " + str(method))
