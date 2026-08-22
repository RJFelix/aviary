# Architecture

## The split

```
┌──────────────────────────────────────────────────────────────┐
│ Aviary.app                                                    │
│                                                               │
│  SwiftUI views ──── AppModel ──── AviaryCore                  │
│                                      │                        │
│                    ┌─────────────────┼──────────────────┐     │
│                    │                 │                  │     │
│              file reads         subprocess          RPC over  │
│              (native)          (native)            stdio      │
└────────────────────┼─────────────────┼──────────────────┼─────┘
                     ▼                 ▼                  ▼
            ~/.prime/agent/      prime-agent        prime-agent
            sessions/*.jsonl     list --json        --mode rpc
            session-artifacts/   doctor --json      (one per live run)
            rlm-ledger/          shutdown
            daemon-workers/
            models.json
            settings.json
```

Three ways in, chosen per question:

**Files, for everything historical.** Transcripts, the sub-agent topology, worker
descriptors, configuration. Reading them natively is a few milliseconds each and — the
reason it matters — keeps the app fully usable when the daemon is wedged, which is exactly
when you want to read what happened.

**Subprocess, for state only the daemon knows.** Whether a session is streaming, which
worker holds it, what is queued. `list --json` is the single richest source in the system
and there is no file equivalent.

**RPC, for driving a run.** One `prime-agent --mode rpc` per live run, spawned by the app,
speaking LF-delimited JSON over pipes. This is the harness's documented embedding contract.

What is deliberately *not* here: any reimplementation of the agent loop. The IPython kernel,
the provider routes, compaction, sub-agent spawning — that is the harness's job and the
reason to keep it.

## The in-house agent

As of 2026-08-22 Aviary runs agents itself: its own provider clients, its own loop, its own
transcript writer, tools in its own runtime host. No harness, no Node, no daemon. The vendored
harness is still there and still selectable, but nothing requires it.

```
prompt ─▶ AgentRunner ─▶ Agent ─┬─▶ ChatProvider   openai-completions │ anthropic-messages
                                ├─▶ RuntimeHost    python tool, persistent interpreter
                                ├─▶ MCPClient      other people's tools, per server
                                ├─▶ MemoryStore    remember / recall
                                └─▶ SessionWriter  JSONL the existing parser already reads
```

| Piece | What it is |
|---|---|
| `ChatModel.swift` | message and tool types, the `openai-completions` wire format, SSE framing |
| `AnthropicProvider.swift` | `anthropic-messages`, which differs in every way that 400s if missed |
| `Agent.swift` | the loop: stream, execute tools, append, repeat; compaction; callbacks |
| `AgentRunner.swift` | builds agents, including the children they spawn, and routes callbacks |
| `RuntimeHost.swift` | client for the runtime-host protocol |
| `SessionWriter.swift` | writes the harness's transcript format |
| `SubAgents.swift` | writes the harness's sub-agent ledger, so Flock draws in-house children |
| `SkillGate.swift` | which skills a request carries |
| `Memory.swift` | what the agent has learned, and how much of it a request carries |
| `MCPClient.swift` | stdio JSON-RPC: initialize, tools/list, tools/call |

### Decisions, and the measurement behind each

**The transcript format is the harness's.** Aviary has a parser, renderer, catalog, usage
analytics and sub-agent tree reader built on it. A second format would mean duplicating all of
that or losing it, so an in-house run produces files indistinguishable from a harness run.
Sub-agents write the same ledger, which is why Flock went from 53 children to 55 with no UI
work at all.

**One tool, `python`.** From the measured corpus of 5,574 real cells: `subprocess` was the top
import by 4×, 27.7% shelled out, and **two cells** touched pandas. A menu of file and search
tools would be a menu of things `sh()` already does, paid for on every request.

**The header is written immediately.** The harness defers file creation until the first
assistant message, so a run that dies during its first model call leaves no transcript — which
is exactly the run worth reading.

