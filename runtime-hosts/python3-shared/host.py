#!/usr/bin/env python3
"""
A runtime host that trades isolation for C-extension compatibility.

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
import os
import queue
import subprocess
import sys
import tempfile
import threading
import traceback
import uuid

try:
    import _xxsubinterpreters as subinterpreters  # 3.12
except ImportError:  # pragma: no cover - newer Pythons renamed it
    try:
        import _interpreters as subinterpreters  # 3.13+
    except ImportError:
        subinterpreters = None

PROTOCOL_VERSION = 2

# Everything the host puts into the agent's namespace. Listed once, because `inspect` must
# hide exactly this set: the namespace belongs to the agent, and a host whose own helpers show
# up in it is lying about what the agent put there.
_AVIARY_INJECTED = frozenset({"sh", "cwd", "ask_app", "spawn", "conversation"})

# ---------------------------------------------------------------------------
# Writing to stdout
# ---------------------------------------------------------------------------

_write_lock = threading.Lock()


def emit(obj: dict) -> None:
    """One JSON object, one line, flushed.

    Locked because session threads emit output events concurrently; without it two
    interleaved writes produce a line that parses as neither message.
    """
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

    def submit(self, job) -> None:
        self.jobs.put(job)

    def _loop(self) -> None:
        while True:
            job = self.jobs.get()
            if job is None:
                break
            try:
                job()
            except Exception:
                emit({"event": "host_error", "session": self.sid,
                      "detail": traceback.format_exc()})

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
        if self.closed:
            return
        self.closed = True
        self.jobs.put(None)
        self.thread.join(timeout=join)


# ---------------------------------------------------------------------------
# The host
# ---------------------------------------------------------------------------


class Host:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}
        self.lock = threading.Lock()

    # -- dispatch ----------------------------------------------------------

    def handle(self, msg: dict) -> None:
        rid = msg.get("id")
        op = msg.get("op")
        try:
            if op == "hello":
                self.reply(rid, self.capabilities())
            elif op == "session.create":
                self.reply(rid, self.create(msg))
            elif op == "session.destroy":
                self.reply(rid, self.destroy(msg))
            elif op == "session.list":
                with self.lock:
                    self.reply(rid, {"sessions": sorted(self.sessions)})
            elif op in ("exec", "inspect"):
                self.dispatch_to_session(rid, op, msg)
            elif op == "shutdown":
                self.reply(rid, {"stopping": True})
                self.shutdown()
                # Hard exit, after the reply is already flushed. A helper process has
                # nothing to persist, and a C extension holding a non-daemon thread would
                # otherwise keep it alive forever — a hung runtime host is worse than an
                # abrupt one.
                sys.stdout.flush()
                os._exit(0)
            else:
                self.fail(rid, "unknown_op", f"no such op: {op!r}")
        except SystemExit:
            raise
        except Exception:
            self.fail(rid, "host_error", traceback.format_exc())

    def capabilities(self) -> dict:
        return {
            "protocol": PROTOCOL_VERSION,
            "runtime": "cpython-shared",
            "runtimeVersion": sys.version.split()[0],
            "implementation": sys.implementation.name,
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
            },
        }

    def create(self, msg: dict) -> dict:
        sid = msg.get("session") or str(uuid.uuid4())
        cwd = msg.get("cwd") or os.getcwd()
        with self.lock:
            if sid in self.sessions:
                raise RuntimeError(f"session already exists: {sid}")
            self.sessions[sid] = Session(sid, cwd)
        return {"session": sid, "cwd": cwd}

    def destroy(self, msg: dict) -> dict:
        sid = msg.get("session")
        with self.lock:
            session = self.sessions.pop(sid, None)
        if session is None:
            raise RuntimeError(f"no such session: {sid}")
        session.close()
        return {"session": sid, "destroyed": True}

    def dispatch_to_session(self, rid, op: str, msg: dict) -> None:
        sid = msg.get("session")
        with self.lock:
            session = self.sessions.get(sid)
        if session is None:
            self.fail(rid, "no_session", f"no such session: {sid}")
            return

        def job() -> None:
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
                self.fail(rid, "exec_failed", traceback.format_exc())

        session.submit(job)

    # -- responses ---------------------------------------------------------

    def reply(self, rid, data: dict) -> None:
        emit({"id": rid, "ok": True, "data": data})

    def fail(self, rid, code: str, detail: str) -> None:
        emit({"id": rid, "ok": False, "error": {"code": code, "detail": detail}})

    def shutdown(self) -> None:
        with self.lock:
            sessions = list(self.sessions.values())
            self.sessions.clear()
        for s in sessions:
            s.close()

    # -- main loop ---------------------------------------------------------

    def serve(self) -> None:
        emit({"event": "ready", **self.capabilities()})
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception as exc:
                # A malformed line is reported and skipped. Exiting would make one bad
                # write from a caller cost every live session in the process.
                emit({"event": "bad_request", "detail": f"{type(exc).__name__}: {exc}"})
                continue
            try:
                self.handle(msg)
            except SystemExit:
                return
        self.shutdown()


if __name__ == "__main__":
    try:
        Host().serve()
    except KeyboardInterrupt:
        pass
