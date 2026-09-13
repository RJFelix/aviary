#!/usr/bin/env python3
"""Bounded loopback OpenAI fixture for the normal-daemon Work-owned child journey."""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 1024 * 1024
MAX_CALLS = 4
CHILD_PROMPT = "normal daemon gated child"
PARENT_PROMPT = "launch one normal daemon child"
ANSWER = "normal daemon child complete"

if len(sys.argv) != 3:
    raise SystemExit(2)

READY_FILE = sys.argv[1]
RELEASE_FILE = sys.argv[2]
LOCK = threading.Lock()
CALLS = []


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 8

    def __init__(self, *args, **kwargs):
        self.worker_slots = threading.BoundedSemaphore(4)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.worker_slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.worker_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.worker_slots.release()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.connection.settimeout(3)
        if self.path != "/stats":
            self.send_error(404)
            return
        with LOCK:
            body = json.dumps({"calls": list(CALLS)}, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.connection.settimeout(5)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if self.path != "/v1/chat/completions" or not 0 < length <= MAX_BODY:
                raise ValueError("invalid request")
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ValueError("incomplete request")
            request = json.loads(raw)
            messages = request.get("messages")
            if not isinstance(messages, list) or not messages:
                raise ValueError("missing messages")
            last = messages[-1]
            role = last.get("role") if isinstance(last, dict) else None
            content = last.get("content") if isinstance(last, dict) else None
            if role == "user" and content == CHILD_PROMPT:
                kind = "child"
            elif role == "user" and content == PARENT_PROMPT:
                kind = "parent_spawn"
            elif role == "tool":
                kind = "parent_finish"
            else:
                raise ValueError("unexpected conversation")
            authorized = self.headers.get("Authorization") == "Bearer child-daemon-key"
            with LOCK:
                if len(CALLS) >= MAX_CALLS or not authorized:
                    raise ValueError("capacity or authorization")
                CALLS.append({"kind": kind, "authorized": authorized})

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            if kind == "child":
                deadline = time.monotonic() + 30
                while not os.path.exists(RELEASE_FILE) and time.monotonic() < deadline:
                    time.sleep(0.02)
                if not os.path.exists(RELEASE_FILE):
                    raise TimeoutError("child release not observed")
                self.text(ANSWER)
                self.usage(31, 7)
            elif kind == "parent_spawn":
                code = (
                    "child = spawn(" + repr(CHILD_PROMPT)
                    + ", name='Normal daemon child')\nprint(child.aviary_id)"
                )
                self.tool(code)
                self.usage(41, 9)
            else:
                self.text("parent completed after child admission")
                self.usage(43, 11)
            self.raw_chunk(b"data: [DONE]\n\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except Exception:
            try:
                body = b'{"error":{"message":"bounded fixture failure"}}'
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            except Exception:
                pass

    def raw_chunk(self, payload):
        self.wfile.write(("%x\r\n" % len(payload)).encode("ascii"))
        self.wfile.write(payload + b"\r\n")
        self.wfile.flush()

    def chunk(self, value):
        payload = ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()
        self.raw_chunk(payload)

    def delta(self, value, finish=None):
        self.chunk({"choices": [{"index": 0, "delta": value, "finish_reason": finish}]})

    def text(self, value):
        for offset in range(0, len(value), 8):
            self.delta({"content": value[offset : offset + 8]})
        self.delta({}, "stop")

    def tool(self, code):
        self.delta({"tool_calls": [{
            "index": 0, "id": "normal-daemon-spawn", "type": "function",
            "function": {"name": "python", "arguments": ""},
        }]})
        arguments = json.dumps({"code": code}, separators=(",", ":"))
        midpoint = max(1, len(arguments) // 2)
        for piece in (arguments[:midpoint], arguments[midpoint:]):
            self.delta({"tool_calls": [{"index": 0, "function": {"arguments": piece}}]})
        self.delta({}, "tool_calls")

    def usage(self, input_tokens, output_tokens):
        self.chunk({
            "choices": [],
            "usage": {
                "prompt_tokens": input_tokens,
                "completion_tokens": output_tokens,
                "total_tokens": input_tokens + output_tokens,
                "prompt_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0},
            },
        })


server = Server(("127.0.0.1", 0), Handler)
ready_tmp = READY_FILE + ".tmp"
with open(ready_tmp, "w", encoding="utf-8") as stream:
    json.dump({"port": server.server_port}, stream)
os.replace(ready_tmp, READY_FILE)
server.serve_forever()
