# /// script
# requires-python = ">=3.11"
# dependencies = ["opentelemetry-proto==1.44.0"]
# ///
"""Verify one real, disposable AppModel/aviaryd/provider/tool/review telemetry journey.

Usage: uv run scripts/verify-live-chat-telemetry.py [--mode healthy|disabled|unreachable] \
    build/Aviary.app/Contents/MacOS/Aviary
Last verified: 2026-09-21. Uses only bounded loopback servers and a private /tmp AgentHome.
"""

import argparse
import collections
import ctypes
import http.server
import json
import os
import pathlib
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest


MAX_HTTP_BODY = 8 * 1024 * 1024
MAX_PROVIDER_BODY = 2 * 1024 * 1024
MAX_SPANS = 4096
MAX_FAILURES = 16
MAX_SERVER_THREADS = 4
PROMPT_SENTINEL = "LIVE_CHAT_PROMPT_SENTINEL_7f23"
ASSISTANT_SENTINEL = "LIVE_CHAT_ASSISTANT_SENTINEL_18ac"
TOOL_SENTINEL = "LIVE_CHAT_TOOL_SENTINEL_6bd1"
CREDENTIAL_SENTINEL = "live-chat-credential-sentinel-49e2"
UNUSED_CREDENTIAL_SENTINEL = "unused-loopback-credential-31dc"
FILE_SENTINEL = "probe-result.txt"
DIRECT_COMMAND_SOURCE_SENTINEL = "LIVE_DIRECT_COMMAND_SOURCE_SENTINEL_c741"
DIRECT_COMMAND_OUTPUT_SENTINEL = "LIVE_DIRECT_COMMAND_OUTPUT_SENTINEL_a29e"
REQUIRED_SPANS = (
    "aviary.agent.provider",
    "aviary.agent.send",
    "aviary.agent.tool",
    "aviary.gui.pending_chat.save",
    "aviary.gui.pending_chat.startup",
    "aviary.gui.repository_review.load",
    "aviary.repository.review",
    "aviary.runtime.execute",
    "aviary.work.admission",
    "aviary.work.command",
    "aviary.work.create_work",
    "aviary.work.direct_shell",
    "aviary.work.turn",
)
FAILURE_STAGES = {
    "directCommand",
    "ending",
    "invalid_environment",
    "review",
    "shutdown",
    "startup",
    "startupHost", "startupWorkspace", "startupProvider", "startupAuthorization", "startupRequest",
    "startupStatusSave", "startupSavedRowUnreadable", "startupPresentation",
    "turn",
    "unknown",
}
MODES = ("healthy", "disabled", "unreachable")


class Capture:
    def __init__(self):
        self.lock = threading.Lock()
        self.spans = []
        self.failures = []
        self.provider_requests = []

    def fail(self, reason):
        with self.lock:
            if len(self.failures) < MAX_FAILURES:
                self.failures.append(reason)


class BoundedThreadingHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True
    request_queue_size = 8

    def __init__(self, address, handler):
        self._permits = threading.BoundedSemaphore(MAX_SERVER_THREADS)
        super().__init__(address, handler)

    def get_request(self):
        request, address = super().get_request()
        # Header parsing happens before a handler reaches do_POST. Bound the accepted socket
        # itself so an idle client cannot strand server_close or the overload reply.
        request.settimeout(5)
        return request, address

    def process_request(self, request, client_address):
        if not self._permits.acquire(blocking=False):
            try:
                request.sendall(
                    b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n"
                    b"Content-Length: 0\r\n\r\n"
                )
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._permits.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._permits.release()


def start_server(handler):
    server = BoundedThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, name="aviary-live-probe-server")
    thread.start()
    return server, thread


def stop_server(server, thread):
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
    if thread.is_alive():
        raise RuntimeError("bounded loopback server did not stop")


def reserve_unreachable_endpoint():
    reservation = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
        if not 0 < port <= 65535:
            raise RuntimeError("could not reserve unreachable loopback endpoint")
        # Intentionally do not listen. Keeping the bound descriptor open prevents another
        # process from reusing this exact port while the exporter exercises connection refusal.
        return reservation, port
    except BaseException:
        reservation.close()
        raise


