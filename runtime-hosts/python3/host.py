#!/usr/bin/env python3
"""
A runtime host: one process, one isolated interpreter per session, a line protocol on a Unix
domain socket. Clients may disconnect and later adopt the same host process.

Why this exists, and why it is a separate process rather than a library linked into Aviary:

  * Isolation per session. CPython 3.12 gives each sub-interpreter its own GIL (PEP 684),
    measured here at 3.85x on four concurrent interpreters — so sessions run genuinely in
    parallel without a process each.
  * Crash isolation for the GUI. Linking libpython into Aviary would mean a segfault in a C
    extension takes the window, the board and the transcripts with it. Aviary's stated
    invariant is that it stays usable when the agent side is wedged; a helper process keeps
    that, and costs only a pipe.
  * A swappable contract. Everything Aviary knows about a runtime is the protocol in
    docs/runtime-host-protocol.md. A Lua, QuickJS or WASM host that speaks it is a drop-in,
    which is the point: the runtime becomes something to experiment with rather than a
    foundation to commit to.

What this replaces: a Jupyter kernel reached over ZeroMQ, in a process per session, paying a
full `ipykernel_launcher` boot each time (the harness's fork-server is Linux-only, so macOS
always pays it), with namespace introspection that had to execute user-visible code and so
perturbed the thing it measured.

Protocol: one JSON object per line over the socket. Requests carry an `id` and get exactly one
response with the same `id`. Output arrives as unsolicited `event` lines before the response,
so a caller can stream. LF only — never \r\n, and never a bare \r. The socket client may go
away without stopping this process or its sessions.
"""

from __future__ import annotations

import json
import errno
import os
import queue
import select
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
from collections import OrderedDict

try:
    import _xxsubinterpreters as subinterpreters  # 3.12
except ImportError:  # pragma: no cover - newer Pythons renamed it
    try:
        import _interpreters as subinterpreters  # 3.13+
    except ImportError:
        subinterpreters = None

PROTOCOL_VERSION = 3
MAX_FRAME_BYTES = 4 * 1024 * 1024
MAX_DIAGNOSTIC_BYTES = 500
MAX_SEND_SECONDS = 1.0
SEND_CHUNK_BYTES = 512


def install_parent_lifetime_lease(parent_pid: int | None, socket_path: str) -> None:
    """Exit this test-owned host when its launching process goes away.

    This is deliberately opt-in and activated only by RuntimeHost's test launch flag. Normal
    hosts have no parent-lifetime lease: a GUI/client disconnect must leave real Work alive for a
    later adopter.
    """
    if parent_pid is None:
        return
    if parent_pid <= 0 or os.getppid() != parent_pid:
        raise RuntimeError("invalid parent lifetime lease")

    def watch() -> None:
        # Capture the exact socket inode after the host has bound it. On lease expiry, unlink
        # only that same user-owned Unix socket; never remove a path that another process may
        # have installed after this host exited. The short lstat/unlink race is contained by the
        # private, mode-0700 runtime directory and the inode check immediately before unlink.
        owned_socket: tuple[int, int] | None = None

        def observe_owned_socket() -> tuple[int, int] | None:
            try:
                current = os.lstat(socket_path)
                if (stat.S_ISSOCK(current.st_mode)
                        and current.st_uid == os.getuid()):
                    return (current.st_dev, current.st_ino)
            except OSError:
                pass
            return None

        while os.getppid() == parent_pid:
            if owned_socket is None:
                owned_socket = observe_owned_socket()
            time.sleep(0.1)
        # The launcher can disappear immediately after observing bind, before this 100 ms
        # watcher has sampled the inode. The host is still serving at this point, so take one
        # final ownership sample before the identity-checked unlink instead of leaving a stale
        # endpoint behind merely because the parent lifetime was very short.
        if owned_socket is None:
            owned_socket = observe_owned_socket()
        if owned_socket is not None:
            try:
                current = os.lstat(socket_path)
                if (stat.S_ISSOCK(current.st_mode)
                        and current.st_uid == os.getuid()
                        and (current.st_dev, current.st_ino) == owned_socket):
                    os.unlink(socket_path)
            except OSError:
                pass
        # This path is intentionally abrupt and test-only. It prevents a dead SelfTest parent
        # from leaving an adoptable host running with no durable owner.
        os._exit(0)

    threading.Thread(target=watch, name="parent-lifetime-lease", daemon=True).start()


def bounded_diagnostic(value, limit: int = MAX_DIAGNOSTIC_BYTES) -> str:
    """Return a bounded, text-only diagnostic for the host protocol and stderr tail."""
    return str(value)[:limit]


def encoded_frame_size(obj: dict) -> int:
    return len(json.dumps(obj, ensure_ascii=False, default=str).encode("utf-8")) + 1

# Everything the host puts into the agent's namespace. Listed once, because `inspect` must
# hide exactly this set: the namespace belongs to the agent, and a host whose own helpers show
# up in it is lying about what the agent put there. Adding a helper without adding it here is
# how that contract quietly breaks.
_AVIARY_INJECTED = frozenset({"sh", "cwd", "ask_app", "spawn", "attach_agent", "conversation",
                              "remember", "recall", "artifact", "attach_image",
                              "agents", "message", "search", "read_url"})

# Callbacks in flight: a runtime asked Aviary for something and is blocked on the answer.
#
# This is the channel that lets agent code reach back into the app — spawning a sub-agent,
# reading the conversation it is part of, asking a person a question. Without it a runtime can
# only compute; with it the runtime is where an agent's whole behaviour can live, which is the
# point of making the environment programmable in the first place.
_callbacks: dict = {}
_callback_lock = threading.Lock()
_callback_seq = [0]
_callback_sender = None
_callback_history = OrderedDict()
_CALLBACK_HISTORY_LIMIT = 1024
# A callback may legitimately resolve to JSON null. Keep pending state out-of-band rather than
# overloading None, or a null reply is indistinguishable from no reply and waits until timeout.
_CALLBACK_PENDING = object()


def set_callback_sender(sender) -> None:
    """Install the host's session-aware callback router."""
    global _callback_sender
    _callback_sender = sender


def _send_callback(session: str, message: dict) -> None:
    sender = _callback_sender
    if sender is None:
        emit(message)
    else:
        sender(session, message)


def pending_callback_messages(session: str) -> list[dict]:
    with _callback_lock:
        return [entry["message"] for entry in _callbacks.values()
                if (entry.get("session") == session
                    and entry.get("result") is _CALLBACK_PENDING)]


def _remember_callback_outcome_locked(rid: str, status: str) -> None:
    """Keep a bounded answer to late callback.result messages.

    A callback is at-least-once across a client disconnect: the same `rid` may be delivered to a
    new client after an earlier client performed an effect but lost its response. Retaining a
    small terminal history lets the host distinguish a duplicate result from an unknown/stale
    one without pretending that this process-local table is durable exactly-once state.
    """
    _callback_history[rid] = status
    _callback_history.move_to_end(rid)
    while len(_callback_history) > _CALLBACK_HISTORY_LIMIT:
        _callback_history.popitem(last=False)


