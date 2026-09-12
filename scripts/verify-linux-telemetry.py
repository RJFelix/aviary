# /// script
# requires-python = ">=3.11"
# dependencies = ["opentelemetry-proto==1.44.0"]
# ///
"""Verify Mac client -> SSH forwards -> Linux aviaryd OTLP parent propagation.

Usage:
    uv run scripts/verify-linux-telemetry.py \
        --probe .build/arm64-apple-macosx/release/AviaryMacTransportProbe \
        --remote-snapshot /home/azureuser/aviary-linux-final-YYYYMMDD-HHMM \
        --remote-aviaryd /home/azureuser/aviary-linux-final-YYYYMMDD-HHMM/aviaryd

The collector, Unix socket, SSH forwards, daemon home, and daemon process are disposable. The
remote paths are explicit inputs so this script never silently tests an older snapshot or binary.
"""

from __future__ import annotations

import argparse
import http.server
import os
import pathlib
import re
import shlex
import selectors
import socket
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass

from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest


HOST = "azureuser@13.72.85.209"
KEY = "/Users/ryan/duckbill/untracked/costlab_ed25519"


@dataclass(frozen=True)
class ReceivedSpan:
    service: str
    name: str
    trace_id: bytes
    span_id: bytes
    parent_span_id: bytes
    kind: int
    strings: tuple[str, ...]


def free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def protobuf_string_values(message) -> list[str]:
    values: list[str] = []
    for attribute in message.attributes:
        value = attribute.value
        if value.HasField("string_value"):
            values.append(value.string_value)
    return values


def resource_service_name(resource) -> str:
    for attribute in resource.attributes:
        if attribute.key != "service.name":
            continue
        if attribute.value.HasField("string_value"):
            return attribute.value.string_value
    return ""


class Collector(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self, address):
        self.spans: list[ReceivedSpan] = []
        self.failures: list[str] = []
        self.lock = threading.Lock()

        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if self.path != "/v1/traces" or not 0 < length <= 8 * 1024 * 1024:
                        raise ValueError("invalid OTLP request")
                    self.connection.settimeout(5)
                    body = self.rfile.read(length)
                    if len(body) != length:
                        raise ValueError("incomplete OTLP request")
                    request = ExportTraceServiceRequest.FromString(body)
                    captured: list[ReceivedSpan] = []
                    for resource_spans in request.resource_spans:
                        service = resource_service_name(resource_spans.resource)
                        for scope_spans in resource_spans.scope_spans:
                            for span in scope_spans.spans:
                                captured.append(ReceivedSpan(
                                    service=service,
                                    name=span.name,
                                    trace_id=bytes(span.trace_id),
                                    span_id=bytes(span.span_id),
                                    parent_span_id=bytes(span.parent_span_id),
                                    kind=span.kind,
                                    strings=tuple(
                                        protobuf_string_values(span)
                                        + [
                                            value
                                            for event in span.events
                                            for value in protobuf_string_values(event)
                                        ]),
                                ))
                    with owner.lock:
                        if len(owner.spans) + len(captured) > 4096:
                            raise ValueError("collector capture capacity exceeded")
                        owner.spans.extend(captured)
                    self.send_response(200)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                except Exception:
                    with owner.lock:
                        owner.failures.append("collector rejected a malformed request")
                    self.send_error(400)

        super().__init__(address, Handler)
        self.daemon_threads = True

    def snapshot(self) -> tuple[list[ReceivedSpan], list[str]]:
        with self.lock:
            return list(self.spans), list(self.failures)


def ssh_base(key: str) -> list[str]:
    return [
        "ssh", "-i", key,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ExitOnForwardFailure=yes",
    ]


def run_ssh(key: str, *arguments: str, timeout: float = 10) -> subprocess.CompletedProcess:
    return subprocess.run(
        # OpenSSH joins trailing argv elements into one remote command. Quote that command
        # ourselves so `sh -c` receives its complete script rather than space-split fragments.
        ssh_base(key) + [HOST, shlex.join(list(arguments))],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=timeout,
        check=False,
    )