**Skills are ranked, not dumped.** The harness sent all 68 descriptions every time: 62.7% of
input tokens on a two-message run. Measured on the real library of 57 — "what is 2+2?" gets 0
descriptions and saves 29 KB; a ClickHouse question gets 12 and still saves 22 KB. What misses
the budget is **listed by name**, never hidden: a capability the model cannot see and cannot
ask for is silent capability loss that reads as the model being stupid.

**Memory has scopes, lifetimes, provenance, and no silent cap.** Each of those is a flaw in
the harness's continual harness, measured earlier in this project: 6 entries per kind at 180
characters sorted *alphabetically* (so the newest was the hidden one), no tier between
session-lifetime and forever, a 0600 blob rewritten in place, and no record of why it believed
anything. Here: append-only JSONL under `memory/`, session/project/global with optional TTLs,
every entry naming the prompt that produced it, relevance-then-recency ranking, and a listed
remainder.

**Payload recording is native.** The harness needed an extension hook and could only show what
the harness had already assembled. Owning the provider makes the exact serialized request a
`ChatEvent`, so the "what was sent" breakdown works with nothing installed. Still opt-in: it
writes the whole system prompt and conversation to disk.

**Cost is priced at write time.** Usage and Cockpit read dollars out of the transcript, so a
run reporting tokens and no cost would look free — and `sessionsWithoutPricing` exists to
distinguish "no rates published" from "cost zero".

### Callbacks: the runtime calling back into the app

Protocol 2 added a second direction, and it is what makes the environment more than a
calculator. Agent code calls `spawn(prompt)` and blocks; a whole sub-agent runs; the answer
comes back as a return value. `conversation(limit)` hands back the transcript the code is part
of. `remember`/`recall` persist findings. `ask_app(kind, …)` is the general form.

Two rules learned the hard way. **The session id travels with every request** — one host serves
many sessions and there is no other way to route the answer; leaving it out cost a debugging
session. And **a refusal is a payload with an `error` key, never silence**: the agent is blocked
on a line of code, so an error it can read beats a nine-minute timeout it cannot.

### Two bugs worth not rediscovering

**`AsyncLineSequence` discards blank lines**, and in SSE the blank line *is* the record
separator. Five `data:` events arrived as five lines with no separators, a spec-correct parser
emitted nothing, and every turn came back empty with no error anywhere. `SSELineSequence` splits
raw bytes and keeps them.

**A capability the model is not told about does not exist.** `spawn()` was in the namespace and
absent from the tool schema; a real run spent twenty turns grepping the codebase for it before
giving up. The schema is now built from what the run can actually do — including how much
sub-agent depth remains — and there is a test asserting `spawn` is advertised only when it is
possible.

### Session lifecycle

**Steering** queues a message that lands at the next turn boundary. Not mid-turn, and not
because that would be awkward: a tool call in flight has to be answered before the model can be
told anything, and injecting between a call and its result produces a conversation the provider
rejects. The Live composer stays usable while the agent works, and a queued message shows in the
inspector until it is taken up. **Follow-ups** continue the run rather than ending it.

**Goals** are a budget and a finishing condition. The useful part is not the word but the two
numbers — an agent asked to do something open-ended otherwise runs until an iteration ceiling it
cannot see, which is the worst kind of stop: silent, arbitrary, and indistinguishable from
success. The remaining budget is restated in the system prompt every turn, because a stale
number is worse than none, and exhaustion is recorded as its own outcome so a run that ran out
does not look like one that finished. `--budget <tokens>` and `--minutes <n>`.

**Scheduled jobs** are per session and stored in the session's own artifacts directory, so a
schedule cannot outlive the thing it schedules. The harness keyed cron jobs on a stable
*attachment* id instead, which is why forking a session silently moved its parent's schedule to
the child. Intervals rather than cron expressions: every real case in the corpus was "every N
minutes", and a cron parser is a weekend and a class of bugs bought for a case nobody had. A
job marked *only when idle* is a heartbeat; a due job that arrives while a turn is running is
skipped rather than queued, because a heartbeat that piles up delivers a burst the moment the
turn ends.

