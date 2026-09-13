"""Shared local adapter for a Work-owned child Handle.

This module deliberately contains no host or transport state.  Each runtime supplies a
session-aware ``call_app(kind, **payload)`` closure, and the adapter remains a local observer:
``cancel`` never sends a durable Work command.  Keeping the adapter here makes the reference
and shared-interpreter hosts expose the same Future contract.
"""

from __future__ import annotations

import base64
import concurrent.futures
import hashlib
import math
import threading
import time
import uuid


MAX_BODY_BYTES = 8 * 1024 * 1024
MAX_CHUNK_BYTES = 256 * 1024


class WorkAgentFuture(concurrent.futures.Future):
    """A Future that observes a Work Handle without owning its execution."""

    aviary_label = None
    aviary_notified = False
    aviary_notify_limit = 1500

    def __init__(self, call_app):
        super().__init__()
        self._aviary_call_app = call_app

    def notify(self, label=None):
        """Deliver a bounded completion to the owning conversation when it settles."""
        if label is not None:
            self.aviary_label = label
        if self.aviary_notified:
            return self
        self.aviary_notified = True
        self._aviary_call_app("dispatched")

        def deliver(done):
            try:
                outcome = done.result()
            except Exception as exc:
                outcome = "failed: %s" % (exc,)
            text = outcome if isinstance(outcome, str) else repr(outcome)
            if len(text) > self.aviary_notify_limit:
                text = (text[:self.aviary_notify_limit]
                        + "\n\n[truncated: %d characters in total. The whole value is still "
                          "on the Future in your namespace — .result() has it.]" % len(text))
            name = self.aviary_label or "a background task"
            self._aviary_call_app("notify", text="[%s finished]\n\n%s" % (name, text))

        self.add_done_callback(deliver)
        return self


class WorkAgentWorkFuture(WorkAgentFuture):
    """A local observer of a Work-owned Handle, not ownership of execution."""

    def result(self, timeout=None):
        with self._aviary_interest_lock:
            self._aviary_waiters += 1
        try:
            return super().result(timeout=timeout)
        finally:
            with self._aviary_interest_lock:
                self._aviary_waiters -= 1

    def cancel(self):
        # Durable cancellation is an explicit Work command, never an observer-side Future
        # operation.  This mirrors the reference host and prevents a local timeout from
        # masquerading as execution control.
        return False


def _work_result(handle_id, call_app):
    body = bytearray()
    expected_digest = None
    expected_count = None
    while True:
        page = call_app("agent_handle_result", id=handle_id, offset=len(body))
        if not isinstance(page, dict) or "error" in page:
            raise RuntimeError(page.get("error", "Invalid Handle body response")
                               if isinstance(page, dict) else "Invalid Handle body response")
        count = page.get("byte_count")
        digest = page.get("body_digest")
        if (type(count) is not int or not 0 <= count <= MAX_BODY_BYTES
                or not isinstance(digest, str) or page.get("id") != handle_id
                or page.get("offset") != len(body)):
            raise RuntimeError("Invalid Handle body identity or bound")
        if expected_digest is None:
            expected_digest, expected_count = digest, count
        if digest != expected_digest or count != expected_count:
            raise RuntimeError("Handle body changed while reading")
        try:
            chunk = base64.b64decode(page.get("data_base64", ""), validate=True)
        except Exception:
            raise RuntimeError("Invalid Handle body encoding") from None
        end = len(body) + len(chunk)
        if (len(chunk) > MAX_CHUNK_BYTES or end > count or page.get("next_offset") != end
                or type(page.get("eof")) is not bool or page["eof"] != (end == count)
                or (not chunk and end != count)):
            raise RuntimeError("Invalid Handle body progress")
        body.extend(chunk)
        if page["eof"]:
            if hashlib.sha256(body).hexdigest() != digest.removeprefix("sha256:"):
                raise RuntimeError("Handle body digest mismatch")
            try:
                return body.decode("utf-8")
            except UnicodeDecodeError:
                raise RuntimeError("Handle body is not UTF-8") from None


def make_work_future(record, call_app):
    """Validate an admission/observation record and start one local polling observer."""
    handle_id, deadline = record.get("id"), record.get("deadline")
    if (not isinstance(handle_id, str) or not handle_id or len(handle_id.encode()) > 256
            or "deadline" not in record
            or (deadline is not None
                and (type(deadline) not in (float, int) or not math.isfinite(deadline)))):
        raise RuntimeError("Invalid Work Handle admission response")

    future = WorkAgentWorkFuture(call_app)
    future.aviary_id = handle_id
    future.aviary_name = record.get("name")
    future.aviary_deadline = deadline
    future.aviary_ownership = "work"
    future._aviary_observer_id = uuid.uuid4().hex
    future._aviary_interest_lock = threading.Lock()
    future._aviary_waiters = 0
    future.set_running_or_notify_cancel()

    def watch():
        try:
            last_interest = False
            while True:
                with future._aviary_interest_lock:
                    interest = future._aviary_waiters > 0
                if interest != last_interest:
                    call_app("agent_handle_await", id=handle_id,
                             observer_id=future._aviary_observer_id, awaited=interest)
                    last_interest = interest
                row = call_app("agent_handle_status", id=handle_id)
                if not isinstance(row, dict) or "error" in row:
                    raise RuntimeError(row.get("error", "Handle state unavailable")
                                       if isinstance(row, dict) else "Handle state unavailable")
                if (row.get("id") != handle_id or row.get("ownership") != "work"
                        or "deadline" not in row
                        or (row["deadline"] is not None
                            and (type(row["deadline"]) not in (float, int)
                                 or not math.isfinite(row["deadline"])))
                        or row.get("deadline") != deadline):
                    raise RuntimeError("Handle observation identity changed")
                state = row.get("state")
                if state == "terminal":
                    if row.get("outcome") == "succeeded":
                        future.set_result(_work_result(handle_id, call_app))
                        return
                    if row.get("outcome") == "limited":
                        reason = {
                            "tokenThresholdReached": "token threshold reached",
                            "costThresholdReached": "cost threshold reached",
                            "tokenAccountingUnknown": "token accounting unknown",
                            "costAccountingUnknown": "cost accounting unknown",
                        }.get(row.get("limit_reason"), "execution limit reached")
                        raise RuntimeError("Work Handle was limited (%s)" % reason)
                    reason = {"failed": "failed", "canceled": "canceled",
                              "expired": "expired"}.get(
                                  row.get("outcome"), "unsuccessful")
                    raise RuntimeError(
                        "Work Handle did not complete successfully (%s)" % reason)
                if state == "reaped":
                    raise RuntimeError("Work Handle was reaped; its tombstone remains recorded")
                if state not in ("queued", "running", "cancel_requested"):
                    raise RuntimeError("Work Handle state is unavailable or unknown")
                time.sleep(0.5)
        except Exception as exc:
            future.set_exception(exc)

    threading.Thread(target=watch).start()
    return future
