# The Runtime Host Protocol

Everything Aviary knows about an execution runtime is this document. A host that speaks it
is a drop-in — which is the point: the runtime becomes something to *experiment with* rather
than a foundation to commit to. Lua, QuickJS, a WASM sandbox, or a remote runtime are all
alternative implementations of the same contract, not rewrites of Aviary.

Reference host: `runtime-hosts/python3/host.py` — CPython, one sub-interpreter per session.
The bundled hosts speak protocol **3** over a local Unix-domain socket. The socket is the
client transport; it is not a process-lifetime signal.

## Shape

One process. Line-delimited JSON on a Unix-domain socket, **LF only**. A host may serve many
clients over the same socket. A request carries an `id` and gets exactly one response with the
same `id`. Unsolicited `event` lines may arrive at any time, including between a request and its
response, so a caller can stream output. Frames are bounded at 4 MiB; malformed or oversized
frames are reported and skipped without taking down the host or its other clients.

The host creates a 0600 socket inside a dedicated, pre-existing 0700 directory owned by the
current user. A host refuses to create a socket under a missing, symlinked, foreign-owned, or
group/world-accessible parent; it never chmods an arbitrary parent such as `/tmp`. The path is
only an endpoint, not an authority. A caller that explicitly retains the typed `{hostID,
instanceID, protocol}` descriptor returned by the ready handshake can verify it again when
adopting a socket. The current app does not persist these descriptors or implement production
GUI reattachment yet. A PID is diagnostic only and is never used to prove identity or ownership.

Those permissions are a local transport precaution, not a sandbox or a complete trust boundary.
The Python interpreter is intentionally capable of file, process, socket, and network effects;
hooks and callback approval can shape requests but cannot contain direct Python effects.

The first frame sent to every client is a ready handshake:

```
← {"event":"ready","protocol":3,"runtime":"cpython","runtimeVersion":"3.14.6",
   "hostID":"host-1","instanceID":"process-1","transport":"unix",
   "features":{"adoptableTransport":true,"multipleClients":true,"persistentSessions":true}}
```

The launcher gives the host null stdin/stdout/stderr, so closing the GUI's client connection does
not send an EOF through a parent-owned pipe. This is a transport boundary, not a service manager:
the protocol promises survival across an ordinary client disconnect, but not across a host crash,
OS termination, or machine shutdown. Closing a client socket is a **disconnect**: sessions,
variables, Futures and callbacks remain host-owned while that process continues. A new client
connects to a caller-retained socket path, verifies the same host/process identity, and calls
`session.attach` for each session it will serve callbacks for. This is an API/test substrate for
future attachment work, not a claim that the production GUI currently stores or restores these
descriptors. An explicit `shutdown` request is the only protocol operation that intentionally
ends the host and destroys its sessions. Orderly host exit removes the endpoint; a crash or hard
kill may leave a stale socket inode, which a later host may reclaim only after its refused-
connection probe.

Split on `\n` and nothing else. `\r` is not a delimiter and U+2028/U+2029 are legal inside
JSON strings — a generic line reader corrupts transcripts that contain them.

```
→ {"id":"7","op":"exec","session":"s1","code":"print('hi')"}
← {"event":"output","session":"s1","stream":"stdout","text":"hi\n"}
← {"id":"7","ok":true,"data":{"stdout":"hi\n","stderr":"","value":null,"exception":null}}
```

Failure is a response, not a dropped connection:

```
← {"id":"7","ok":false,"error":{"code":"no_session","detail":"no such session: s1"}}
```

## Operations

| op | fields | returns |
|---|---|---|
| `hello` | — | capabilities (same shape as the `ready` event) |
| `session.create` | `session?`, `cwd?` | `{session, cwd}` — id is generated if omitted |
| `session.destroy` | `session` | `{session, destroyed}` |
| `session.list` | — | `{sessions: [id]}` |
| `session.attach` | `session` | `{session, attached}` — routes callbacks to this client and replays unresolved callbacks |
| `session.detach` | `session` | `{session, detached}` — leaves the session alive |
| `exec` | `session`, `code`, `mode?` (`exec`\|`eval`), diagnostic `traceparent?` | `{stdout, stderr, value, exception}` |
| `inspect` | `session` | `{names: [{name,type,repr,length}], cwd}` |
| `shutdown` | — | `{stopping:true}`, then the process exits |
| `callback.result` | `rid`, `result` | `{delivered, status}` — answers or classifies a `callback` event |

`value` is the repr of a trailing expression, the way a REPL echoes one — agents write
`x.head()` on the last line and expect to see it. `exception` is a formatted traceback.
**Both are data.** Agent code that raises, or calls `SystemExit`, must never take the host
down; verified in the suite.

## Callbacks: the runtime asking the client for something

Protocol 3 carries a second direction. The runtime emits

```
← {"event":"callback","rid":"cb-1","session":"s1","kind":"spawn","payload":{"prompt":"…"}}
→ {"id":"9","op":"callback.result","rid":"cb-1","result":{"answer":"42"}}
```

and the agent code that asked is unblocked with that result. This is what makes the runtime
more than a calculator: `spawn(prompt)` starts a sub-agent and returns a Future,
`conversation(limit)` hands back the transcript the code is part of, and `ask_app(kind, …)` is
the general form.

For Work-owned children, both bundled Python hosts share the same Future adapter:
`spawn(prompt, name=None, model=None, timeout=None, token_limit=None, cost_limit_usd=None)`.
Omitted limits mean run until finished or explicitly stopped. `timeout` is a positive number of
seconds, `token_limit` a positive integer, and `cost_limit_usd` a positive configured-price estimate.
The callback encodes token limits as canonical decimal strings to preserve integer precision.
The Work Host fixes the deadline once on admission; reconnect/retry never renews it. Token/cost
thresholds gate each child provider request, including compaction. They are not invoice caps:
the last postpaid request can exceed the threshold, and unknown usage/pricing blocks further
requests when that dimension is limited. Routes that cannot honor limits refuse them.