def request_from_app(kind: str, payload: dict, session: str = "", timeout: float = 900.0):
    """Ask Aviary to do something, and block this session's thread until it answers.

    Blocking is correct here: the agent wrote `await spawn(...)` and expects a result. Only
    the calling session's thread waits — other sessions have their own interpreters and their
    own GILs, so a session waiting on a sub-agent does not stall the host.
    """
    with _callback_lock:
        _callback_seq[0] += 1
        rid = f"cb-{_callback_seq[0]}"
        event = threading.Event()
        message = {"event": "callback", "rid": rid, "kind": kind,
                   "payload": payload, "session": session}
        _callbacks[rid] = {
            "event": event, "result": _CALLBACK_PENDING, "session": session,
            "message": message,
        }
    # The session must travel with the request: one host serves many sessions, and a client
    # routing a callback has no other way to know which agent asked.
    _send_callback(session, message)
    if not event.wait(timeout):
        with _callback_lock:
            entry = _callbacks.get(rid)
            if entry is not None and entry.get("result") is _CALLBACK_PENDING:
                _callbacks.pop(rid, None)
                _remember_callback_outcome_locked(rid, "stale")
                return {"error": "Aviary did not answer the %s request within %ss" % (
                    bounded_diagnostic(kind, 120), int(timeout))}
            # A result won the timeout race. Return it rather than manufacturing a timeout.
            entry = _callbacks.pop(rid, None)
            if entry is not None:
                _remember_callback_outcome_locked(rid, "accepted")
                return entry.get("result")
        return {"error": "Aviary did not answer the %s request within %ss" % (
            bounded_diagnostic(kind, 120), int(timeout))}
    with _callback_lock:
        entry = _callbacks.pop(rid, None)
        if entry is not None:
            _remember_callback_outcome_locked(rid, "accepted")
    return entry.get("result") if entry is not None else {}


def resolve_callback(rid: str, result) -> dict:
    """Resolve one callback atomically and report whether this result won the race."""
    with _callback_lock:
        entry = _callbacks.get(rid)
        if entry is None:
            status = _callback_history.get(rid)
            return {"delivered": False,
                    "status": "duplicate" if status == "accepted" else "stale"}
        if entry.get("result") is not _CALLBACK_PENDING:
            return {"delivered": False, "status": "duplicate"}
        entry["result"] = result
        _remember_callback_outcome_locked(rid, "accepted")
        entry["event"].set()
        return {"delivered": True, "status": "accepted"}

# ---------------------------------------------------------------------------
# Writing to the client
# ---------------------------------------------------------------------------

_write_lock = threading.Lock()
_output_sink = threading.local()


def emit(obj: dict) -> None:
    """One JSON object, one line, flushed to the current client.

    A stdio fallback remains useful while importing this module for diagnostics, but socket
    serving never depends on a parent-owned pipe. The sink is thread-local because responses and
    output events from different sessions may be emitted concurrently.
    """
    line = json.dumps(obj, ensure_ascii=False, default=str)
    sink = getattr(_output_sink, "sink", None)
    if sink is not None:
        sink.send_obj(obj)
        return
    with _write_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


# ---------------------------------------------------------------------------
# The code that runs *inside* a sub-interpreter
# ---------------------------------------------------------------------------

# Sub-interpreters have separate object spaces: nothing crosses the boundary as an object,
# only as bytes. So every call writes its result to a file the host reads back, and its
# inputs arrive as literals assigned ahead of the body.
#
# Inputs are passed as a *prelude* of `NAME = <repr>` lines rather than formatted into the
# body. The body is full of dict and f-string braces, and `str.format` fails on the first
# one — an escaping game that must be re-won on every future edit. A prelude cannot be
# broken by anything the body contains.
#
# Host names are mangled and deleted afterwards: the namespace belongs to the agent, and a
# host that leaves its own variables in it is lying about what the agent put there.


def _prelude(**names) -> str:
    return "".join("%s = %r\n" % (k, v) for k, v in names.items())


