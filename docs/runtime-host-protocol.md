# The Runtime Host Protocol

Everything Aviary knows about an execution runtime is this document. A host that speaks it
is a drop-in — which is the point: the runtime becomes something to *experiment with* rather
than a foundation to commit to. Lua, QuickJS, a WASM sandbox, or a remote runtime are all
alternative implementations of the same contract, not rewrites of Aviary.

Reference host: `runtime-hosts/python3/host.py` — CPython, one sub-interpreter per session.

## Shape

One process. Line-delimited JSON on stdin and stdout, **LF only**. A request carries an `id`
and gets exactly one response with the same `id`. Unsolicited `event` lines may arrive at any
time, including between a request and its response, so a caller can stream output.

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
| `exec` | `session`, `code`, `mode?` (`exec`\|`eval`) | `{stdout, stderr, value, exception}` |
| `inspect` | `session` | `{names: [{name,type,repr,length}], cwd}` |
| `shutdown` | — | `{stopping:true}`, then the process exits |
| `callback.result` | `rid`, `result` | `{delivered:true}` — answers a `callback` event |

`value` is the repr of a trailing expression, the way a REPL echoes one — agents write
`x.head()` on the last line and expect to see it. `exception` is a formatted traceback.
**Both are data.** Agent code that raises, or calls `SystemExit`, must never take the host
down; verified in the suite.

## Callbacks: the runtime asking the client for something

Protocol 2 added a second direction. The runtime emits

```
← {"event":"callback","rid":"cb-1","session":"s1","kind":"spawn","payload":{"prompt":"…"}}
→ {"id":"9","op":"callback.result","rid":"cb-1","result":{"answer":"42"}}
```

and the agent code that asked is unblocked with that result. This is what makes the runtime
more than a calculator: `spawn(prompt)` runs a whole sub-agent and returns its answer,
`conversation(limit)` hands back the transcript the code is part of, and `ask_app(kind, …)` is
the general form.

Two rules. **The session id travels with the request** — one host serves many sessions and a
client has no other way to know which agent asked; leaving it out cost a debugging session.
And **a refusal is a payload with an `error` key, never silence**: the agent is blocked on a
line of code, so an error it can read beats a nine-minute timeout it cannot.

A client that serves no callbacks should still answer, saying so. The reference host declares
`callbacks: true`; a runtime without the channel declares it false and must not offer
`spawn` in its namespace.

## Capabilities, and why they are declared

`hello` and the startup `ready` event both carry a `features` map. A caller must not assume a
capability that isn't declared — the reference host reports `interruptPython: false` because
it cannot interrupt a running Python loop, and a UI that offered a Stop button on the strength
of an assumption would be lying to the person pressing it.

```json
{"protocol":2,"runtime":"cpython","runtimeVersion":"3.12.9",
 "features":{"isolatedSessions":true,"perSessionGIL":true,"namespaceInspection":true,
             "persistentShellState":true,"interruptSubprocess":false,
             "interruptPython":false,"snapshot":false,"callbacks":true}}
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
keeps that for the price of a pipe, and buys two things besides: a runtime that can be
swapped without touching the app, and no version coupling between the app and whatever the
terminal has installed.