The Future observes the durable Handle; `.result()` waits for its retained answer and `.notify()`
requests a bounded notification. `.cancel()` does not terminate Work-owned execution. Parent Run
End and client EOF likewise do not stop the child; explicit Work control owns that decision.
Terminal limit reasons remain distinct from provider failures in canonical state and activity UI.

Two rules. **The session id travels with the request** — one host serves many sessions and a
client has no other way to know which agent asked; leaving it out cost a debugging session.
And **a refusal is a payload with an `error` key, never silence**: the agent is blocked on a
line of code, so an error it can read beats a nine-minute timeout it cannot.
Callback admission is bounded. Once that bound is full, the client sends each excess callback a
bounded `callback.result` refusal directly; if even that bounded write cannot be delivered, it
closes the transport so the runtime can observe disconnection instead of retaining a silent RID.

A client that serves no callbacks should still answer, saying so. The reference host declares
`callbacks: true`; a runtime without the channel declares it false and must not offer
`spawn` in its namespace. If the serving client disconnects while a callback is unresolved, the
host retains the callback identity and re-emits it after `session.attach`; it does not silently
let the Python session hang. Callback delivery is **at-least-once**, so the same `rid` can be
delivered to more than one client when a response is lost. The host atomically accepts the first
result and returns `{delivered:false,status:"duplicate"}` for a later result, or
`{delivered:false,status:"stale"}` when no callback remains. This process-local history is not
durable exactly-once effect state; consumers performing durable effects must deduplicate by the
stable `rid` themselves.

### Diagnostic tracing

An `exec` request and a `callback` event may carry a top-level W3C `traceparent`.
Only the lowercase version-00, 55-byte form with nonzero trace/span IDs is accepted; other
values are ignored. There is no baggage. Trace context is never authentication, an effect
identity, or delivery evidence. If context alone would exceed the frame limit, the sender
omits it before the single write. An oversized base request still fails normally.

The bundled hosts capture context per execution and retain it with pending callback messages,
including reconnect replay. Reference-host Futures and their notification/Handle observers
capture the originating callback callable, so a later cell cannot relabel their work. A retained
callback callable in the shared host likewise keeps its origin. Arbitrary user threads that
later look up a replaced namespace function do not have automatic context inheritance; this
is not a complete Python-effect audit.

The Swift callback boundary starts a server span from the explicit received context. Missing
or malformed context starts an independent trace, never inherits the socket-listener task.
A callback may legitimately descend from an already-ended execution span. Its reply status
describes the callback exchange, not whether arbitrary external effects succeeded. Replayed
callbacks remain subject to the existing RID/idempotency contract, regardless of trace IDs.

## Capabilities, and why they are declared

`hello` and the startup `ready` event both carry a `features` map. A caller must not assume a
capability that isn't declared — the reference host reports `interruptPython: false` because
it cannot interrupt a running Python loop, and a UI that offered a Stop button on the strength
of an assumption would be lying to the person pressing it.

```json
{"protocol":3,"runtime":"cpython","runtimeVersion":"3.14.6","hostID":"host-1",
 "instanceID":"process-1","transport":"unix",
 "features":{"isolatedSessions":true,"perSessionGIL":true,"namespaceInspection":true,
             "persistentShellState":true,"interruptSubprocess":false,
             "interruptPython":false,"snapshot":false,"callbacks":true,
             "adoptableTransport":true,"multipleClients":true,"persistentSessions":true}}
```

## What a host must guarantee

1. **State persists across `exec` calls within a session.** This is the whole premise: the
   agent's variables, imports and open handles survive, so work accumulates instead of being
   rebuilt every turn.
2. **Sessions are isolated.** One session cannot see another's names. Measured on the
   reference host: four concurrent sub-interpreters ran a GIL-bound loop **3.85× faster than
   sequentially**, so isolation is real parallelism rather than cooperative scheduling.
3. **`inspect` must not perturb the namespace.** It may run host-authored code, but it must
   leave no trace the agent can see — no new names, no mutated history. This is the capability
   a Jupyter kernel could not offer: listing names there meant executing a cell, which
   mutated `In`/`Out` and could shadow the very names being listed.
4. **A malformed input line is reported and skipped, never fatal.** One bad write from a
   caller must not cost every live session in the process.
5. **The namespace belongs to the agent.** A host that leaves its own variables in it is
   lying about what the agent put there.

## What a host should provide

`sh(command)` with a **persistent working directory and environment** — `cd` and `export`
stick for the life of the session. Not a nicety: 19.7% of 5,574 real cells were doing
directory bookkeeping by hand because `subprocess` starts every child in the same place. See
[knowledge/agent-execution-environment.md](../../knowledge/agent-execution-environment.md)
for the full measured usage profile, which is what this protocol is designed around —
27.7% shelling out, 29.6% file I/O, and *two cells out of 5,574* using pandas.

`cwd()` returning the session's current directory rounds it out.

## Why a separate process

Linking a runtime into Aviary directly would be faster to call and would let the GUI read
interpreter memory. It would also mean a segfault in a C extension takes the window, the
board and the transcripts with it. Aviary's stated invariant is that it stays usable when the
agent side is wedged — precisely when you most want to read what happened. A helper process
keeps that for the price of a local socket, and buys two things besides: a runtime that can be
swapped without touching the app, and no version coupling between the app and whatever the
terminal has installed. Unlike a pipe, the socket gives a future client API a way to reconnect
to the same process and interpreter without pretending that client lifetime is work lifetime;
production descriptor persistence and GUI reattachment remain future work.