_EXEC_BODY = r'''
import builtins, io, json, sys, traceback

__aviary_out = io.StringIO()
__aviary_err = io.StringIO()
__aviary_result = {"stdout": "", "stderr": "", "value": None, "exception": None}

# The agent's module globals, created once per session and reused, so state persists across
# calls — the entire reason this is a long-lived interpreter and not a subprocess.
if "__aviary_ns" not in globals():
    globals()["__aviary_ns"] = {"__name__": "__main__", "__builtins__": builtins}
    globals()["__aviary_session_state"] = {"cwd": __AVIARY_CWD, "env": {}}

__aviary_ns = globals()["__aviary_ns"]
__aviary_state = globals()["__aviary_session_state"]


__aviary_sh_lock = __import__("threading").Lock()


def __aviary_sh(command, timeout=None):
    # A Future, like spawn() and search(). A shell command is the commonest long-running thing
    # an agent does — a test suite, a build, a clone — and making it await-or-not is what lets
    # one cell start the slow thing and get on with reading code while it runs.
    #
    # `.result()` is the old blocking behaviour, spelled by the caller.
    import threading as _th

    future = _AviaryFuture()

    def __aviary_run_sh():
        try:
            future.set_result(__aviary_sh_blocking(command, timeout=timeout))
        except Exception as exc:
            future.set_exception(exc)

    _th.Thread(target=__aviary_run_sh).start()
    return future


def __aviary_sh_blocking(command, timeout=None):
    # Run a shell command whose working directory and environment persist.
    #
    # The measured reason this exists: 19.7% of cells in the corpus did working-directory
    # bookkeeping by hand, because subprocess starts every child in the same place. Here
    # `cd` and `export` stick for the life of the session.
    import subprocess as _sp, tempfile as _tf, os as _os, shlex as _shlex
    env = dict(_os.environ)
    env.update(__aviary_state["env"])
    with _tf.NamedTemporaryFile("w+", delete=False, suffix=".aviary-sh") as probe:
        probe_path = probe.name
    # The trailing probe reports the shell's final state, so a `cd` inside the command is
    # observed rather than inferred.
    wrapped = "\n".join([
        "cd " + _shlex.quote(__aviary_state["cwd"]) + " 2>/dev/null || cd /",
        command,
        "__aviary_status=$?",
        '{ printf "%s\\0" "$PWD"; env -0; } > ' + _shlex.quote(probe_path) + " 2>/dev/null",
        "exit $__aviary_status",
    ])
    proc = _sp.run(["/bin/sh", "-c", wrapped], capture_output=True, text=True,
                   env=env, timeout=timeout)
    try:
        raw = open(probe_path, "rb").read().decode("utf-8", "replace")
        _os.unlink(probe_path)
        parts = raw.split("\0")
        # Locked because commands can now overlap. Each one still *starts* from the cwd as of
        # its own launch, which is deterministic; it is only the write-back that races, and
        # last-finisher-wins is the honest rule. Await if you care which.
        with __aviary_sh_lock:
            if parts and parts[0]:
                __aviary_state["cwd"] = parts[0]
            base = dict(_os.environ)
            for item in parts[1:]:
                if "=" not in item:
                    continue
                k, v = item.split("=", 1)
                # Remember only what the command changed, so the session does not accumulate
                # the whole inherited environment.
                if base.get(k) != v and k not in ("_", "PWD", "SHLVL", "OLDPWD"):
                    __aviary_state["env"][k] = v
    except Exception:
        pass
    return {"stdout": proc.stdout, "stderr": proc.stderr, "status": proc.returncode}


def __aviary_ask_app(kind, **payload):
    # Objects cannot cross an interpreter boundary, so a callback is marshalled through two
    # files: this side writes the request and spins on the reply. The spin is cheap because
    # this interpreter has its own GIL — waiting here does not stall any other session.
    import json as _json, os as _os, tempfile as _tf, time as _time
    fd, req_path = _tf.mkstemp(prefix="aviary-cb-req-", suffix=".json")
    _os.close(fd)
    reply_path = req_path.replace("-req-", "-rep-")
    with open(req_path, "w") as fh:
        _json.dump({"kind": kind, "payload": payload, "reply": reply_path}, fh)
    with open(__AVIARY_CALLBACK_DIR + "/pending", "a") as fh:
        fh.write(req_path + "\n")
    deadline = _time.time() + 900
    while _time.time() < deadline:
        if _os.path.exists(reply_path):
            try:
                with open(reply_path) as fh:
                    out = _json.load(fh)
                _os.unlink(reply_path)
                return out
            except Exception:
                _time.sleep(0.02)
                continue
        _time.sleep(0.02)
    return {"error": "Aviary did not answer in time"}


__aviary_ns["sh"] = __aviary_sh
__aviary_ns["cwd"] = lambda: __aviary_state["cwd"]
__aviary_ns["ask_app"] = __aviary_ask_app
# Aliased without the double underscore because Python mangles `__name` *inside a class body*
# into `_ClassName__name`. The first live run of `.notify()` died on
# `NameError: _AviaryFuture__aviary_ask_app`, which no amount of reading the class would have
# shown.
_aviary_call_app = __aviary_ask_app


class _AviaryFuture(__import__("concurrent.futures", fromlist=["Future"]).Future):
    """A Future that can also deliver its own result back into the conversation.

    The third thing an agent wants from a slow operation, after "wait for it" and "do other
    work and then collect it": start it, stop, and be told later. `.notify()` registers a
    done-callback that sends the result to this same session as a message, which arrives at a
    turn boundary exactly as a person's would — and wakes the agent if it had already stopped.

    It lives on the Future rather than as an argument to each builtin so that it composes:
    `sh('pytest -q').notify()`, `spawn(...).notify()` and `search(...).notify()` are the same
    gesture, and a builtin added later gets it for free.
    """

    aviary_label = None
    aviary_notified = False

    #: What may cross into the conversation. Everything that lands there is a model call and
    #: then permanent context, re-sent on every later turn, so the crossing is rationed at the
    #: crossing rather than trusted to be small. `sh('cat big.log').notify()` was previously a
    #: way to put a megabyte into a transcript forever.
    aviary_notify_limit = 1500

    def notify(self, label=None):
        """Deliver this result into the conversation when it finishes.

        Idempotent: calling it twice registers one delivery, not two. Two deliveries would be
        two model calls for one event, which is the expensive kind of duplicate.
        """
        if label is not None:
            self.aviary_label = label
        if self.aviary_notified:
            return self
        self.aviary_notified = True
        # Announced up front so the run knows not to finish on a promise: an agent that
        # dispatches and stops would otherwise end before its own answer arrived.
        _aviary_call_app("dispatched")

        def __aviary_deliver(done):
            try:
                outcome = done.result()
            except Exception as exc:
                outcome = "failed: %s" % (exc,)
            text = outcome if isinstance(outcome, str) else repr(outcome)
            limit = self.aviary_notify_limit
            if len(text) > limit:
                # The whole value is still on this Future, in a namespace that persists, so the
                # message says how to reach the rest rather than carrying it.
                text = (
                    text[:limit]
                    + "\n\n[truncated: %d characters in total. The whole value is still on "
                      "the Future in your namespace — .result() has it.]" % (len(text),))
            name = self.aviary_label or "a background task"
            _aviary_call_app("notify", text="[%s finished]\n\n%s" % (name, text))

        self.add_done_callback(__aviary_deliver)
        return self


class _AviaryWorkFuture(_AviaryFuture):
    """A local observer of a Work-owned Handle, not ownership of its execution."""

    def result(self, timeout=None):
        # Interest is a scheduling hint sent by the existing observer thread. A callback
        # must not extend Future.result(timeout) or make an already-local result need a host.
        with self._aviary_interest_lock:
            self._aviary_waiters += 1
        try:
            return super().result(timeout=timeout)
        finally:
            with self._aviary_interest_lock:
                self._aviary_waiters -= 1

    def cancel(self):
        # Future.cancel() must not imply a durable Work cancellation. The separately
        # authorized service command owns that boundary, including uncertain outcomes.
        return False


def _aviary_work_result(handle_id):
    import base64 as _b64, hashlib as _hash
    body = bytearray()
    expected_digest = None
    expected_count = None
    while True:
        page = _aviary_call_app("agent_handle_result", id=handle_id, offset=len(body))
        if not isinstance(page, dict) or "error" in page:
            raise RuntimeError(page.get("error", "Invalid Handle body response")
                               if isinstance(page, dict) else "Invalid Handle body response")
        count = page.get("byte_count")
        digest = page.get("body_digest")
        if (type(count) is not int or not 0 <= count <= 8 * 1024 * 1024
                or not isinstance(digest, str) or page.get("id") != handle_id
                or page.get("offset") != len(body)):
            raise RuntimeError("Invalid Handle body identity or bound")
        if expected_digest is None:
            expected_digest, expected_count = digest, count
        if digest != expected_digest or count != expected_count:
            raise RuntimeError("Handle body changed while reading")
        chunk = _b64.b64decode(page.get("data_base64", ""), validate=True)
        end = len(body) + len(chunk)
        if (len(chunk) > 256 * 1024 or end > count or page.get("next_offset") != end
                or type(page.get("eof")) is not bool or page["eof"] != (end == count)
                or (not chunk and end != count)):
            raise RuntimeError("Invalid Handle body progress")
        body.extend(chunk)
        if page["eof"]:
            if _hash.sha256(body).hexdigest() != digest.removeprefix("sha256:"):
                raise RuntimeError("Handle body digest mismatch")
            return body.decode("utf-8")


def _aviary_make_work_future(record):
    import math as _math, threading as _th, time as _time, uuid as _uuid
    handle_id, deadline = record.get("id"), record.get("deadline")
    if (not isinstance(handle_id, str) or not handle_id or len(handle_id.encode()) > 256
            or "deadline" not in record
            or (deadline is not None
                and (type(deadline) not in (float, int) or not _math.isfinite(deadline)))):
        raise RuntimeError("Invalid Work Handle admission response")
    future = _AviaryWorkFuture()
    future.aviary_id = handle_id
    future.aviary_name = record.get("name")
    future.aviary_deadline = deadline
    future.aviary_ownership = "work"
    future._aviary_observer_id = _uuid.uuid4().hex
    future._aviary_interest_lock = _th.Lock()
    future._aviary_waiters = 0
    future.set_running_or_notify_cancel()

    def watch():
        try:
            last_interest = False
            while True:
                with future._aviary_interest_lock:
                    interest = future._aviary_waiters > 0
                if interest != last_interest:
                    _aviary_call_app("agent_handle_await", id=handle_id,
                                     observer_id=future._aviary_observer_id, awaited=interest)
                    last_interest = interest
                row = _aviary_call_app("agent_handle_status", id=handle_id)
                if not isinstance(row, dict) or "error" in row:
                    raise RuntimeError(row.get("error", "Handle state unavailable")
                                       if isinstance(row, dict) else "Handle state unavailable")
                if (row.get("id") != handle_id or row.get("ownership") != "work"
                        or "deadline" not in row
                        or (row["deadline"] is not None
                            and (type(row["deadline"]) not in (float, int)
                                 or not _math.isfinite(row["deadline"])))
                        or row.get("deadline") != deadline):
                    raise RuntimeError("Handle observation identity changed")
                state = row.get("state")
                if state == "terminal":
                    if row.get("outcome") == "succeeded":
                        future.set_result(_aviary_work_result(handle_id))
                        return
                    raise RuntimeError("Handle %s settled as %s; inspect its retained outcome" %
                                       (handle_id, row.get("outcome", "unknown")))
                if state == "reaped":
                    raise RuntimeError("Handle %s was reaped; its tombstone remains recorded" % handle_id)
                if state not in ("queued", "running", "cancel_requested"):
                    raise RuntimeError("Handle state is unavailable or unknown")
                # Scope expiry governs execution at the coordinator, not this observer.
                # Persistence can lag an on-time completion. Only canonical terminal evidence
                # settles the Future; result(timeout) bounds the caller's own wait.
                _time.sleep(0.5)
        except Exception as exc:
            future.set_exception(exc)

    _th.Thread(target=watch).start()
    return future


def __aviary_attach_agent(handle_id, name=None):
    """Observe one explicitly named Work Handle, optionally binding it without overwriting."""
    import keyword as _keyword, threading as _th
    if (not isinstance(handle_id, str) or not handle_id or len(handle_id.encode()) > 256):
        raise ValueError("attach_agent needs a bounded Handle ID")
    if name is not None and (not isinstance(name, str) or not name.isidentifier()
                             or _keyword.iskeyword(name)):
        raise ValueError("an explicit binding name must be a Python identifier")
    # The lock and sentinel are interpreter-local; no automatic rebinding on another Session.
    lock = globals().setdefault("_aviary_work_binding_lock", _th.RLock())
    sentinel = object()
    if name is not None:
        with lock:
            if name in __aviary_ns:
                raise ValueError("attach_agent will not overwrite existing binding: " + name)
            __aviary_ns[name] = sentinel
    try:
        record = _aviary_call_app("agent_handle_status", id=handle_id)
        if not isinstance(record, dict) or "error" in record:
            raise RuntimeError(record.get("error", "Handle unavailable")
                               if isinstance(record, dict) else "Handle unavailable")
        if record.get("id") != handle_id or record.get("ownership") != "work":
            raise RuntimeError("Handle attachment identity mismatch")
        future = _aviary_make_work_future(record)
        if name is not None:
            with lock:
                if __aviary_ns.get(name) is not sentinel:
                    raise RuntimeError("Binding changed during Handle attachment; no value was overwritten")
                __aviary_ns[name] = future
        return future
    except Exception:
        if name is not None:
            with lock:
                if __aviary_ns.get(name) is sentinel:
                    del __aviary_ns[name]
        raise


__aviary_ns["attach_agent"] = __aviary_attach_agent


def __aviary_spawn(prompt, name=None, model=None):
    # Returns a real `concurrent.futures.Future`, not a bespoke handle.
    #
    # The agent here is *writing Python*, not calling a sub-agent tool, so whether to wait is
    # its script's decision rather than the primitive's. A Future is the shape that says so —
    # and being the stdlib one means `.result()`, `.done()`, `wait()`, `as_completed()` and
    # `add_done_callback()` all work without this file implementing any of them.
    #
    # A blocking variant used to exist beside this. It is gone: `spawn(p).result()` is the
    # blocking call, spelled by the caller.
    import threading as _th
    import time as _time

    started = __aviary_ask_app("spawn", prompt=prompt, name=name, model=model)
    if isinstance(started, dict) and started.get("ownership") == "work" and "id" in started:
        return _aviary_make_work_future(started)
    future = _AviaryFuture()
    if not isinstance(started, dict) or "id" not in started:
        future.set_result(started)
        return future
    child_id = started["id"]
    future.aviary_id = child_id
    future.aviary_name = started.get("name")

    def __aviary_watch():
        # Polls rather than being pushed to: nothing can interrupt a turn that is already
        # running without producing a conversation the provider would reject, so the parent
        # finds out by asking. One thread per child, and threads are cheap next to an agent.
        deadline = _time.time() + 3600
        while _time.time() < deadline:
            rows = __aviary_ask_app("children")
            if isinstance(rows, dict) and "error" in rows:
                # The host is going away, or sub-agents were never enabled. Resolving with the
                # error beats a thread that outlives the session waiting for an answer nobody
                # is coming to give.
                future.set_exception(RuntimeError(rows["error"]))
                return
            for row in rows or []:
                if not isinstance(row, dict) or row.get("id") != child_id:
                    continue
                if row.get("state") == "running":
                    break
                if row.get("state") == "failed":
                    future.set_exception(RuntimeError(row.get("answer") or "the sub-agent failed"))
                else:
                    future.set_result(row.get("answer") or "")
                return
            _time.sleep(0.5)
        future.set_exception(RuntimeError("the sub-agent did not finish within an hour"))

    # Not a daemon thread: 3.12 sub-interpreters refuse them outright
    # ("daemon threads are disabled in this (sub)interpreter"), which a real run found the
    # moment the model wrote the fan-out this API invites. So the thread has to end by itself,
    # which is what the deadline and the error branch above are for — a non-daemon thread that
    # never returns would hold up the interpreter's teardown.
    _th.Thread(target=__aviary_watch).start()
    return future


__aviary_ns["spawn"] = __aviary_spawn


def __aviary_async(kind, **payload):
    # The same Future shape spawn() has, for the calls whose cost is latency rather than
    # tokens. Search and page reads are the two places an agent most obviously wants to start
    # several at once and collect them, and giving them the shape it already knows means it
    # can — `[search(q) for q in questions]` and then read the results.
    #
    # Unlike spawn there is nothing to poll: the callback itself blocks until Aviary answers,
    # so the thread runs it once and resolves. The thread exists only so the caller is not
    # blocked while it happens.
    import threading as _th

    future = _AviaryFuture()

    def __aviary_run():
        try:
            answer = __aviary_ask_app(kind, **payload)
        except Exception as exc:  # the callback channel itself failed
            future.set_exception(exc)
            return
        if isinstance(answer, dict) and "error" in answer:
            future.set_exception(RuntimeError(answer["error"]))
        else:
            future.set_result(answer)

    _th.Thread(target=__aviary_run).start()
    return future


__aviary_ns["search"] = lambda objective, queries=None, mode="fast", n=10, **rest: (
    __aviary_async(
        "search", objective=objective, queries=list(queries or []), mode=mode, n=n, **rest))
__aviary_ns["read_url"] = lambda urls, objective=None, full=False, **rest: (
    __aviary_async(
        "read_url",
        urls=[urls] if isinstance(urls, str) else list(urls),
        objective=objective, full=bool(full), **rest))
__aviary_ns["conversation"] = lambda limit=40: __aviary_ask_app("conversation", limit=limit)
__aviary_ns["remember"] = lambda text, scope="project", days=None, tags=None: __aviary_ask_app(
    "remember", text=text, scope=scope, days=days, tags=tags or [])
__aviary_ns["recall"] = lambda query="": __aviary_ask_app("recall", query=query)
__aviary_ns["attach_image"] = lambda path, note=None: __aviary_ask_app(
    "attach_image", path=str(path), note=note)
__aviary_ns["agents"] = lambda: __aviary_ask_app("agents")
__aviary_ns["message"] = lambda to, text: __aviary_ask_app(
    "message", to=str(to), text=str(text))
# Storage is Aviary's: the kernel does not know the session id or where its artifacts live, and
# a runtime that picked its own directory would put the same document somewhere different on
# each engine.
__aviary_ns["artifact"] = lambda text, title=None, format="md": __aviary_ask_app(
    "artifact", text=text, title=title, format=format)

try:
    sys.stdout, sys.stderr = __aviary_out, __aviary_err
    if __AVIARY_MODE == "eval":
        __aviary_result["value"] = repr(
            eval(compile(__AVIARY_CODE, "<agent>", "eval"), __aviary_ns, __aviary_ns))
    else:
        # Compile as a module, but echo a trailing expression the way a REPL would: agents
        # write `x.head()` on the last line and expect to see the result.
        import ast
        tree = ast.parse(__AVIARY_CODE, "<agent>", "exec")
        if tree.body and isinstance(tree.body[-1], ast.Expr):
            head = ast.Module(body=tree.body[:-1], type_ignores=[])
            tail = ast.Expression(tree.body[-1].value)
            exec(compile(head, "<agent>", "exec"), __aviary_ns, __aviary_ns)
            __aviary_value = eval(compile(tail, "<agent>", "eval"), __aviary_ns, __aviary_ns)
            if __aviary_value is not None:
                __aviary_result["value"] = repr(__aviary_value)
        else:
            exec(compile(tree, "<agent>", "exec"), __aviary_ns, __aviary_ns)
except BaseException:
    __aviary_result["exception"] = traceback.format_exc()
finally:
    sys.stdout, sys.stderr = sys.__stdout__, sys.__stderr__
    __aviary_result["stdout"] = __aviary_out.getvalue()
    __aviary_result["stderr"] = __aviary_err.getvalue()
    with open(__AVIARY_OUT, "w") as __aviary_fh:
        json.dump(__aviary_result, __aviary_fh, default=repr)
    for __aviary_dead in ("__aviary_out", "__aviary_err", "__aviary_result", "__aviary_fh",
                          "__aviary_value", "__aviary_sh", "__aviary_state",
                          "__AVIARY_CODE", "__AVIARY_MODE", "__AVIARY_OUT", "__AVIARY_CWD"):
        globals().pop(__aviary_dead, None)
    globals().pop("__aviary_dead", None)
'''

