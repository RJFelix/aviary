#!/usr/bin/env python3
"""
A runtime host: one process, one isolated interpreter per session, a line protocol on stdio.

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

Protocol: one JSON object per line in, one per line out. Requests carry an `id` and get
exactly one response with the same `id`. Output arrives as unsolicited `event` lines before
the response, so a caller can stream. LF only — never \r\n, and never a bare \r.
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
# up in it is lying about what the agent put there. Adding a helper without adding it here is
# how that contract quietly breaks.
_AVIARY_INJECTED = frozenset({"sh", "cwd", "ask_app", "spawn", "conversation",
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


def request_from_app(kind: str, payload: dict, session: str = "", timeout: float = 900.0) -> dict:
    """Ask Aviary to do something, and block this session's thread until it answers.

    Blocking is correct here: the agent wrote `await spawn(...)` and expects a result. Only
    the calling session's thread waits — other sessions have their own interpreters and their
    own GILs, so a session waiting on a sub-agent does not stall the host.
    """
    with _callback_lock:
        _callback_seq[0] += 1
        rid = f"cb-{_callback_seq[0]}"
        event = threading.Event()
        _callbacks[rid] = {"event": event, "result": None}
    # The session must travel with the request: one host serves many sessions, and a client
    # routing a callback has no other way to know which agent asked.
    emit({"event": "callback", "rid": rid, "kind": kind, "payload": payload,
          "session": session})
    if not event.wait(timeout):
        with _callback_lock:
            _callbacks.pop(rid, None)
        return {"error": f"Aviary did not answer the {kind} request within {int(timeout)}s"}
    with _callback_lock:
        entry = _callbacks.pop(rid, None)
    return (entry or {}).get("result") or {}


def resolve_callback(rid: str, result: dict) -> None:
    with _callback_lock:
        entry = _callbacks.get(rid)
    if entry:
        entry["result"] = result
        entry["event"].set()

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

    def submit(self, job) -> None:
        self.jobs.put(job)

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
                      "detail": traceback.format_exc()})

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


class Host:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}
        self.lock = threading.Lock()
        self.hook_interp = None

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
            elif op == "hook.load":
                self.reply(rid, self.load_hooks(msg.get("paths") or []))
            elif op == "hook.call":
                self.reply(rid, self.call_hook(msg.get("event") or "", msg.get("payload") or {}))
            elif op == "callback.result":
                resolve_callback(msg.get("rid") or "", msg.get("result") or {})
                self.reply(rid, {"delivered": True})
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
                failed.append({"path": path, "detail": traceback.format_exc()[-400:]})
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
            return {"handled": False, "error": traceback.format_exc()[-400:]}
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
            },
        }

    def create(self, msg: dict) -> dict:
        if subinterpreters is None:
            raise RuntimeError("this Python has no sub-interpreter support")
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
