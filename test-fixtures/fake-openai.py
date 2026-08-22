#!/usr/bin/env python3
"""
A scripted `openai-completions` server, for testing the agent loop without a provider.

Exists because the loop is the part most worth testing and the hardest to test against a real
model: you cannot assert that a live model will call a tool, and paying for a round trip to
find out is a poor test. This serves a fixed script instead, so a test can assert the whole
path — request encoding, SSE framing, tool-call assembly, tool execution in the runtime host,
the result going back, and the second turn ending the loop.

Turn N of a conversation gets script entry N. Each entry is either
  {"tool": {"name": ..., "arguments": {...}}}   – ask for a tool call
  {"text": "..."}                                – answer and stop
and every response also carries usage, so token accounting is exercised too.

Usage: fake-openai.py <port> <script.json>
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = []
CALLS = {"n": 0}
REQUESTS = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # quiet: the test's output is the interesting one

    def do_GET(self):
        # Lets a test read back exactly what the client sent, which is how request encoding
        # gets asserted rather than assumed.
        if self.path == "/_requests":
            body = json.dumps(REQUESTS).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            REQUESTS.append(json.loads(raw))
        except Exception:
            REQUESTS.append({"unparseable": raw.decode("utf-8", "replace")})

        index = CALLS["n"]
        CALLS["n"] += 1
        step = SCRIPT[index] if index < len(SCRIPT) else {"text": "(script exhausted)"}

        if "status" in step:
            # A scripted failure, for asserting that a provider error surfaces as one.
            body = json.dumps({"error": {"message": step.get("message", "scripted failure")}}).encode()
            self.send_response(step["status"])
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(obj):
            payload = ("data: " + json.dumps(obj) + "\n\n").encode()
            self.wfile.write(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")
            self.wfile.flush()

        def delta(d, finish=None):
            chunk({"choices": [{"index": 0, "delta": d, "finish_reason": finish}]})

        if "thinking" in step:
            delta({"reasoning_content": step["thinking"]})

        if "tool" in step:
            tool = step["tool"]
            call_id = tool.get("id", "call_%d" % index)
            # Split deliberately across chunks: only the first fragment carries id and name,
            # and the arguments arrive in pieces. Reassembling that is the client's job and
            # getting it wrong produces truncated arguments that look like model error.
            delta({"tool_calls": [{"index": 0, "id": call_id, "type": "function",
                                   "function": {"name": tool["name"], "arguments": ""}}]})
            args = json.dumps(tool.get("arguments") or {})
            mid = max(1, len(args) // 2)
            for piece in (args[:mid], args[mid:]):
                delta({"tool_calls": [{"index": 0, "function": {"arguments": piece}}]})
            delta({}, finish="tool_calls")
        else:
            text = step.get("text", "")
            for i in range(0, len(text), 7):
                delta({"content": text[i:i + 7]})
            delta({}, finish="stop")

        chunk({
            "choices": [],
            "usage": {
                "prompt_tokens": step.get("input_tokens", 100),
                "completion_tokens": step.get("output_tokens", 20),
                "total_tokens": step.get("input_tokens", 100) + step.get("output_tokens", 20),
                "prompt_tokens_details": {"cached_tokens": step.get("cached_tokens", 40)},
                **({"completion_tokens_details": {"reasoning_tokens": step["reasoning_tokens"]}}
                   if "reasoning_tokens" in step else {}),
            },
        })
        payload = b"data: [DONE]\n\n"
        self.wfile.write(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    port = int(sys.argv[1])
    SCRIPT = json.load(open(sys.argv[2]))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    # Announce readiness on stdout so a test waits for a listening socket rather than sleeping.
    print(json.dumps({"listening": port}), flush=True)
    server.serve_forever()
