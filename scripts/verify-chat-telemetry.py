# /// script
# requires-python = ">=3.11"
# dependencies = ["opentelemetry-proto==1.44.0"]
# ///
"""Run Aviary's isolated AppModel probe against a disposable standard OTLP collector.

Usage: uv run scripts/verify-chat-telemetry.py build/Aviary.app/Contents/MacOS/Aviary
Last verified: 2026-09-11. Does not start the user's Work or select a permanent backend.
"""
import collections
import hashlib
import http.server
import os
import pathlib
import subprocess
import sys
import tempfile
import threading

from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest


def main():
    binary = pathlib.Path(sys.argv[1]).resolve(strict=True)
    spans = []
    failures = []
    lock = threading.Lock()

    class Collector(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if self.path != "/v1/traces" or not 0 < length <= 8 * 1024 * 1024:
                    raise ValueError("invalid collector request")
                self.connection.settimeout(5)
                body = self.rfile.read(length)
                if len(body) != length:
                    raise ValueError("incomplete collector body")
                message = ExportTraceServiceRequest.FromString(body)
                batch = [span for resource in message.resource_spans
                         for scope in resource.scope_spans for span in scope.spans]
                with lock:
                    if len(spans) + len(batch) > 4096:
                        raise ValueError("collector capture capacity exceeded")
                    spans.extend(batch)
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()
            except Exception:
                with lock:
                    failures.append("collector rejected a malformed or excessive request")
                self.send_error(400)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Collector)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment = dict(os.environ)
    environment.update({
        "AVIARY_OTEL_ENABLED": "1",
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/traces",
    })
    try:
        with tempfile.TemporaryFile() as output:
            result = subprocess.run([str(binary), "--chat-journey-probe"], env=environment,
                                    stdout=output, stderr=output, timeout=120, check=False)
            if result.returncode != 0:
                raise RuntimeError(f"AppModel journey probe exited {result.returncode}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    if failures:
        raise RuntimeError(failures[0])
    names = collections.Counter(span.name for span in spans)
    saves = [span for span in spans if span.name == "aviary.gui.pending_chat.save"]

    def attrs(span):
        return {entry.key: entry.value.string_value for entry in span.attributes}

    if not any(attrs(span).get("aviary.outcome") == "completed" for span in saves):
        raise RuntimeError("collector did not receive a successful real local-save span")
    if not any(attrs(span).get("aviary.outcome") == "failed" for span in saves):
        raise RuntimeError("collector did not receive the real failed-save span")
    startups = [span for span in spans if span.name == "aviary.gui.pending_chat.startup"]
    if not startups or not all(not span.parent_span_id for span in startups):
        raise RuntimeError("startup attempts were missing or not independent roots")
    if not all(attrs(span).get("aviary.outcome") in {"rejected", "unavailable", "indeterminate"}
               for span in startups):
        raise RuntimeError("blocked startup was not truthfully classified")
    reviews = [span for span in spans if span.name == "aviary.gui.repository_review.load"]
    histories = [span for span in spans if span.name == "aviary.gui.history.load_earlier"]
    if collections.Counter(attrs(span).get("aviary.outcome") for span in reviews) != {
            "unavailable": 2, "succeeded": 1}:
        raise RuntimeError("repository consumer outcomes did not preserve bounded/success/stale results")
    if len(histories) != 1 or attrs(histories[0]).get("aviary.outcome") != "unavailable":
        raise RuntimeError("history failure consumer scope missing or repeated by refresh/jump")
    session_hash = hashlib.sha256(b"consumer-telemetry-session").hexdigest()
    artifact_hash = hashlib.sha256(b"consumer-review-artifact").hexdigest()
    for span in reviews + histories:
        values = attrs(span)
        if span.parent_span_id or values.get("aviary.session.id") != session_hash:
            raise RuntimeError("consumer trace had unrelated parent or Session identity")
        work_hash = values.get("aviary.work.id", "")
        if len(work_hash) != 64 or any(c not in "0123456789abcdef" for c in work_hash):
            raise RuntimeError("consumer Work identity missing or not hashed")
        expected_target = "work" if span in reviews else "session"
        if values.get("aviary.read.target") != expected_target:
            raise RuntimeError("consumer read target was misclassified")
        if span in reviews and values.get("aviary.artifact.id") != artifact_hash:
            raise RuntimeError("consumer artifact identity was not exact")
    for span in spans:
        for entry in list(span.attributes) + [attr for event in span.events for attr in event.attributes]:
            value = entry.value.string_value
            if any(secret in value for secret in ["/tmp/", "/var/folders/", "keep this in the editor",
                                                   "preserve this initial prompt", "Preserve this exact request",
                                                   "consumer-telemetry-work", "consumer-telemetry-session",
                                                   "consumer-review-artifact"]):
                raise RuntimeError("private fixture content appeared in exported attributes")
    print(f"OTLP AppModel probe PASS: {len(spans)} spans; {len(saves)} saves; {len(startups)} blocked startups")
    for name, count in sorted(names.items()):
        print(f"  {name}: {count}")
    print("Boundary: real AppModel save/relaunch/blocked-start paths; no live provider or production Work.")


if __name__ == "__main__":
    main()