# Reads the namespace without running anything the agent wrote.
#
# This is what a host you own buys and a Jupyter kernel cannot: listing names in a kernel
# meant executing a cell, which mutated In/Out and could shadow the very names being listed.
# Here the host's own code reads the agent's dict and changes nothing in it.
_INSPECT_BODY = r'''
import json
__aviary_ns = globals().get("__aviary_ns", {})
__aviary_state = globals().get("__aviary_session_state", {"cwd": None})
__aviary_names = []
for __k, __v in list(__aviary_ns.items()):
    if __k.startswith("__") or __k in __AVIARY_INJECTED:
        continue
    try:
        __r = repr(__v)
        if len(__r) > 300:
            __r = __r[:300] + "…"
        try:
            __n = len(__v)
        except Exception:
            __n = None
        __aviary_names.append({"name": __k, "type": type(__v).__name__, "repr": __r,
                               "length": __n})
    except Exception:
        __aviary_names.append({"name": __k, "type": "?", "repr": "<unreadable>",
                               "length": None})
with open(__AVIARY_OUT, "w") as __fh:
    json.dump({"names": sorted(__aviary_names, key=lambda d: d["name"]),
               "cwd": __aviary_state.get("cwd")}, __fh, default=repr)
for __k in ("__aviary_names", "__k", "__v", "__r", "__n", "__fh", "__aviary_state",
            "__AVIARY_OUT", "__AVIARY_INJECTED"):
    globals().pop(__k, None)
'''