**Prompt templates** expand `/name argument` from the templates already on disk — only at the
start of a prompt and only one, because a prompt that expands templates anywhere becomes a
templating language and a `/` mid-sentence is far more often a path. A name that does not exist
is refused with the list of ones that do, rather than sent to the model as a literal slash,
which reads as the model ignoring an instruction.

### What the harness still does and this does not

Extension hooks, and the OAuth-authenticated built-in providers (`openai-codex`, Anthropic
subscription login). Both are real gaps rather than deliberate omissions.

## The runtime host

Where agent code runs, as of 2026-08-21. A separate process, one isolated interpreter per
session, a line protocol on stdio — the contract is [runtime-host-protocol.md](runtime-host-protocol.md)
and it is deliberately the *only* thing Aviary knows about a runtime.

```
Aviary ──stdio JSONL──▶ runtime-hosts/python3/host.py
                          ├── sub-interpreter per session (own GIL, own thread)
                          └── sh() with a persistent cwd and environment
```

Three reasons for this shape, each measured rather than assumed:

- **A process, not a library.** Linking a runtime in would let the GUI read interpreter
  memory, and would also mean a segfault in a C extension takes the window, the board and the
  transcripts. Not hypothetical: importing `polars` into a sub-interpreter aborted the whole
  process during development. The invariant that Aviary stays usable when the agent side is
  wedged is worth more than direct pointer access.
- **Sub-interpreters, not processes, per session.** CPython 3.12 gives each its own GIL —
  measured at **3.85× on four concurrent interpreters** — so sessions run genuinely in
  parallel without a process each, and without a daemon, worker pool, ownership leases or a
  socket whose version must match whatever the terminal has installed.
- **A swappable contract.** `runtime-hosts/python3-shared/` is a second host that runs every
  session in one interpreter: no per-session GIL, but `numpy`, `pandas` and `duckdb` import,
  because those declare `Py_mod_multiple_interpreters = NOT_SUPPORTED` and CPython refuses
  them in a sub-interpreter. Both hosts speak the same protocol and declare the difference in
  `features`, so a caller routes on capability rather than on hard-coded knowledge. A Lua or
  QuickJS host is a third implementation, not a rewrite.

`sh()` keeps a working directory and environment across calls. That is not a convenience:
**19.7% of 5,574 real cells** were doing directory bookkeeping by hand because `subprocess`
starts every child in the same place. See
[knowledge/agent-execution-environment.md](../../knowledge/agent-execution-environment.md).

`inspect` reads a session's namespace without running anything the agent wrote — the
capability a Jupyter kernel could not offer, where listing names meant executing a cell that
mutated `In`/`Out` and could shadow the names being listed.

## Core types

| Type | Job |
|---|---|
| `JSONValue` | Permissive JSON with forgiving accessors. Every record is parsed into this first. |
| `SessionParser` | JSONL → `Transcript`. Walks the entry *tree*, renders only the active branch, pairs tool calls with results, collapses thousands of status entries into one. |
| `SessionCatalog` | Actor. Single-pass summaries with a size+mtime cache, persisted to Application Support. |
| `AgentTreeReader` | The sub-agent topology, from per-session `rlm-subagents.jsonl` (live status, model, prompt) with the append-only spawn ledger folded in for children that died before writing a status. |
| `DaemonInspector` | Actor. Three cross-checked liveness signals, worker descriptors from disk, and repair actions. |
| `ApiKeyResolver` | Resolves a provider's key expression exactly as the harness does, and explains the result. |
| `RPCSession` | Actor. One live run: launch, command/response correlation, event stream. |
| `LiveTranscriptBuilder` | RPC events → the same `TranscriptItem` values the file parser produces, so history and a streaming run share one renderer. |

## One renderer, two sources

`TranscriptView` does not know whether its items came from a file or a socket.
`SessionParser` and `LiveTranscriptBuilder` both produce `[TranscriptItem]`, which is
deliberately *not* a one-to-one mapping of session entries:

- A tool call and its result are two entries but one thing a person looks at, so they become
  one row with the Python cell above its output.
- Eighteen hundred `agent_status` entries are one thing — the latest status — not eighteen
  hundred rows.
- Hook-injected context (`<duckbill-knowledge>…`) is separated from the prompt the person
  actually typed, so it can be folded away and so session titles are the question rather
  than the preamble.

The payoff: a message that just streamed in looks identical to the same message read back
tomorrow. Any rendering improvement lands in both places at once.

## Workshop capture ordering

The screenshot attached to a request is taken when the compose panel is **asked for**, not
when the request is filed. Filing-time capture puts the panel on top of the thing being
reported, and the panel occupies the bottom-right corner of the window, which on this app is
content rather than margin. Capturing first costs a few hundred milliseconds of latency on
open — the pill shows a spinner for it — and buys an image that is purely what the person was
looking at.

The context facts are captured at the same moment for the same reason, and for one more: the
preview in the panel is then exactly what will be filed rather than a fresh reading that
could differ. Everything held that way is dropped when the panel is dismissed without
filing, so a stale image can never be attached to a later request.

Capture goes through ScreenCaptureKit rather than `cacheDisplay`, because AppKit vibrancy and
material layers are composited by the WindowServer and never drawn by the view — a
`cacheDisplay` shot loses the sidebar and the Sessions inspector entirely. `cacheDisplay`
remains the fallback, so a refused Screen Recording grant costs fidelity, not the feature.

## Snapshot rendering

`Aviary --snapshot <dir>` boots the model against the real agent directory, hosts `RootView`
in an `NSWindow`, and writes a PNG per screen via `cacheDisplay`. `ImageRenderer` cannot do
this job — it refuses `NavigationSplitView` and draws SwiftUI's "unsupported" glyph.

Known limits, both in the capture path rather than the app:

- AppKit vibrancy materials do not rasterize, so the sidebar column comes out white.
- The window does not draw reliably until it has been through a couple of section
  transitions, so every screen is rendered twice and only the second pass is written.
  Longer settle times do not help; forcing a rebuild with `.id()` makes it worse.
- The sidebar is **always white** in a capture, on every screen: AppKit vibrancy does not
  rasterize. It is never evidence of anything. A real sidebar bug cannot be seen here at
  all — it has to be reproduced by hosting `SidebarView` on its own, which does render.
- Read colours in `--bare` with suspicion: bare mode has no window background, so
  light-on-light text is an artifact of that, not a contrast bug. Flat black where a
  background is explicitly set is the same class.

### The greedy-child trap (2026-08-21)

Four screens used to capture as identical blank frames. Two separate causes, both real
bugs rather than capture flakiness, and both worth knowing because the symptom in each
case was *a missing header* rather than anything that pointed at height:

1. `present()` pinned the hosting view with `.frame(width:height:)`. A
   `NavigationSplitView` given a hard frame lays out against a proposal it never receives
   in the real app, and its sidebar comes back empty. The hosting view is now sized by the
   window and autoresizes. This alone took `cockpit` from a blank 42KB frame to a full
   160KB dashboard, and fixed `health` and `usage` too.
2. `EmptyStateView` applied `.frame(maxHeight: .infinity)` and *then* `.padding(40)`.
   Frame-then-padding makes a view report back more height than it was offered, so the
   parent re-proposes the larger value and the height runs away — measured at 3040pt and
   still climbing inside a 963pt pane. Padding now goes inside the frame.

The lesson that generalizes: **a screen that resolves taller than its own pane does not
just clip.** `NavigationSplitView` re-solves the whole window for it, and the casualty is
whatever else shares the window — in this case the sidebar went blank on one tab and only
that tab. If a screen has a greedy child, pin the screen to `GeometryReader`'s size, and
measure with a geometry probe before theorising. Two `onChange(of: g.size)` probes found
in one build what four rounds of guessing did not.