def read_remote_ready(process: subprocess.Popen, deadline: float) -> tuple[str, str]:
    if process.stdout is None:
        raise RuntimeError("daemon stdout was not captured")
    fd = process.stdout.fileno()
    os.set_blocking(fd, False)
    selector = selectors.DefaultSelector()
    try:
        selector.register(fd, selectors.EVENT_READ)
        pending = b""
        while time.monotonic() < deadline:
            events = selector.select(max(0.0, deadline - time.monotonic()))
            if not events:
                break
            try:
                chunk = os.read(fd, 8192)
            except BlockingIOError:
                continue
            if not chunk:
                if process.poll() is not None:
                    raise RuntimeError("remote aviaryd exited before readiness")
                time.sleep(0.05)
                continue
            pending += chunk
            if len(pending) > 64 * 1024:
                raise RuntimeError("remote aviaryd readiness output exceeded its bound")
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                text = line.decode("utf-8", errors="replace")
                match = re.search(r"\bhost=([^ ]+)\b.*\bendpoint=([^ ]+)", text)
                if match:
                    return match.group(1), match.group(2)
        raise RuntimeError("remote aviaryd readiness timed out")
    finally:
        selector.close()


def stop_remote_daemon(
    key: str, pid_path: str, expected_binary: str, remote_home: str,
    process: subprocess.Popen | None,
) -> bool:
    # The pid file is inside this invocation's private remote root. No process discovery or
    # broad pkill is used. The remote helper independently polls the exact owned PID even if the
    # original SSH session has already exited, and verifies both argv0 and --agent-home's next
    # argument before either signal.
    cleanup_script = (
        "pid_file={pid}; binary={binary}; expected_home={home}; "
        "pid=$(cat -- \"$pid_file\" 2>/dev/null) || exit 1; "
        "case $pid in (*[!0-9]*|'') exit 1;; esac; "
        "state() {{ "
        "test -s \"$pid_file\" || {{ printf NEVER; return; }}; "
        "recorded_pid=$(cat -- \"$pid_file\" 2>/dev/null) || {{ printf FAILED; return; }}; "
        "[ \"$recorded_pid\" = \"$pid\" ] || {{ printf FAILED; return; }}; "
        "test -r /proc/$pid/cmdline || {{ printf STOPPED; return; }}; "
        "exe=$(readlink -- /proc/$pid/exe 2>/dev/null || true); "
        "first=$(tr '\\000' '\\n' < /proc/$pid/cmdline 2>/dev/null | sed -n '1p'); "
        "home_arg=$(tr '\\000' '\\n' < /proc/$pid/cmdline 2>/dev/null | "
        "awk 'previous == \"--agent-home\" {{ print; exit }} {{ previous = $0 }}'); "
        "if [ \"$exe\" != \"$binary\" ] || [ \"$first\" != \"$binary\" ] || "
        "[ \"$home_arg\" != \"$expected_home\" ]; then printf NOT_OWNED; return; fi; "
        "printf ALIVE; }}; "
        "wait_stopped() {{ i=0; while [ $i -lt 40 ]; do s=$(state); "
        "case $s in NEVER|STOPPED) printf STOPPED; return;; NOT_OWNED|FAILED) printf FAILED; return;; esac; "
        "i=$((i + 1)); sleep 0.1; done; printf FAILED; }}; "
        "s=$(state); case $s in NEVER|STOPPED) printf STOPPED;; "
        "NOT_OWNED|FAILED) printf FAILED;; ALIVE) "
        "/bin/kill -TERM -- \"$pid\" 2>/dev/null || true; "
        "s=$(wait_stopped); if [ \"$s\" = STOPPED ]; then printf STOPPED; else "
        "s=$(state); if [ \"$s\" = ALIVE ]; then "
        "/bin/kill -KILL -- \"$pid\" 2>/dev/null || true; "
        "wait_stopped; else case $s in NEVER|STOPPED) printf STOPPED;; *) printf FAILED;; esac; "
        "fi; fi;; esac"
    ).format(
        pid=shlex.quote(pid_path), binary=shlex.quote(expected_binary),
        home=shlex.quote(remote_home))
    stopped = False
    try:
        result = subprocess.run(
            ssh_base(key) + [HOST, shlex.join(["sh", "-c", cleanup_script])],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=55, check=False)
        stopped = result.returncode == 0 and result.stdout.strip() == b"STOPPED"
    except (OSError, subprocess.SubprocessError):
        stopped = False
    if process is not None:
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                stopped = False
    return stopped