_HOOK_LOAD_BODY = r'''
import json, importlib.util, os, sys, traceback

if "__aviary_hooks" not in globals():
    globals()["__aviary_hooks"] = []

__result = {"ok": False, "detail": None, "events": []}
try:
    __name = "aviary_hook_" + str(len(globals()["__aviary_hooks"]))
    __spec = importlib.util.spec_from_file_location(__name, __AVIARY_HOOK_PATH)
    __module = importlib.util.module_from_spec(__spec)
    __spec.loader.exec_module(__module)
    # A hook declares what it wants by defining functions named for events. Nothing to
    # register, nothing to import from us — the file is the interface.
    __events = [n for n in dir(__module) if n.startswith("on_")]
    if not __events:
        __result = {"ok": False,
                    "detail": "no on_* functions found; a hook file defines on_<event>(payload)",
                    "events": []}
    else:
        globals()["__aviary_hooks"].append(__module)
        __result = {"ok": True, "detail": None, "events": __events}
except Exception:
    __result = {"ok": False, "detail": traceback.format_exc()[-500:], "events": []}

with open(__AVIARY_OUT, "w") as __fh:
    json.dump(__result, __fh, default=str)
for __n in ("__result", "__name", "__spec", "__module", "__events", "__fh", "__n",
            "__AVIARY_HOOK_PATH", "__AVIARY_OUT"):
    globals().pop(__n, None)
'''


_HOOK_CALL_BODY = r'''
import json, traceback

__payload = json.loads(__AVIARY_PAYLOAD)
__out = {"handled": False}
for __hook in globals().get("__aviary_hooks", []):
    __fn = getattr(__hook, "on_" + __AVIARY_EVENT, None)
    if __fn is None:
        continue
    try:
        __r = __fn(__payload)
    except Exception:
        # One hook failing does not stop the others, and does not stop the run.
        __out.setdefault("errors", []).append(traceback.format_exc()[-300:])
        continue
    if isinstance(__r, dict) and __r:
        # Later hooks see earlier decisions, so a chain can refine rather than fight.
        __payload.update({k: v for k, v in __r.items() if k in ("payload", "code")})
        __out.update(__r)
        __out["handled"] = True

with open(__AVIARY_OUT, "w") as __fh:
    json.dump(__out, __fh, default=str)
for __n in ("__payload", "__out", "__hook", "__fn", "__r", "__fh", "__n",
            "__AVIARY_EVENT", "__AVIARY_PAYLOAD", "__AVIARY_OUT"):
    globals().pop(__n, None)
'''


# ---------------------------------------------------------------------------
# One session
# ---------------------------------------------------------------------------


class Session:
    """A sub-interpreter, the thread that owns it, and a queue of work.

    Every interpreter is driven from exactly one thread for its whole life. Sub-interpreter
    state is not safe to touch from arbitrary threads, and serialising per session also
    makes execution order something the caller can reason about.
    """

    def __init__(self, sid: str, cwd: str):
        self.sid = sid
        self.cwd = cwd
        self.jobs: queue.Queue = queue.Queue()
        self.interp = subinterpreters.create()
        self.closed = False
        # Admission and destruction share one lock. A dispatcher that has looked up this
        # session must either enqueue before close's teardown marker or be refused; otherwise a
        # late exec can land behind the destroy sentinel and wait forever with no response.
        self.admission_lock = threading.Lock()
        # Where the sub-interpreter drops callback requests. A directory rather than a pipe
        # because a file is the only thing both sides can see without sharing objects, and
        # this is not a hot path — a callback is a sub-agent or a question, not a loop.
        self.cb_dir = tempfile.mkdtemp(prefix=f"aviary-cb-{sid}-")
        open(os.path.join(self.cb_dir, "pending"), "w").close()
        self.watcher = threading.Thread(
            target=self._watch_callbacks, name=f"cb-{sid}", daemon=True)
        self.watcher.start()
        self.thread = threading.Thread(target=self._loop, name=f"session-{sid}", daemon=True)
        self.thread.start()

    def submit(self, job) -> bool:
        with self.admission_lock:
            if self.closed:
                return False
            self.jobs.put(job)
            return True

    def _watch_callbacks(self) -> None:
        """Forward callback requests from the interpreter to Aviary and write back replies.

        Each request is served on its own thread so several outstanding callbacks — a fan-out
        of sub-agents, say — do not serialise behind one another.
        """
        path = os.path.join(self.cb_dir, "pending")
        seen = 0
        while not self.closed:
            try:
                with open(path) as fh:
                    lines = [l.strip() for l in fh if l.strip()]
                while seen < len(lines):
                    req_path = lines[seen]
                    seen += 1
                    threading.Thread(
                        target=self._serve_callback, args=(req_path,), daemon=True).start()
            except Exception:
                pass
            threading.Event().wait(0.02)

    def _serve_callback(self, req_path: str) -> None:
        try:
            with open(req_path) as fh:
                req = json.load(fh)
            os.unlink(req_path)
        except Exception:
            return
        result = request_from_app(req.get("kind") or "", req.get("payload") or {},
                                  session=self.sid)
        try:
            with open(req["reply"], "w") as fh:
                json.dump(result, fh, default=str)
        except Exception:
            pass

    def _loop(self) -> None:
        while True:
            job = self.jobs.get()
            if job is None:
                break
            try:
                job()
            except Exception:
                emit({"event": "host_error", "session": self.sid,
                      "detail": bounded_diagnostic(traceback.format_exc())})

    def _run(self, body: str, **inputs) -> dict:
        """Run host-authored source in the interpreter and read back its JSON result."""
        fd, path = tempfile.mkstemp(prefix="aviary-runtime-", suffix=".json")
        os.close(fd)
        try:
            source = _prelude(__AVIARY_OUT=path, **inputs) + body
            subinterpreters.run_string(self.interp, source)
            with open(path) as fh:
                return json.load(fh)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    def execute(self, code: str, mode: str) -> dict:
        return self._run(_EXEC_BODY, __AVIARY_CODE=code, __AVIARY_MODE=mode,
                         __AVIARY_CWD=self.cwd, __AVIARY_CALLBACK_DIR=self.cb_dir)

    def inspect(self) -> dict:
        return self._run(_INSPECT_BODY, __AVIARY_INJECTED=sorted(_AVIARY_INJECTED))

    def close(self, join: float = 2.0) -> None:
        """Tear the interpreter down from the thread that owns it.

        Destroying a sub-interpreter from a different thread than the one running it hangs —
        the first shutdown attempt here never returned. So the destroy is queued as the
        session's last job and the caller waits briefly for the thread to finish it.
        """
        with self.admission_lock:
            if self.closed:
                return
            self.closed = True

            def teardown() -> None:
                try:
                    subinterpreters.destroy(self.interp)
                except Exception:
                    pass

            self.jobs.put(teardown)
            self.jobs.put(None)
        self.thread.join(timeout=join)
        try:
            import shutil
            shutil.rmtree(self.cb_dir, ignore_errors=True)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# The host
