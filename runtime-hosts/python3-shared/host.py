#!/usr/bin/env python3
"""
A runtime host that trades isolation for C-extension compatibility. It serves an adoptable Unix
domain socket so a client can disconnect without ending the host or its sessions.

Identical protocol to `../python3/host.py` — see docs/runtime-host-protocol.md — and that is
the entire point of this file existing. It is the swappability claim being cashed in: the same
Aviary code drives either host, and picks between them on capabilities rather than on
hard-coded knowledge of what a runtime can do.

Why it exists: `numpy` and `duckdb` declare `Py_mod_multiple_interpreters = NOT_SUPPORTED`,
so CPython refuses to import them into a sub-interpreter, and `polars` fails messily — one of
them aborted the entire process during development. There is no trick around it; the extension
has stated its global state is not per-interpreter safe. So this host runs every session in
*one* interpreter, isolating them by namespace dict instead.

What that costs, and it is declared honestly in `features`:

  * `perSessionGIL: false` — sessions share a GIL, so two CPU-bound sessions take turns
    instead of running in parallel. The reference host measured 3.85x on four interpreters;
    here you get 1x.
  * `isolatedSessions: false` — namespaces are separate, but `sys.modules`, warning filters,
    signal handlers and any C-extension global state are shared. One session that reconfigures
    a library reconfigures it for all of them.

What it keeps: everything else, including crash isolation from Aviary itself, because this is
still a helper process rather than a library linked into the GUI.

Choose the reference host by default; route a session here only when it needs a library that
refuses to load anywhere else.
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
# up in it is lying about what the agent put there.
_AVIARY_INJECTED = frozenset({"sh", "cwd", "ask_app", "spawn", "conversation",
                              "remember", "recall"})

# Callbacks in flight. The shared host uses the same callback contract as the isolated host;
# keeping this here also means a reconnect can re-deliver a callback that was emitted just as a
# client disconnected.
_callbacks: dict = {}
_callback_lock = threading.Lock()
_callback_seq = [0]
_callback_sender = None
_callback_history = OrderedDict()
_CALLBACK_HISTORY_LIMIT = 1024


def set_callback_sender(sender) -> None:
    global _callback_sender
    _callback_sender = sender


def pending_callback_messages(session: str) -> list[dict]:
    with _callback_lock:
        return [entry["message"] for entry in _callbacks.values()
                if entry.get("session") == session and entry.get("result") is None]


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


def request_from_app(kind: str, payload: dict, session: str = "", timeout: float = 900.0) -> dict:
    with _callback_lock:
        _callback_seq[0] += 1
        rid = f"cb-{_callback_seq[0]}"
        event = threading.Event()
        message = {"event": "callback", "rid": rid, "kind": kind,
                   "payload": payload, "session": session}
        _callbacks[rid] = {
            "event": event, "result": None, "session": session, "message": message,
        }
    sender = _callback_sender
    if sender is None:
        emit(message)
    else:
        sender(session, message)
    if not event.wait(timeout):
        with _callback_lock:
            entry = _callbacks.get(rid)
            if entry is not None and entry.get("result") is None:
                _callbacks.pop(rid, None)
                _remember_callback_outcome_locked(rid, "stale")
                return {"error": "Aviary did not answer the %s request within %ss" % (
                    bounded_diagnostic(kind, 120), int(timeout))}
            entry = _callbacks.pop(rid, None)
            if entry is not None:
                _remember_callback_outcome_locked(rid, "accepted")
                return entry.get("result") or {}
        return {"error": "Aviary did not answer the %s request within %ss" % (
            bounded_diagnostic(kind, 120), int(timeout))}
    with _callback_lock:
        entry = _callbacks.pop(rid, None)
        if entry is not None:
            _remember_callback_outcome_locked(rid, "accepted")
    return (entry or {}).get("result") or {}


def resolve_callback(rid: str, result: dict) -> dict:
    """Resolve one callback atomically and report whether this result won the race."""
    if not isinstance(result, dict):
        return {"delivered": False, "status": "invalid"}
    with _callback_lock:
        entry = _callbacks.get(rid)
        if entry is None:
            status = _callback_history.get(rid)
            return {"delivered": False,
                    "status": "duplicate" if status == "accepted" else "stale"}
        if entry.get("result") is not None:
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
    """One JSON object, one line, flushed to the current client."""
    sink = getattr(_output_sink, "sink", None)
    if sink is not None:
        sink.send_obj(obj)
        return

    line = json.dumps(obj, ensure_ascii=False, default=str)
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


def __aviary_sh(command, timeout=None):
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
        if parts and parts[0]:
            __aviary_state["cwd"] = parts[0]
        base = dict(_os.environ)
        for item in parts[1:]:
            if "=" not in item:
                continue
            k, v = item.split("=", 1)
            # Remember only what the command changed, so the session does not accumulate the
            # whole inherited environment.
            if base.get(k) != v and k not in ("_", "PWD", "SHLVL", "OLDPWD"):
                __aviary_state["env"][k] = v
    except Exception:
        pass
    return {"stdout": proc.stdout, "stderr": proc.stderr, "status": proc.returncode}


__aviary_ns["sh"] = __aviary_sh
__aviary_ns["cwd"] = lambda: __aviary_state["cwd"]

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
    if __k.startswith("__") or __k in ("sh", "cwd"):
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
            "__AVIARY_OUT"):
    globals().pop(__k, None)
'''


# ---------------------------------------------------------------------------
# One session
# ---------------------------------------------------------------------------


class Session:
    """A namespace dict in the main interpreter, and a thread that serialises work on it.

    No sub-interpreter, so no per-session GIL and no module isolation — but `numpy`, `pandas`
    and `duckdb` import, which is the only reason to choose this host. Work is still funnelled
    through one thread per session so execution order stays something a caller can reason
    about, and so two `exec` calls on the same session cannot interleave.
    """

    def __init__(self, sid: str, cwd: str):
        self.sid = sid
        self.cwd = cwd
        self.jobs: queue.Queue = queue.Queue()
        self.closed = False
        # Admission and destruction share one lock. A dispatcher that has looked up this
        # session must either enqueue before close's teardown marker or be refused; otherwise a
        # late exec can land behind the destroy sentinel and wait forever with no response.
        self.admission_lock = threading.Lock()
        self.globals: dict = {"__name__": "__main__", "__builtins__": __builtins__}
        self.state = {"cwd": cwd, "env": {}}
        self.globals["sh"] = self._make_sh()
        self.globals["cwd"] = lambda: self.state["cwd"]
        # Same namespace surface as the reference host, so agent code is portable between
        # them. Here the closure can be handed over directly; the sub-interpreter host has to
        # marshal through a file because objects cannot cross an interpreter boundary.
        self.globals["ask_app"] = lambda kind, **payload: request_from_app(kind, payload, sid)
        self.globals["spawn"] = lambda prompt, name=None, model=None: request_from_app(
            "spawn", {"prompt": prompt, "name": name, "model": model}, sid)
        self.globals["conversation"] = lambda limit=40: request_from_app(
            "conversation", {"limit": limit}, sid)
        self.globals["remember"] = lambda text, scope="project", days=None, tags=None: (
            request_from_app("remember",
                             {"text": text, "scope": scope, "days": days, "tags": tags or []},
                             sid))
        self.globals["recall"] = lambda query="": request_from_app(
            "recall", {"query": query}, sid)
        self.thread = threading.Thread(target=self._loop, name=f"session-{sid}", daemon=True)
        self.thread.start()

    def _make_sh(self):
        state = self.state

        def sh(command, timeout=None):
            # Same persistent cwd/env contract as the reference host: 19.7% of real cells
            # were doing this bookkeeping by hand.
            import shlex
            env = dict(os.environ)
            env.update(state["env"])
            fd, probe = tempfile.mkstemp(prefix="aviary-sh-")
            os.close(fd)
            wrapped = "\n".join([
                "cd " + shlex.quote(state["cwd"]) + " 2>/dev/null || cd /",
                command,
                "__aviary_status=$?",
                '{ printf "%s\\0" "$PWD"; env -0; } > ' + shlex.quote(probe) + " 2>/dev/null",
                "exit $__aviary_status",
            ])
            proc = subprocess.run(["/bin/sh", "-c", wrapped], capture_output=True, text=True,
                                  env=env, timeout=timeout)
            try:
                raw = open(probe, "rb").read().decode("utf-8", "replace")
                os.unlink(probe)
                parts = raw.split("\0")
                if parts and parts[0]:
                    state["cwd"] = parts[0]
                base = dict(os.environ)
                for item in parts[1:]:
                    if "=" not in item:
                        continue
                    k, v = item.split("=", 1)
                    if base.get(k) != v and k not in ("_", "PWD", "SHLVL", "OLDPWD"):
                        state["env"][k] = v
            except Exception:
                pass
            return {"stdout": proc.stdout, "stderr": proc.stderr, "status": proc.returncode}

        return sh

    def submit(self, job) -> bool:
        with self.admission_lock:
            if self.closed:
                return False
            self.jobs.put(job)
            return True

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

    def execute(self, code: str, mode: str) -> dict:
        import ast, contextlib, io
        out, err = io.StringIO(), io.StringIO()
        result = {"stdout": "", "stderr": "", "value": None, "exception": None}
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                if mode == "eval":
                    result["value"] = repr(eval(compile(code, "<agent>", "eval"),
                                                self.globals, self.globals))
                else:
                    tree = ast.parse(code, "<agent>", "exec")
                    if tree.body and isinstance(tree.body[-1], ast.Expr):
                        head = ast.Module(body=tree.body[:-1], type_ignores=[])
                        tail = ast.Expression(tree.body[-1].value)
                        exec(compile(head, "<agent>", "exec"), self.globals, self.globals)
                        value = eval(compile(tail, "<agent>", "eval"), self.globals, self.globals)
                        if value is not None:
                            result["value"] = repr(value)
                    else:
                        exec(compile(tree, "<agent>", "exec"), self.globals, self.globals)
        except BaseException:
            # BaseException, not Exception: agent code calling SystemExit must not take the
            # host with it. Verified in the suite for both hosts.
            result["exception"] = traceback.format_exc()
        result["stdout"] = out.getvalue()
        result["stderr"] = err.getvalue()
        return result

    def inspect(self) -> dict:
        names = []
        for k, v in list(self.globals.items()):
            if k.startswith("__") or k in _AVIARY_INJECTED:
                continue
            try:
                r = repr(v)
                r = r if len(r) <= 300 else r[:300] + "\u2026"
                try:
                    n = len(v)
                except Exception:
                    n = None
                names.append({"name": k, "type": type(v).__name__, "repr": r, "length": n})
            except Exception:
                names.append({"name": k, "type": "?", "repr": "<unreadable>", "length": None})
        return {"names": sorted(names, key=lambda d: d["name"]), "cwd": self.state["cwd"]}

    def close(self, join: float = 2.0) -> None:
        with self.admission_lock:
            if self.closed:
                return
            self.closed = True
            self.jobs.put(None)
        self.thread.join(timeout=join)


# ---------------------------------------------------------------------------
# The host
# ---------------------------------------------------------------------------


class Client:
    """One socket client; closing it never tears down host-owned sessions."""

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
            elif op == "callback.result":
                result = msg.get("result")
                resolution = resolve_callback(msg.get("rid") or "", result)
                self.reply(rid, resolution)
            elif op in ("exec", "inspect"):
                self.dispatch_to_session(rid, op, msg, client)
            elif op == "shutdown":
                self.reply(rid, {"stopping": True})
                if self.socket_path:
                    try:
                        os.unlink(self.socket_path)
                    except OSError:
                        pass
                self.shutdown()
                self.stopping.set()
                # This branch is reached only by the explicit shutdown operation.
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

    def capabilities(self) -> dict:
        return {
            "protocol": PROTOCOL_VERSION,
            "runtime": "cpython-shared",
            "runtimeVersion": sys.version.split()[0],
            "implementation": sys.implementation.name,
            "hostID": self.host_id,
            "instanceID": self.instance_id,
            "transport": "unix",
            "features": {
                # Honest about what is not here. An interrupt that only kills a child
                # process is not a general interrupt, and claiming otherwise would have a
                # caller offering a Stop button that does nothing to a Python loop.
                # False, and load-bearing: a caller checks these to decide which host to
                # route a session to. Namespaces are separate; interpreters are not.
                "isolatedSessions": False,
                "perSessionGIL": False,
                "namespaceInspection": True,
                "persistentShellState": True,
                "interruptSubprocess": False,
                "interruptPython": False,
                "snapshot": False,
                "callbacks": True,
                "adoptableTransport": True,
                "multipleClients": True,
                "persistentSessions": True,
            },
        }

    def create(self, msg: dict, client: Client | None = None) -> dict:
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
            if not client.send_obj(message):
                if (message.get("event") == "callback"
                        and encoded_frame_size(message) > MAX_FRAME_BYTES):
                    resolve_callback(message.get("rid") or "", {
                        "error": "callback payload exceeded the runtime frame limit",
                    })

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
                if client.send_obj(message):
                    return
            if message.get("event") == "callback" and encoded_frame_size(message) > MAX_FRAME_BYTES:
                resolve_callback(message.get("rid") or "", {
                    "error": "callback payload exceeded the runtime frame limit",
                })
                return
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