def stop_local_process(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def wait_for_streamlocal_forward(
    process: subprocess.Popen, socket_path: pathlib.Path, deadline: float
) -> None:
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("SSH streamlocal/reverse forwarding failed")
        if socket_path.exists():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.settimeout(1)
                    probe.connect(str(socket_path))
                return
            except OSError:
                pass
        time.sleep(0.05)
    raise RuntimeError("SSH streamlocal forwarding readiness timed out")


def wait_for_collector_services(collector: Collector, deadline: float) -> list[ReceivedSpan]:
    while time.monotonic() < deadline:
        spans, failures = collector.snapshot()
        if failures:
            raise RuntimeError("collector rejected an OTLP payload")
        services = {span.service for span in spans}
        has_client = any(
            span.service == "aviary" and span.name.startswith("aviary.work.")
            and span.kind == 3 for span in spans)
        has_server = any(
            span.service == "aviaryd" and span.name.startswith("aviary.work.")
            and span.kind == 2 for span in spans)
        if {"aviary", "aviaryd"}.issubset(services) and has_client and has_server:
            return spans
        time.sleep(0.05)
    spans, _ = collector.snapshot()
    return spans


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, help="current locally-built Mac probe binary")
    parser.add_argument("--remote-snapshot", required=True, help="current remote source snapshot")
    parser.add_argument("--remote-aviaryd", required=True, help="aviaryd binary inside that snapshot")
    parser.add_argument("--ssh-key", default=KEY, help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    probe = pathlib.Path(args.probe).resolve(strict=True)
    remote_snapshot = args.remote_snapshot
    remote_aviaryd = args.remote_aviaryd
    if not remote_snapshot.startswith("/") or not remote_aviaryd.startswith("/"):
        raise RuntimeError("remote snapshot and binary must be absolute paths")
    snapshot_prefix = remote_snapshot.rstrip("/") + "/"
    if not remote_aviaryd.startswith(snapshot_prefix):
        raise RuntimeError("remote aviaryd must be inside the supplied snapshot")
    if not pathlib.Path(args.ssh_key).is_file():
        raise RuntimeError("SSH key is unavailable")

    token = next(tempfile._get_candidate_names())
    local_root = pathlib.Path(tempfile.mkdtemp(
        prefix="aviary-linux-telemetry-", dir="/tmp"))
    os.chmod(local_root, 0o700)
    local_socket = local_root / "forward.sock"
    collector = Collector(("127.0.0.1", 0))
    collector_thread = threading.Thread(target=collector.serve_forever, daemon=True)
    collector_thread.start()
    collector_port = int(collector.server_address[1])
    remote_root = f"/tmp/aviary-otlp-verify-{token}"
    remote_socket_root = f"{remote_root}/sockets"
    remote_home = f"{remote_root}/home"
    remote_pid = f"{remote_root}/aviaryd.pid"
    remote_otel_port = free_tcp_port()
    tunnel: subprocess.Popen | None = None
    daemon: subprocess.Popen | None = None
    daemon_log = None
    remote_stopped = False
    try:
        daemon_log = tempfile.TemporaryFile()
        daemon_script = (
            "umask 077; mkdir -p {root} {sockets} {home}; echo $$ > {pid}; exec env "
            "AVIARY_OTEL_ENABLED=1 "
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:{port}/v1/traces "
            "{binary} --agent-home {home} --socket-root {sockets}"
        ).format(
            root=shlex.quote(remote_root), sockets=shlex.quote(remote_socket_root),
            home=shlex.quote(remote_home), pid=shlex.quote(remote_pid),
            port=remote_otel_port, binary=shlex.quote(remote_aviaryd),
        )
        daemon = subprocess.Popen(
            ssh_base(args.ssh_key) + [HOST, shlex.join(["sh", "-c", daemon_script])],
            stdout=subprocess.PIPE, stderr=daemon_log)
        expected_host, remote_socket = read_remote_ready(daemon, time.monotonic() + 20)

        # Endpoint naming is daemon-owned and includes its persisted host/start identity. Wait
        # for that exact path, then create the streamlocal plus reverse-TCP forwards together.
        tunnel = subprocess.Popen(
            ssh_base(args.ssh_key) + [
                "-N", "-T",
                "-L", f"{local_socket}:{remote_socket}",
                "-R", f"{remote_otel_port}:127.0.0.1:{collector_port}",
                HOST,
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for_streamlocal_forward(tunnel, local_socket, time.monotonic() + 8)

        environment = dict(os.environ)
        environment.update({
            "AVIARY_OTEL_ENABLED": "1",
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT":
                f"http://127.0.0.1:{collector_port}/v1/traces",
            "AVIARY_MAC_LINUX_STREAMLOCAL_SOCKET": str(local_socket),
            "AVIARY_MAC_LINUX_EXPECTED_HOST": expected_host,
            "AVIARY_MAC_LINUX_CLIENT_ID": "mac-linux-telemetry-probe",
        })
        probe_result = subprocess.run(
            [str(probe)], env=environment, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=40, check=False)
        if probe_result.returncode != 0:
            raise RuntimeError("Mac transport probe failed")

        # Give the client shutdown and daemon's signal-driven telemetry drain bounded time.
        remote_stopped = stop_remote_daemon(
            args.ssh_key, remote_pid, remote_aviaryd, remote_home, daemon)
        daemon = None
        spans = wait_for_collector_services(collector, time.monotonic() + 5)
        _, failures = collector.snapshot()
        if failures:
            raise RuntimeError("collector rejected an OTLP payload")
        if not spans:
            raise RuntimeError("collector received no spans")

        services = {span.service for span in spans}
        if not {"aviary", "aviaryd"}.issubset(services):
            raise RuntimeError("collector did not receive both aviary and aviaryd services")
        private_markers = (str(local_root), remote_snapshot, remote_aviaryd, "/tmp/")
        if any(marker and marker in value for span in spans for value in span.strings for marker in private_markers):
            raise RuntimeError("private path material appeared in OTLP strings")

        client_spans = [
            span for span in spans
            if span.service == "aviary" and span.name.startswith("aviary.work.") and span.kind == 3
        ]
        server_spans = [
            span for span in spans
            if span.service == "aviaryd" and span.name.startswith("aviary.work.") and span.kind == 2
        ]
        if not client_spans or not server_spans:
            raise RuntimeError("collector did not receive client/server Work spans")
        for server in server_spans:
            matches = [
                client for client in client_spans
                if client.name == server.name
                and client.trace_id == server.trace_id
                and server.parent_span_id == client.span_id
            ]
            if len(matches) != 1:
                raise RuntimeError("a Linux server span lacked its exact Mac client parent")
        print(
            f"OTLP Mac->SSH->Linux PASS: {len(spans)} spans; "
            f"{len(client_spans)} client / {len(server_spans)} server Work spans; "
            f"services={','.join(sorted(services))}")
        print("Boundary: current explicit probe, current remote aviaryd, streamlocal + reverse TCP SSH forwards, standard OTLP protobuf collector.")
    finally:
        remote_stopped = stop_remote_daemon(
            args.ssh_key, remote_pid, remote_aviaryd, remote_home, daemon)
        stop_local_process(tunnel)
        collector.shutdown()
        collector.server_close()
        collector_thread.join(timeout=5)
        if remote_stopped:
            try:
                run_ssh(args.ssh_key, "rm", "-rf", "--", remote_root, timeout=10)
            except (OSError, subprocess.SubprocessError):
                pass
        else:
            print("retained remote fixture root because daemon shutdown was not verified")
        if daemon_log is not None:
            daemon_log.close()
        try:
            local_socket.unlink(missing_ok=True)
            local_root.rmdir()
        except OSError:
            pass
        if not remote_stopped:
            raise RuntimeError("remote fixture shutdown was not verified; retained its private root")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError, TimeoutError) as error:
        print(f"OTLP Mac->SSH->Linux verification failed: {error}")
        raise SystemExit(1)