# ---------------------------------------------------------------------------


class Client:
    """One socket client; its close never changes host/session lifetime."""

    def __init__(self, connection: socket.socket) -> None:
        self.connection = connection
        self.lock = threading.Lock()
        self.closed = False
        self.client_id = str(uuid.uuid4())

    def send_obj(self, obj: dict) -> bool:
        line = json.dumps(obj, ensure_ascii=False, default=str).encode("utf-8") + b"\n"
        callback_oversized = obj.get("event") == "callback" and len(line) > MAX_FRAME_BYTES
        if len(line) > MAX_FRAME_BYTES:
            # Preserve request completion when a result itself is too large. An event-only
            # diagnostic would leave the client's pending request hanging until its much longer
            # operation timeout. Unsolicited events still get a bounded diagnostic event.
            if obj.get("id") is not None:
                obj = {"id": obj.get("id"), "ok": False, "error": {
                    "code": "response_too_large",
                    "detail": "response exceeded the runtime frame limit",
                }}
            else:
                obj = {"event": "host_error", "code": "response_too_large",
                       "detail": "response exceeded the runtime frame limit"}
            line = json.dumps(obj).encode("utf-8") + b"\n"
        with self.lock:
            if self.closed:
                return False
            try:
                deadline = time.monotonic() + MAX_SEND_SECONDS
                offset = 0
                while offset < len(line):
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("runtime client write timed out")
                    _, writable, exceptional = select.select(
                        [], [self.connection], [self.connection], remaining)
                    if exceptional or not writable:
                        raise TimeoutError("runtime client write timed out")
                    try:
                        sent = self.connection.send(
                            line[offset:offset + SEND_CHUNK_BYTES])
                    except InterruptedError:
                        continue
                    if sent == 0:
                        raise OSError(errno.EPIPE, "socket closed")
                    offset += sent
                # A deliberately oversized unsolicited callback was not delivered as a callback
                # frame. Its caller must resolve the rid locally rather than treating the small
                # host_error diagnostic as successful delivery.
                return not callback_oversized
            except OSError:
                self.closed = True
                try:
                    # Wake a sibling makefile.readline/serve thread before closing. Merely closing
                    # the socket object can leave the duplicated file wrapper blocked forever.
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    self.connection.close()
                except OSError:
                    pass
                return False

    def close(self) -> None:
        with self.lock:
            if self.closed:
                return
            self.closed = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self.connection.close()
            except OSError:
                pass