def make_collector_handler(capture):
    class Collector(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if self.path != "/v1/traces" or not 0 < length <= MAX_HTTP_BODY:
                    raise ValueError("invalid collector request")
                self.connection.settimeout(5)
                body = self.rfile.read(length)
                if len(body) != length:
                    raise ValueError("incomplete collector body")
                message = ExportTraceServiceRequest.FromString(body)
                batch = [
                    (resource.resource, span)
                    for resource in message.resource_spans
                    for scope in resource.scope_spans
                    for span in scope.spans
                ]
                with capture.lock:
                    if len(capture.spans) + len(batch) > MAX_SPANS:
                        raise ValueError("collector capacity exceeded")
                    capture.spans.extend(batch)
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()
            except Exception:
                capture.fail("collector rejected a malformed or excessive request")
                self.send_error(400)

    return Collector


def make_provider_handler(capture):
    class Provider(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if self.path != "/v1/chat/completions" or not 0 < length <= MAX_PROVIDER_BODY:
                    raise ValueError("invalid provider request")
                self.connection.settimeout(5)
                body = self.rfile.read(length)
                if len(body) != length:
                    raise ValueError("incomplete provider body")
                request = json.loads(body)
                with capture.lock:
                    if len(capture.provider_requests) >= 4:
                        raise ValueError("provider call capacity exceeded")
                    capture.provider_requests.append(
                        {
                            "body": request,
                            "authorized": self.headers.get("Authorization")
                            == f"Bearer {CREDENTIAL_SENTINEL}",
                        }
                    )
                    index = len(capture.provider_requests) - 1
                if index > 1:
                    raise ValueError("unexpected provider call")
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                if index == 0:
                    code = (
                        "from pathlib import Path\n"
                        f"(Path(cwd()) / {FILE_SENTINEL!r}).write_text({TOOL_SENTINEL!r})\n"
                        f"print({TOOL_SENTINEL!r})"
                    )
                    self._tool_response(code)
                else:
                    self._text_response(ASSISTANT_SENTINEL)
                self._chunk(
                    {
                        "choices": [],
                        "usage": {
                            "prompt_tokens": 120 + index,
                            "completion_tokens": 24,
                            "total_tokens": 144 + index,
                            "prompt_tokens_details": {"cached_tokens": 20},
                        },
                    }
                )
                self._raw_chunk(b"data: [DONE]\n\n")
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except Exception:
                capture.fail("provider rejected a malformed or excessive request")
                try:
                    payload = b'{"error":{"message":"bounded fixture failure"}}'
                    self.send_response(400)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(payload)
                except Exception:
                    pass

        def _raw_chunk(self, payload):
            self.wfile.write(f"{len(payload):x}\r\n".encode("ascii"))
            self.wfile.write(payload + b"\r\n")
            self.wfile.flush()

        def _chunk(self, value):
            self._raw_chunk(("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode())

        def _delta(self, delta, finish=None):
            self._chunk({"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]})

        def _tool_response(self, code):
            call_id = "call-live-probe"
            self._delta(
                {
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": call_id,
                            "type": "function",
                            "function": {"name": "python", "arguments": ""},
                        }
                    ]
                }
            )
            arguments = json.dumps({"code": code}, separators=(",", ":"))
            midpoint = max(1, len(arguments) // 2)
            for piece in (arguments[:midpoint], arguments[midpoint:]):
                self._delta(
                    {"tool_calls": [{"index": 0, "function": {"arguments": piece}}]}
                )
            self._delta({}, finish="tool_calls")

        def _text_response(self, text):
            for offset in range(0, len(text), 7):
                self._delta({"content": text[offset : offset + 7]})
            self._delta({}, finish="stop")

    return Provider


def run_checked(arguments, *, cwd=None, timeout=10):
    result = subprocess.run(
        arguments,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0 or len(result.stdout) > 64 * 1024 or len(result.stderr) > 64 * 1024:
        raise RuntimeError("private fixture setup failed")


def prepare_fixture(root, provider_port):
    home = root / "home"
    workspace = root / "workspace"
    scratch = root / "tmp"
    shell_startup = root / "zsh"
    for directory in (home, workspace, scratch, shell_startup):
        directory.mkdir(mode=0o700)
        os.chmod(directory, 0o700)
    models = {
        "providers": {
            "live-local": {
                "name": "Loopback OpenAI-compatible",
                "baseUrl": f"http://127.0.0.1:{provider_port}/v1",
                "api": "openai-completions",
                "apiKey": "AVIARY_LIVE_CHAT_API_KEY",
                "models": [
                    {
                        "id": "live-model",
                        "contextWindow": 100000,
                        "maxTokens": 2048,
                        "cost": {"input": 0.000001, "output": 0.000002},
                    }
                ],
            },
            "unused-anthropic": {
                "name": "Unused loopback provider",
                "baseUrl": f"http://127.0.0.1:{provider_port}/unused",
                "api": "anthropic-messages",
                "apiKey": "AVIARY_UNUSED_LIVE_CHAT_KEY",
                "models": [{"id": "unused-model", "contextWindow": 100000, "maxTokens": 1024}],
            },
        }
    }
    models_path = home / "models.json"
    models_path.write_text(json.dumps(models, sort_keys=True), encoding="utf-8")
    os.chmod(models_path, 0o600)
    tracked = workspace / FILE_SENTINEL
    tracked.write_text("before\n", encoding="utf-8")
    run_checked(["git", "init", "-q"], cwd=workspace)
    run_checked(["git", "add", FILE_SENTINEL], cwd=workspace)
    run_checked(
        [
            "git",
            "-c",
            "user.name=Aviary Probe",
            "-c",
            "user.email=probe@invalid.example",
            "commit",
            "-qm",
            "initial fixture",
        ],
        cwd=workspace,
    )
    return home, workspace, scratch


def expected_daemon(binary):
    if binary.parent.name == "MacOS" and binary.parent.parent.name == "Contents":
        return (binary.parent.parent / "Helpers" / "aviaryd").resolve(strict=True)
    return (binary.parent / "aviaryd").resolve(strict=True)


def process_executable(pid):
    if sys.platform == "darwin":
        buffer = ctypes.create_string_buffer(4096)
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        size = libproc.proc_pidpath(int(pid), buffer, len(buffer))
        return pathlib.Path(os.fsdecode(buffer.raw[:size])).resolve() if size > 0 else None
    path = pathlib.Path(f"/proc/{pid}/exe")
    try:
        return path.resolve(strict=True)
    except (FileNotFoundError, PermissionError):
        return None


def process_table():
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,command="],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=5,
        check=False,
        text=True,
    )
    rows = {}
    if result.returncode != 0 or len(result.stdout) > 4 * 1024 * 1024:
        raise RuntimeError("process inventory could not establish cleanup ownership")
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            rows[int(parts[0])] = (int(parts[1]), parts[2])
        except ValueError:
            continue
    return rows


def exact_daemon(pid, daemon, home):
    if process_executable(pid) != daemon:
        return False
    row = process_table().get(pid)
    if row is None:
        return False
    try:
        argv = shlex.split(row[1])
    except ValueError:
        return False
    if "--agent-home" not in argv:
        return False
    arguments = argv[argv.index("--agent-home") + 1 :][:1]
    return bool(arguments) and pathlib.Path(arguments[0]).resolve() == home.resolve()


def endpoint_pid(home, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        paths = list(home.glob("timeline-v2/work-hosts/*/service/endpoint.json"))
        if len(paths) > 16:
            raise RuntimeError("endpoint descriptor capacity exceeded")
        for path in paths:
            try:
                if path.stat().st_size > 64 * 1024:
                    continue
                value = json.loads(path.read_text(encoding="utf-8"))
                pid = int(value["processID"])
                if pid > 1:
                    return pid
            except (OSError, ValueError, KeyError, json.JSONDecodeError):
                continue
        time.sleep(0.05)
    raise RuntimeError("disposable daemon descriptor was unavailable")


def owned_daemon_pids(daemon, home):
    matches = [pid for pid in process_table() if exact_daemon(pid, daemon, home)]
    if len(matches) > 4:
        raise RuntimeError("owned daemon scan exceeded its bound")
    return matches


def captured_runtime_children(daemon_pid):
    rows = process_table()
    descendants = set()
    changed = True
    while changed:
        changed = False
        for pid, (parent, _command) in rows.items():
            if pid not in descendants and (parent == daemon_pid or parent in descendants):
                descendants.add(pid)
                changed = True
    result = {}
    lease_flag = f"--parent-lifetime-pid {daemon_pid}"
    for pid in descendants:
        command = rows[pid][1]
        if "runtime-hosts/python3/host.py" in command and lease_flag in command:
            result[pid] = command
    return result


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_dead(pid, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.05)
    return not pid_alive(pid)


def cleanup_owned_processes(daemon_pid, daemon, home):
    children = captured_runtime_children(daemon_pid) if exact_daemon(daemon_pid, daemon, home) else {}
    forced = False
    if exact_daemon(daemon_pid, daemon, home):
        os.kill(daemon_pid, signal.SIGTERM)
    if not wait_dead(daemon_pid, 15):
        if not exact_daemon(daemon_pid, daemon, home):
            raise RuntimeError("daemon PID changed identity during cleanup")
        os.kill(daemon_pid, signal.SIGKILL)
        forced = True
        if not wait_dead(daemon_pid, 5):
            raise RuntimeError("owned daemon did not exit")
    rows = process_table()
    for pid, original_command in children.items():
        current = rows.get(pid)
        if current is None:
            continue
        if current[1] != original_command:
            raise RuntimeError("runtime child PID changed identity during cleanup")
        os.kill(pid, signal.SIGTERM)
        if not wait_dead(pid, 3):
            current = process_table().get(pid)
            if current is None:
                continue
            if current[1] != original_command:
                raise RuntimeError("runtime child PID changed identity during cleanup")
            os.kill(pid, signal.SIGKILL)
            forced = True
            if not wait_dead(pid, 3):
                raise RuntimeError("owned runtime child did not exit")
    if forced:
        raise RuntimeError("disposable processes required forced cleanup")


def any_value(value):
    kind = value.WhichOneof("value")
    if kind == "string_value":
        return value.string_value
    if kind == "bool_value":
        return "true" if value.bool_value else "false"
    if kind == "int_value":
        return str(value.int_value)
    if kind == "double_value":
        return repr(value.double_value)
    if kind == "bytes_value":
        return value.bytes_value.hex()
    return ""


def attributes(entries):
    return {entry.key: any_value(entry.value) for entry in entries}


def service_name(resource):
    return attributes(resource.attributes).get("service.name")


def validate_receipt(receipt):
    expected = {
        "work", "journal", "session", "run", "startCommand", "action", "artifact",
        "directCommand", "directAction",
    }
    if set(receipt) != expected:
        raise RuntimeError("probe receipt had an invalid shape")
    if not all(
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
        for value in receipt.values()
    ):
        raise RuntimeError("probe receipt did not contain bounded identity hashes")


def validate_workload(capture):
    with capture.lock:
        spans = list(capture.spans)
        failures = list(capture.failures)
        requests = list(capture.provider_requests)
    if failures:
        raise RuntimeError(failures[0])
    if len(requests) != 2 or not all(row["authorized"] for row in requests):
        raise RuntimeError("provider did not receive exactly two authorized calls")
    first = json.dumps(requests[0]["body"], separators=(",", ":"))
    second = json.dumps(requests[1]["body"], separators=(",", ":"))
    if PROMPT_SENTINEL not in first or TOOL_SENTINEL not in second:
        raise RuntimeError("provider requests did not prove prompt/tool-result continuation")
    return spans


def validate_telemetry(capture, receipt, private_root):
    spans = validate_workload(capture)

    names = collections.Counter(span.name for _resource, span in spans)
    missing = sorted(set(REQUIRED_SPANS) - set(names))
    if missing:
        raise RuntimeError("collector missed required live journey spans: " + ",".join(missing))
    if names["aviary.agent.provider"] != 2:
        raise RuntimeError("provider span count did not match the deterministic provider calls")
    services = {service_name(resource) for resource, _span in spans}
    if not {"aviary", "aviaryd"}.issubset(services):
        raise RuntimeError("collector did not receive both app and daemon resources")

    startups = [span for _resource, span in spans if span.name == "aviary.gui.pending_chat.startup"]
    if (len(startups) != 2 or any(span.parent_span_id for span in startups)
            or len({span.trace_id for span in startups}) != 2):
        raise RuntimeError("startup and retained-card refresh were not independent roots")
    if any(attributes(span.attributes).get("aviary.outcome") not in {"accepted", "completed"}
           for span in startups):
        raise RuntimeError("pending chat startup did not report accepted completion")
    recoveries = [span for _resource, span in spans
                  if span.name == "aviary.gui.retained_start.recover"]
    if (len(recoveries) != 1
            or attributes(recoveries[0].attributes).get("aviary.outcome") != "completed"
            or recoveries[0].parent_span_id
            or recoveries[0].trace_id in {span.trace_id for span in startups}):
        raise RuntimeError("retained-card refresh did not report completed reconciliation")
    recovery_attributes = attributes(recoveries[0].attributes)
    recovery_roots = [span for span in startups
                      if attributes(span.attributes).get("aviary.chat.id")
                      == recovery_attributes.get("aviary.chat.id")]
    if (len(recovery_roots) != 1 or not recovery_attributes.get("aviary.chat.id")
            or recovery_attributes.get("aviary.start.command.id") != receipt["startCommand"]
            or attributes(recovery_roots[0].attributes).get("aviary.start.command.id")
            != receipt["startCommand"]):
        raise RuntimeError("retained-card refresh lost the exact saved-command correlation")
    for command_kind in ("start", "end"):
        gui_commands = [
            span
            for resource, span in spans
            if service_name(resource) == "aviary"
            and span.name == "aviary.ui.command"
            and attributes(span.attributes).get("aviary.command.kind") == command_kind
        ]
        daemon_admissions = [
            span
            for resource, span in spans
            if service_name(resource) == "aviaryd"
            and span.name == "aviary.work.admission"
            and attributes(span.attributes).get("aviary.command.kind") == command_kind
        ]
        if (
            len(gui_commands) != 1
            or attributes(gui_commands[0].attributes).get("aviary.outcome")
            not in {"accepted", "duplicate"}
            or len(daemon_admissions) != 1
            or attributes(daemon_admissions[0].attributes).get("aviary.outcome") != "accepted"
        ):
            raise RuntimeError("Start/End admission telemetry did not match canonical success")
    successful_tools = [
        span
        for _resource, span in spans
        if span.name == "aviary.agent.tool"
        and attributes(span.attributes).get("aviary.outcome") == "succeeded"
    ]
    successful_review_loads = [
        span
        for _resource, span in spans
        if span.name == "aviary.gui.repository_review.load"
        and attributes(span.attributes).get("aviary.outcome") == "succeeded"
    ]
    if len(successful_tools) != 1 or len(successful_review_loads) != 1:
        raise RuntimeError("tool execution or explicit repository-review load was not successful")
    create_spans = [
        (service_name(resource), span)
        for resource, span in spans
        if span.name == "aviary.work.create_work"
    ]
    app_creates = [span for service, span in create_spans if service == "aviary"]
    daemon_creates = [span for service, span in create_spans if service == "aviaryd"]
    if len(app_creates) != 1 or len(daemon_creates) != 1:
        raise RuntimeError("Create did not produce one app/client and daemon/server span")
    app_create, daemon_create = app_creates[0], daemon_creates[0]
    creation_roots = [span for span in startups if span.trace_id == app_create.trace_id]
    if (
        len(creation_roots) != 1
        or app_create.parent_span_id != creation_roots[0].span_id
        or daemon_create.trace_id != app_create.trace_id
        or daemon_create.parent_span_id != app_create.span_id
        or recoveries[0].trace_id == app_create.trace_id
    ):
        raise RuntimeError("Create trace propagation did not preserve the startup/client/server chain")

    start_admissions = [
        span
        for resource, span in spans
        if service_name(resource) == "aviaryd"
        and span.name == "aviary.work.admission"
        and attributes(span.attributes).get("aviary.command.kind") == "start"
    ]
    if len(start_admissions) != 1:
        raise RuntimeError("collector did not retain one Start admission")
    start_attributes = attributes(start_admissions[0].attributes)
    for key, value in {
            "aviary.command.id": receipt["startCommand"],
            "aviary.work.id": receipt["work"],
            "aviary.session.id": receipt["session"],
            "aviary.run.id": receipt["run"],
        }.items():
        if start_attributes.get(key) != value:
            raise RuntimeError("Start admission did not bind canonical " + key)

    tool_outcomes = [
        attributes(event.attributes)
        for span in successful_tools
        for event in span.events
        if event.name == "aviary.agent.action.outcome"
    ]
    if len(tool_outcomes) != 1 or any(
        tool_outcomes[0].get(key) != value
        for key, value in {
            "aviary.action.id": receipt["action"],
            "aviary.event.journal.id": receipt["journal"],
            "aviary.outcome": "succeeded",
        }.items()
    ):
        raise RuntimeError("Python outcome did not bind its canonical action receipt")

    review_attributes = attributes(successful_review_loads[0].attributes)
    if any(
        review_attributes.get(key) != value
        for key, value in {
            "aviary.artifact.id": receipt["artifact"],
            "aviary.work.id": receipt["work"],
            "aviary.session.id": receipt["session"],
        }.items()
    ):
        raise RuntimeError("repository review load did not bind its selected canonical artifact")

    direct_worker_spans = [
        span
        for resource, span in spans
        if service_name(resource) == "aviaryd"
        and span.name == "aviary.work.direct_shell"
        and span.kind == 1
        and any(event.name == "aviary.direct_shell.settled" for event in span.events)
    ]
    if len(direct_worker_spans) != 1:
        raise RuntimeError("direct command did not produce one internal worker settlement span")
    direct_span = direct_worker_spans[0]
    direct_attributes = attributes(direct_span.attributes)
    if any(
        direct_attributes.get(key) != value
        for key, value in {
            "aviary.command.id": receipt["directCommand"],
            "aviary.action.id": receipt["directAction"],
            "aviary.work.id": receipt["work"],
            "aviary.run.id": receipt["run"],
            "aviary.outcome": "succeeded",
        }.items()
    ):
        raise RuntimeError("direct command span did not bind its canonical identities")
    settled_events = [
        attributes(event.attributes)
        for event in direct_span.events
        if event.name == "aviary.direct_shell.settled"
    ]
    if len(settled_events) != 1:
        raise RuntimeError("direct command span lacked one settlement event")
    settled = settled_events[0]
    event_id = settled.get("aviary.event.id", "")
    event_sequence = settled.get("aviary.event.sequence", "")
    if (
        settled.get("aviary.event.journal.id") != receipt["journal"]
        or len(event_id) != 64
        or any(character not in "0123456789abcdef" for character in event_id)
        or not event_sequence.isdigit()
        or int(event_sequence) <= 0
    ):
        raise RuntimeError("direct command settlement lacked a canonical event reference")

    private_values = {
        PROMPT_SENTINEL,
        ASSISTANT_SENTINEL,
        TOOL_SENTINEL,
        CREDENTIAL_SENTINEL,
        UNUSED_CREDENTIAL_SENTINEL,
        FILE_SENTINEL,
        DIRECT_COMMAND_SOURCE_SENTINEL,
        DIRECT_COMMAND_OUTPUT_SENTINEL,
        str(private_root),
        str(private_root.resolve()),
    }
    for resource, span in spans:
        values = [span.name, service_name(resource) or ""]
        values.extend(any_value(entry.value) for entry in resource.attributes)
        values.extend(any_value(entry.value) for entry in span.attributes)
        for event in span.events:
            values.append(event.name)
            values.extend(any_value(entry.value) for entry in event.attributes)
        joined = "\n".join(values)
        if any(private in joined for private in private_values):
            raise RuntimeError("private fixture content appeared in exported telemetry")
    return names, len(spans)


def validate_telemetry_absent(capture, mode):
    spans = validate_workload(capture)
    if spans:
        raise RuntimeError(f"{mode} telemetry journey unexpectedly exported spans")


def launch_probe(binary, environment):
    process = subprocess.Popen(
        [str(binary), "--live-chat-telemetry-probe"],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    retained = bytearray()
    overflow = threading.Event()
    reader_failed = threading.Event()

    def drain_output():
        descriptor = process.stdout.fileno()
        os.set_blocking(descriptor, False)
        try:
            while True:
                readable, _, _ = select.select([descriptor], [], [], 0.2)
                if not readable:
                    if process.poll() is not None:
                        return
                    continue
                try:
                    chunk = os.read(descriptor, 8192)
                except BlockingIOError:
                    continue
                if not chunk:
                    return
                available = 64 * 1024 - len(retained)
                if available > 0:
                    retained.extend(chunk[:available])
                if len(chunk) > available:
                    overflow.set()
        except OSError:
            reader_failed.set()

    reader = threading.Thread(target=drain_output, name="aviary-live-probe-output")
    reader.start()
    try:
        return_code = process.wait(timeout=120)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        raise RuntimeError("live AppModel journey timed out")
    finally:
        reader.join(timeout=5)
        if not reader.is_alive():
            process.stdout.close()
    if reader.is_alive():
        raise RuntimeError("live probe output reader did not stop")
    if reader_failed.is_set():
        raise RuntimeError("live probe output reader failed")
    data = bytes(retained)
    if overflow.is_set():
        raise RuntimeError("live probe output exceeded its bound")
    if return_code != 0:
        prefix = "live chat telemetry probe FAILED:"
        try:
            lines = [line for line in data.decode("ascii").splitlines() if line.strip()]
        except UnicodeDecodeError:
            lines = []
        stage = lines[0].removeprefix(prefix) if len(lines) == 1 else ""
        if not lines or not lines[0].startswith(prefix) or stage not in FAILURE_STAGES:
            stage = "unknown"
        raise RuntimeError("live AppModel journey failed at allowlisted stage " + stage)
    try:
        lines = [line for line in data.decode("utf-8").splitlines() if line.strip()]
        if len(lines) != 1:
            raise ValueError
        receipt = json.loads(lines[0])
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        raise RuntimeError("live probe returned an invalid bounded receipt") from None
    validate_receipt(receipt)
    return receipt


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Run one bounded live AppModel telemetry journey.")
    parser.add_argument("--mode", choices=MODES, default="healthy")
    parser.add_argument("executable", help="Aviary app executable")
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    mode = arguments.mode
    binary = pathlib.Path(arguments.executable).resolve(strict=True)
    daemon = expected_daemon(binary)
    full_started = time.monotonic()
    root = pathlib.Path(tempfile.mkdtemp(prefix="avlive-", dir="/tmp")).resolve()
    os.chmod(root, 0o700)
    capture = Capture()
    collector = provider = collector_thread = provider_thread = None
    unreachable_reservation = None
    daemon_pid = None
    journey_elapsed = None
    primary_error = None
    success_lines = None
    try:
        if mode == "unreachable":
            unreachable_reservation, telemetry_port = reserve_unreachable_endpoint()
        else:
            collector, collector_thread = start_server(make_collector_handler(capture))
            telemetry_port = collector.server_port
        provider, provider_thread = start_server(make_provider_handler(capture))
        home, workspace, scratch = prepare_fixture(root, provider.server_port)
        inherited_keys = {
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LOGNAME",
            "PATH",
            "SHELL",
            "TERM",
            "USER",
        }
        environment = {
            key: value
            for key, value in os.environ.items()
            if key in inherited_keys or key.startswith("DYLD_")
        }
        environment.update(
            {
                "TMPDIR": str(scratch) + os.sep,
                "ZDOTDIR": str(root / "zsh"),
                "AVIARY_OTEL_ENABLED": "0" if mode == "disabled" else "1",
                "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": (
                    f"http://127.0.0.1:{telemetry_port}/v1/traces"
                ),
                "AVIARY_LIVE_CHAT_PROBE_HOME": str(home),
                "AVIARY_LIVE_CHAT_PROBE_WORKSPACE": str(workspace),
                "AVIARY_LIVE_CHAT_API_KEY": CREDENTIAL_SENTINEL,
                "AVIARY_UNUSED_LIVE_CHAT_KEY": UNUSED_CREDENTIAL_SENTINEL,
                "NO_PROXY": "127.0.0.1,localhost",
                "no_proxy": "127.0.0.1,localhost",
            }
        )
        journey_started = time.monotonic()
        receipt = launch_probe(binary, environment)
        journey_elapsed = time.monotonic() - journey_started
        daemon_pid = endpoint_pid(home)
        if not exact_daemon(daemon_pid, daemon, home):
            raise RuntimeError("endpoint descriptor did not name the owned daemon")
        if (workspace / FILE_SENTINEL).read_text(encoding="utf-8") != TOOL_SENTINEL:
            raise RuntimeError("Python tool did not mutate the disposable repository")
        cleanup_owned_processes(daemon_pid, daemon, home)
        daemon_pid = None
        # The collector remains available through the daemon's bounded shutdown drain above.
        if mode == "healthy":
            names, span_count = validate_telemetry(capture, receipt, root)
            success_lines = [
                "live OTLP chat probe PASS: "
                f"{span_count} spans; 2 provider calls; "
                "Create/Start/tool/review/direct-shell/Dismiss/End/drain",
                *(f"  {name}: {names[name]}" for name in REQUIRED_SPANS),
            ]
        else:
            validate_telemetry_absent(capture, mode)
            success_lines = [
                f"live {mode} telemetry chat probe PASS: " +
                ("0 collected spans; " if mode == "disabled" else "reserved refusing endpoint; ")
                + "2 provider calls; Create/Start/tool/review/direct-shell/Dismiss/End/cleanup",
            ]
        success_lines.append(
            "Boundary: one normal disposable Work; Queue/Steer/direct-shell Stop and remote "
            "backends not exercised.")
    except BaseException as error:
        primary_error = error
        with capture.lock:
            diagnostic_spans = list(capture.spans)
            request_count = len(capture.provider_requests)
            diagnostic_requests = list(capture.provider_requests)
        diagnostics = collections.Counter(
            (span.name, attributes(span.attributes).get("aviary.outcome", "unset"))
            for _, span in diagnostic_spans
            if span.name in REQUIRED_SPANS
        )
        print(f"Bounded journey diagnostic: provider_requests={request_count}", file=sys.stderr)
        tool_results = "\n".join(
            str(message.get("content", ""))
            for request in diagnostic_requests
            for message in request["body"].get("messages", [])
            if message.get("role") == "tool"
        )
        for error_type in (
            "PermissionError", "FileNotFoundError", "SyntaxError", "NameError",
            "ModuleNotFoundError", "RuntimeError", "TypeError", "TimeoutError",
        ):
            if error_type in tool_results:
                print("  tool_error_class=" + error_type, file=sys.stderr)
        for (name, outcome), count in sorted(diagnostics.items()):
            safe_outcome = outcome if outcome in {
                "unset", "accepted", "completed", "succeeded", "failed", "rejected",
                "unavailable", "indeterminate", "duplicate", "cancelled",
            } else "unclassified"
            print(f"  {name}: {safe_outcome} x{count}", file=sys.stderr)
    finally:
        cleanup_error = None
        try:
            candidates = ([daemon_pid] if daemon_pid is not None else [])
            if not candidates:
                try:
                    candidates.append(endpoint_pid(root / "home", timeout=0.5))
                except RuntimeError:
                    pass
            candidates += [
                pid for pid in owned_daemon_pids(daemon, root / "home") if pid not in candidates
            ]
            for candidate in candidates:
                cleanup_owned_processes(candidate, daemon, root / "home")
        except BaseException as error:
            cleanup_error = error
        for server, thread in ((provider, provider_thread), (collector, collector_thread)):
            if server is not None:
                try:
                    stop_server(server, thread)
                except BaseException as error:
                    cleanup_error = cleanup_error or error
        if unreachable_reservation is not None:
            try:
                unreachable_reservation.close()
            except BaseException as error:
                cleanup_error = cleanup_error or error
        if cleanup_error is None:
            shutil.rmtree(root)
        if primary_error is not None:
            raise primary_error
        if cleanup_error is not None:
            raise cleanup_error
    full_elapsed = time.monotonic() - full_started
    if journey_elapsed is None:
        raise RuntimeError("live journey timing receipt was unavailable")
    success_lines = (success_lines or []) + [
        "Monotonic timing receipt: "
        f"mode={mode} journey_seconds={journey_elapsed:.3f} "
        f"through_full_cleanup_seconds={full_elapsed:.3f}",
    ]
    for line in success_lines or []:
        print(line)


if __name__ == "__main__":
    main()