class Host:
    def __init__(self, host_id: str | None = None) -> None:
        self.sessions: dict[str, Session] = {}
        self.lock = threading.Lock()
        self.hook_interp = None
        self.host_id = host_id or str(uuid.uuid4())
        self.instance_id = str(uuid.uuid4())
        self.session_clients: dict[str, Client] = {}
        # Serialize callback delivery with attach acknowledgement. A callback emitted after the
        # mapping changes must not overtake the attach reply that tells a reconnecting GUI where
        # the session is now routed.
        self.session_callback_barriers: dict[str, threading.Lock] = {}
        self.clients: set[Client] = set()
        self.clients_lock = threading.Lock()
        self.stopping = threading.Event()
        self.socket_path: str | None = None
        set_callback_sender(self._send_callback)

    # -- dispatch ----------------------------------------------------------

    def handle(self, msg: dict, client: Client | None = None) -> None:
        previous_sink = getattr(_output_sink, "sink", None)
        _output_sink.sink = client
        rid = msg.get("id")
        op = msg.get("op")
        try:
            if op == "hello":
                requested_protocol = msg.get("protocol")
                if requested_protocol is not None and requested_protocol != PROTOCOL_VERSION:
                    self.fail(rid, "protocol_mismatch",
                              f"host speaks protocol {PROTOCOL_VERSION}")
                    return
                expected = msg.get("expectedIdentity") or {}
                if expected and (expected.get("hostID") != self.host_id
                                  or expected.get("instanceID") != self.instance_id):
                    self.fail(rid, "identity_mismatch", "host instance is not the expected one")
                    return
                self.reply(rid, self.capabilities())
            elif op == "session.create":
                self.reply(rid, self.create(msg, client))
            elif op == "session.destroy":
                self.reply(rid, self.destroy(msg))
            elif op == "session.list":
                with self.lock:
                    self.reply(rid, {"sessions": sorted(self.sessions)})
            elif op == "session.attach":
                sid = msg.get("session") or ""
                barrier = self._callback_barrier(sid)
                with barrier:
                    self.reply(rid, self.attach(msg, client))
                    self._replay_pending_callbacks(sid, client)
            elif op == "session.detach":
                self.reply(rid, self.detach(msg, client))
            elif op == "hook.load":
                self.reply(rid, self.load_hooks(msg.get("paths") or []))
            elif op == "hook.call":
                self.reply(rid, self.call_hook(msg.get("event") or "", msg.get("payload") or {}))
            elif op == "callback.result":
                if "result" not in msg:
                    resolution = {"delivered": False, "status": "invalid"}
                else:
                    resolution = resolve_callback(msg.get("rid") or "", msg["result"])
                self.reply(rid, resolution)
            elif op in ("exec", "inspect"):
                self.dispatch_to_session(rid, op, msg, client)
            elif op == "shutdown":
                self.reply(rid, {"stopping": True})
                # Remove the discoverable endpoint before the potentially slow interpreter
                # teardown. Existing clients get their acknowledgement; new clients cannot
                # race the shutdown window and mistake a dying host for an adoptable one.
                if self.socket_path:
                    try:
                        os.unlink(self.socket_path)
                    except OSError:
                        pass
                self.shutdown()
                self.stopping.set()
                # Hard exit, after the reply is synchronously flushed. A helper process has
                # nothing to persist, and a C extension holding a non-daemon thread would
                # otherwise keep it alive forever — a hung runtime host is worse than an abrupt
                # one. This branch is reached only by the explicit shutdown operation.
                os._exit(0)
            else:
                self.fail(rid, "unknown_op", f"no such op: {op!r}")
        except SystemExit:
            raise
        except Exception:
            self.fail(rid, "host_error", bounded_diagnostic(traceback.format_exc()))
        finally:
            if previous_sink is None:
                try:
                    del _output_sink.sink
                except AttributeError:
                    pass
            else:
                _output_sink.sink = previous_sink

    # ---- hooks -----------------------------------------------------------
    #
    # Hooks are Python, loaded into their own interpreter, and called by the client at points
    # in the agent loop. Python rather than Swift because the whole premise of this system is
    # a runtime you can change without rebuilding the app — a hook that needs a compiler is
    # not an extension point, it is a patch.
    #
    # Their own interpreter, separate from every session, for two reasons: a hook that breaks
    # must not corrupt an agent's namespace, and a hook must not be able to read one session's
    # variables while running on behalf of another.

    def load_hooks(self, paths: list) -> dict:
        if subinterpreters is None:
            raise RuntimeError("no sub-interpreter support, so hooks cannot be isolated")
        if self.hook_interp is None:
            self.hook_interp = subinterpreters.create()
        loaded, failed = [], []
        for path in paths:
            fd, out = tempfile.mkstemp(prefix="aviary-hook-", suffix=".json")
            os.close(fd)
            code = _prelude(__AVIARY_HOOK_PATH=path, __AVIARY_OUT=out) + _HOOK_LOAD_BODY
            try:
                subinterpreters.run_string(self.hook_interp, code)
                with open(out) as fh:
                    result = json.load(fh)
                (loaded if result.get("ok") else failed).append(
                    {"path": path, "detail": result.get("detail"),
                     "events": result.get("events") or []})
            except Exception:
                failed.append({"path": path, "detail": bounded_diagnostic(traceback.format_exc(), 400)})
            finally:
                try:
                    os.unlink(out)
                except OSError:
                    pass
        return {"loaded": loaded, "failed": failed}

    def call_hook(self, event: str, payload: dict) -> dict:
        if self.hook_interp is None:
            return {"handled": False}
        fd, out = tempfile.mkstemp(prefix="aviary-hookcall-", suffix=".json")
        os.close(fd)
        code = _prelude(
            __AVIARY_EVENT=event, __AVIARY_PAYLOAD=json.dumps(payload), __AVIARY_OUT=out
        ) + _HOOK_CALL_BODY
        try:
            subinterpreters.run_string(self.hook_interp, code)
            with open(out) as fh:
                return json.load(fh)
        except Exception:
            # A broken hook must never stop a run. It is reported and ignored, which is the
            # only safe default: the alternative is one bad extension taking the agent with it.
            return {"handled": False,
                    "error": bounded_diagnostic(traceback.format_exc(), 400)}
        finally:
            try:
                os.unlink(out)
            except OSError:
                pass

    def capabilities(self) -> dict:
        return {
            "protocol": PROTOCOL_VERSION,
            "runtime": "cpython",
            "runtimeVersion": sys.version.split()[0],
            "implementation": sys.implementation.name,
            "hostID": self.host_id,
            "instanceID": self.instance_id,
            "transport": "unix",
            "features": {
                # Honest about what is not here. An interrupt that only kills a child
                # process is not a general interrupt, and claiming otherwise would have a
                # caller offering a Stop button that does nothing to a Python loop.
                "isolatedSessions": subinterpreters is not None,
                "perSessionGIL": subinterpreters is not None,
                "namespaceInspection": True,
                "persistentShellState": True,
                "interruptSubprocess": False,
                "interruptPython": False,
                "snapshot": False,
                # The runtime can call back into the app: sub-agents, conversation access,
                # asking a person. Declared, so a client that cannot serve callbacks knows
                # not to offer code that uses them.
                "callbacks": True,
                # Hooks run in their own interpreter, so a broken one cannot reach an agent's
                # namespace or another hook's state.
                "hooks": subinterpreters is not None,
                "adoptableTransport": True,
                "multipleClients": True,
                "persistentSessions": True,
            },
        }

    def create(self, msg: dict, client: Client | None = None) -> dict:
        if subinterpreters is None:
            raise RuntimeError("this Python has no sub-interpreter support")
        sid = msg.get("session") or str(uuid.uuid4())
        cwd = msg.get("cwd") or os.getcwd()
        with self.lock:
            if sid in self.sessions:
                raise RuntimeError(f"session already exists: {sid}")
            self.sessions[sid] = Session(sid, cwd)
            if client is not None:
                self.session_clients[sid] = client
        return {"session": sid, "cwd": cwd}

    def destroy(self, msg: dict) -> dict:
        sid = msg.get("session")
        with self.lock:
            session = self.sessions.pop(sid, None)
            # Remove ownership in the same critical section as the session identity. Otherwise a
            # concurrent destroy/recreate can delete the newly-created session's client mapping.
            if session is not None:
                self.session_clients.pop(sid, None)
        if session is None:
            raise RuntimeError(f"no such session: {sid}")
        session.close()
        return {"session": sid, "destroyed": True}

    def attach(self, msg: dict, client: Client | None) -> dict:
        sid = msg.get("session")
        if client is None:
            raise RuntimeError("session.attach requires a socket client")
        with self.lock:
            if sid not in self.sessions:
                raise RuntimeError(f"no such session: {sid}")
            self.session_clients[sid] = client
        return {"session": sid, "attached": True}

    def _callback_barrier(self, session: str) -> threading.Lock:
        with self.lock:
            barrier = self.session_callback_barriers.get(session)
            if barrier is None:
                barrier = threading.Lock()
                self.session_callback_barriers[session] = barrier
            return barrier

    def _replay_pending_callbacks(self, session: str, client: Client | None) -> None:
        if client is None:
            return
        # The caller holds this session's barrier, so callbacks emitted after attach cannot send
        # until the acknowledgement and this replay have been written in order.
        for message in pending_callback_messages(session):
            if not self._deliver_callback(client, message):
                if (message.get("event") == "callback"
                        and encoded_frame_size(message) > MAX_FRAME_BYTES):
                    resolve_callback(message.get("rid") or "", {
                        "error": "callback payload exceeded the runtime frame limit",
                    })

    @staticmethod
    def _deliver_callback(client: Client, message: dict) -> bool:
        return client.send_obj(message)

    def detach(self, msg: dict, client: Client | None) -> dict:
        sid = msg.get("session")
        with self.lock:
            if sid not in self.sessions:
                raise RuntimeError(f"no such session: {sid}")
            if self.session_clients.get(sid) is client:
                self.session_clients.pop(sid, None)
        return {"session": sid, "detached": True}

    def _send_callback(self, session: str, message: dict) -> None:
        with self.lock:
            client = self.session_clients.get(session)
            barrier = self.session_callback_barriers.get(session)
        if client is not None:
            if barrier is None:
                barrier = self._callback_barrier(session)
            with barrier:
                if self._deliver_callback(client, message):
                    return
            if message.get("event") == "callback" and encoded_frame_size(message) > MAX_FRAME_BYTES:
                # The callback body cannot cross this bounded transport. Resolve the waiting
                # Python call locally with a bounded, actionable result; sending host_error alone
                # would make the GUI believe delivery succeeded while the agent waited 900s.
                resolve_callback(message.get("rid") or "", {
                    "error": "callback payload exceeded the runtime frame limit",
                })
                return
        # No client is currently attached. The request remains in `_callbacks` and is replayed by
        # the next session.attach; silently dropping it would leave the Python interpreter blocked.
        if client is not None:
            with self.lock:
                if self.session_clients.get(session) is client:
                    self.session_clients.pop(session, None)

    def _client_disconnected(self, client: Client) -> None:
        client.close()
        with self.lock:
            for sid, owner in list(self.session_clients.items()):
                if owner is client:
                    self.session_clients.pop(sid, None)
        with self.clients_lock:
            self.clients.discard(client)

    def dispatch_to_session(self, rid, op: str, msg: dict, client: Client | None = None) -> None:
        sid = msg.get("session")
        with self.lock:
            session = self.sessions.get(sid)
        if session is None:
            self.fail(rid, "no_session", f"no such session: {sid}")
            return

        def job() -> None:
            previous_sink = getattr(_output_sink, "sink", None)
            _output_sink.sink = client
            try:
                if op == "exec":
                    code = msg.get("code") or ""
                    result = session.execute(code, msg.get("mode") or "exec")
                    # Output goes out as events first so a caller can stream it, then the
                    # response closes the request. Both, deliberately: streaming is what a
                    # UI wants, and a single settled result is what a test wants.
                    for stream in ("stdout", "stderr"):
                        text = result.get(stream) or ""
                        if text:
                            emit({"event": "output", "session": sid, "stream": stream,
                                  "text": text})
                    self.reply(rid, {
                        "session": sid,
                        "stdout": result.get("stdout") or "",
                        "stderr": result.get("stderr") or "",
                        "value": result.get("value"),
                        "exception": result.get("exception"),
                    })
                else:
                    self.reply(rid, {"session": sid, **session.inspect()})
            except Exception:
                self.fail(rid, "exec_failed", bounded_diagnostic(traceback.format_exc()))
            finally:
                if previous_sink is None:
                    try:
                        del _output_sink.sink
                    except AttributeError:
                        pass
                else:
                    _output_sink.sink = previous_sink

        if not session.submit(job):
            self.fail(rid, "session_closed", "session is being destroyed")

    # -- responses ---------------------------------------------------------

    def reply(self, rid, data: dict) -> None:
        emit({"id": rid, "ok": True, "data": data})

    def fail(self, rid, code: str, detail: str) -> None:
        emit({"id": rid, "ok": False, "error": {
            "code": bounded_diagnostic(code),
            "detail": bounded_diagnostic(detail),
        }})

    def shutdown(self) -> None:
        with self.lock:
            sessions = list(self.sessions.values())
            self.sessions.clear()
            self.session_clients.clear()
        for s in sessions:
            s.close()

    # -- main loop ---------------------------------------------------------

    def serve_socket(self, path: str) -> None:
        self.socket_path = path
        server = self._bind_socket(path)
        try:
            while not self.stopping.is_set():
                try:
                    connection, _ = server.accept()
                except OSError:
                    if self.stopping.is_set():
                        break
                    continue
                client = Client(connection)
                with self.clients_lock:
                    self.clients.add(client)
                client.send_obj({"event": "ready", **self.capabilities()})
                threading.Thread(
                    target=self._serve_client, args=(client,),
                    name=f"runtime-client-{client.client_id}", daemon=True).start()
        finally:
            try:
                server.close()
            except OSError:
                pass
            try:
                os.unlink(path)
            except OSError:
                pass

    def _serve_client(self, client: Client) -> None:
        try:
            reader = client.connection.makefile("rb")
            while not self.stopping.is_set():
                raw = reader.readline(MAX_FRAME_BYTES + 1)
                if not raw:
                    break
                if len(raw) > MAX_FRAME_BYTES and not raw.endswith(b"\n"):
                    # Consume only through the next LF, but do not allocate the unbounded frame.
                    while raw and not raw.endswith(b"\n"):
                        raw = reader.readline(MAX_FRAME_BYTES + 1)
                    client.send_obj({"event": "bad_request", "code": "frame_too_large",
                                     "detail": "request exceeded the runtime frame limit"})
                    continue
                if len(raw) > MAX_FRAME_BYTES:
                    client.send_obj({"event": "bad_request", "code": "frame_too_large",
                                     "detail": "request exceeded the runtime frame limit"})
                    continue
                raw = raw[:-1] if raw.endswith(b"\n") else raw
                try:
                    msg = json.loads(raw.decode("utf-8"))
                except Exception as exc:
                    detail = bounded_diagnostic(f"{type(exc).__name__}: {exc}")
                    client.send_obj({"event": "bad_request", "code": "malformed_json",
                                     "detail": detail})
                    continue
                if not isinstance(msg, dict):
                    client.send_obj({"event": "bad_request", "code": "not_object",
                                     "detail": "request must be a JSON object"})
                    continue
                try:
                    self.handle(msg, client)
                except SystemExit:
                    return
        except OSError:
            pass
        finally:
            self._client_disconnected(client)

    @staticmethod
    def _bind_socket(path: str) -> socket.socket:
        encoded = path.encode("utf-8")
        if not encoded or len(encoded) > 103:
            raise RuntimeError("socket path is empty or too long")
        parent = os.path.dirname(path) or "."
        # Never silently chmod an arbitrary parent. In particular, `/tmp` is commonly
        # world-writable; changing it to 0700 would break unrelated processes, while leaving it
        # open would make a predictable endpoint a local interception opportunity. The Swift
        # launcher and `just host` each create a dedicated owner-only directory before launch.
        try:
            parent_info = os.lstat(parent)
        except FileNotFoundError:
            raise RuntimeError("socket parent directory must already exist")
        except OSError as exc:
            raise RuntimeError(f"socket parent is not accessible: {exc.strerror or 'I/O error'}")
        if stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode):
            raise RuntimeError("socket parent must be a real directory")
        if parent_info.st_uid != os.getuid():
            raise RuntimeError("socket parent must be owned by the current user")
        if (parent_info.st_mode & 0o777) != 0o700:
            raise RuntimeError("socket parent permissions must be 0700")
        if os.path.lexists(path):
            if not stat.S_ISSOCK(os.lstat(path).st_mode):
                raise RuntimeError("socket path is occupied by a non-socket")
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(0.15)
            try:
                probe.connect(path)
            except OSError as exc:
                if exc.errno not in (errno.ECONNREFUSED, errno.ENOENT, errno.ECONNRESET):
                    raise RuntimeError("socket path is occupied or inaccessible")
                os.unlink(path)
            else:
                raise RuntimeError("socket path already serves a live host")
            finally:
                probe.close()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(path)
            os.chmod(path, 0o600)
            server.listen(16)
            return server
        except Exception:
            server.close()
            raise

    def serve(self) -> None:
        """The v3 entry point. A host has no stdio transport; it must be adoptable."""
        raise RuntimeError("runtime host requires --socket")


if __name__ == "__main__":
    try:
        import argparse
        parser = argparse.ArgumentParser(description="Aviary adoptable Python runtime host")
        parser.add_argument("--socket", required=True,
                            help="Unix-domain socket path for the v3 transport")
        parser.add_argument("--host-id", default=None,
                            help="logical host identity supplied by the launcher")
        parser.add_argument("--parent-lifetime-pid", type=int, default=None,
                            help=argparse.SUPPRESS)
        args = parser.parse_args()
        install_parent_lifetime_lease(args.parent_lifetime_pid, args.socket)
        # The socket host must not be tied to the GUI's process group or stdio lifecycle. The
        # call can fail when the launcher already made us a session leader; in that case the
        # socket itself still provides the detach boundary.
        try:
            os.setsid()
        except OSError:
            pass
        Host(args.host_id).serve_socket(args.socket)
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        print(bounded_diagnostic(exc), file=sys.stderr)
        raise SystemExit(1)
