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

### Hooks

`hooks/*.py` in the checkout, loaded on each in-house run. A file defines `on_<event>(payload)`
and there is nothing to register — the file is the interface. See [hooks/README.md](../hooks/README.md).

Python rather than Swift because the premise of this whole system is a runtime you can change
without rebuilding the app: a hook that needs a compiler is not an extension point, it is a
patch. They run in **their own interpreter**, separate from every session, so a hook cannot read
a session's variables (asserted) and a broken hook cannot corrupt one.

`on_before_tool` can return `{"block": true, "reason": …}` or `{"code": …}`. Because `python`
is the only built-in tool, that single event is a complete permission system — and it can
*rewrite* a call rather than only veto it, which is the difference between a gate and a wall. A
rewrite is noted in the transcript, because a silently altered call would make the record lie
about what ran.

Three failure behaviours, all deliberate. A hook that cannot import is reported into the
transcript, not swallowed: silently absent and deliberately doing nothing are
indistinguishable, and the difference matters when the hook was supposed to be blocking
something. A hook with no `on_*` functions is refused with an explanation rather than loaded as
a no-op. And **a hook that raises is ignored** — one bad extension must never take the run
with it.

The shipped example is disabled by default, and its first version is a lesson: it matched
`rm -rf /tmp/scratch`, which is fine and which an agent has every reason to run. A guard that
refuses reasonable things teaches the agent to route around it, which is worse than no guard.

### The Codex path is a transcription, not a design

`CodexAuth.swift`, `CodexLogin.swift`, `CodexProvider.swift` and the catalogue in
`BuiltInProviders.swift` are a **deliberate one-to-one reimplementation** of the harness's
`utils/oauth/openai-codex.ts` and `providers/openai-codex-responses.ts`. Every value that
reaches an OpenAI server is copied rather than chosen: the client id, endpoints, scope, the
three Codex-specific authorize parameters, the PKCE method, the header set and its exact
spellings, the body's fields and defaults, the retry policy.

**The rule for those files is that a difference is a bug, not an improvement.** Third-party
harness use is in a tolerated grey area; looking like a *novel* client is what risks being
mistaken for credential resale. Comments mark every field that looks arbitrary so a future
reader does not tidy it away.

Verified empirically rather than by reading alone. A harness request was captured with the
wire-log extension and diffed field by field against Aviary's for the same model:

```
keys identical: True     harness-only: []     mine-only: []
  include, model, parallel_tool_calls, service_tier, store, stream, text,
  tool_choice          all identical
  reasoning            {"effort":"high"} vs {"effort":"medium"} — session preference,
                       and "medium" is the harness's own DEFAULT_THINKING_LEVEL
  tools[].strict       null in both (not false, not absent)
```

That diff found two real deviations that reading had missed: `service_tier` was absent
entirely, and `reasoning` was omitted when no effort was requested where a harness request
always carries it. Both fixed. Outgoing headers were captured the same way and match, including
`originator: pi` and the `pi (darwin <release>; <arch>)` user agent — with Node's `x64` spelling
rather than uname's `x86_64`.

**One known residual difference**, recorded because pretending otherwise would be worse:
URLSession adds `Accept-Language` to every request and it cannot be suppressed from
`httpAdditionalHeaders`. Node's fetch does not send it. It is a transport-layer default of every
native macOS client rather than an application-level identity signal, and hand-rolling an HTTP
stack to remove one standard header would be a far larger deviation than the header is.

Credentials live in the harness's own `auth.json`, in the same shape and mode 0600, so a login
done in either client works in the other. There is one account; two stores would mean two
logins and a refresh race.

`Aviary --codex-login` runs the flow. `--paste` adds a manual code entry that **races** the
browser callback rather than replacing it — the reference does this, and implementing them as
alternatives broke a real login: the paste prompt returned immediately, tore down the listener,
and the browser's redirect hit a closed port. The listener binds `127.0.0.1` only, and a state
mismatch answers 400 and keeps waiting rather than ending the login, both matching the reference.

### Resuming a session

`AgentRunner.Settings.resume` continues an existing session: the run appends to that
transcript and picks up its conversation. `SessionResume` rebuilds the message list, and it is
built on `SessionParser` rather than re-reading the JSONL — the parser already decides which
branch is live, so **what gets replayed is exactly what the transcript shows**. A second
reader would eventually disagree with the screen, invisibly.

Four things it has to get right, each with a test:

- **`parentId` threading.** Entries form a tree and the parser walks backwards from the *last*
  line, so a resumed run whose first entry has no parent orphans the whole prior conversation.
  The transcript would then show only the new turns and look perfectly well-formed doing it.
  `SessionWriter.init(home:resuming:…)` seeds `lastEntryID` from the file.
- **One session header.** A reader that meets a second one treats the tail as a different
  session, so the resuming initialiser writes no header.
- **Unfinished tool calls.** A call with no result is not a valid request, and the run that
  died mid-tool is exactly the one worth resuming — so each gets a synthetic error result
  saying the previous run ended before it returned. An empty *string* result is left alone;
  only a missing result entry is synthesised, which is why the distinction matters.
- **Compaction.** History is cut at the marker and rebuilt as first task + summary + tail,
  reproducing `compactIfNeeded`'s in-process shape exactly. A resumed run whose history
  differs in shape from a run that compacted while alive is a divergence nobody would see.

Visible reasoning is dropped rather than replayed. The routes that produce it want their own
encrypted form echoed back — Codex's `reasoning.encrypted_content`, deliberately not persisted
— and sending the human-readable summary in its place would be a quiet lie about what the
model previously thought. It costs the model its earlier train of thought, which is the
cheaper of the two errors.

Every departure from the file is counted and surfaced: `SessionReplay.caveat` becomes a line
in the UI *and* an `aviary.resume` note in the transcript, so a session read back tomorrow
still says its history was altered.

`AgentRunner.prepare()` builds a run without sending anything. That is how the UI resumes —
continuing a session opens a run whose conversation is already there and then waits for what
you want to say next, which is not the same as sending an empty prompt.

Fixed on the way, because resume inherited both: `model_change` entries were written unparented
(so they never landed on the active branch and never rendered) and keyed `model` where the
parser reads `modelId` (so every Aviary-written session recorded an empty model). Each bug hid
the other. The parser now accepts both keys so sessions already on disk render too.

### What the harness still does and this does not

Two gaps closed since this list was written: resuming a session (above) and the
reachable-model catalogue (below). Workshop dispatch now routes through the engine picker
too — it was the last place that built a harness `RunConfiguration` regardless of what the
picker said.

**The daemon, kernels, workers and live-session list.** `DaemonInspector` talks to the harness
supervisor socket, and Health's Supervisor card, the cockpit's kernel tile and the "Working
agents" sidebar all read it. The in-house engine has runtime hosts instead; whether those
cards map onto runtime-host sessions or go away is an open decision.

The Anthropic subscription login, as a *provider*. Still deferred, and now for a settled
reason rather than a pending one: the harness's own docs say its Claude Pro/Max login bills as
extra per-token usage rather than against plan limits, so that path was never about cheaper
tokens — only about which client Anthropic sees. Plan-included Claude usage needs Claude Code
itself, which is what the third engine below is.

## Claude Code driving

The third engine, and it is not a third provider. It is a different arrangement of the same
parts, so it gets said plainly: **Claude Code owns the loop, and Aviary's kernel is the only
tool it gets.**

The reason it has to be that way around is one measured fact. Claude Code will not accept a
conversation history — `--input-format stream-json` reads `user` lines and *silently discards*
`assistant` lines, so there is no way to hand it a prepared transcript. Every design that keeps
Aviary's loop therefore has to degrade the tool channel: flatten the history into one giant
user message each turn, or forge session files, or feed tool results back as prose. All three
drift away from the format the model was trained on, and they do it quietly — a session that
looks fine and reasons slightly worse. `plans/claude-code-as-transport.md` has the experiments.

So the loop is given away and the valuable part is kept. That trade is better than it sounds,
because almost nothing that makes an Aviary session worth more than a chat window lives in the
agent loop:

| Kept | Given up |
|---|---|
| The persistent interpreter, its variables and open handles | Aviary's agent loop |
| `sh()` with a working directory that survives | Steering — Claude Code owns the turn boundary |
| Skills, ranked against the prompt rather than all sent | Sub-agents (`spawn` needs a runner) |
| `remember` / `recall` / `conversation` | Model switching mid-run |
| `AGENTS.md` / `CLAUDE.md` for the working directory | Resuming an Aviary session |
| The transcript, in Aviary's own format | Compaction, and Aviary's own message log |

### The courier, and why there is one

MCP servers are spawned *by* the client, so the process that answers `tools/call` is a child of
`claude` — not of Aviary, and therefore not the process holding the kernel.

```
Aviary ──▶ claude -p ──▶ Aviary --mcp-bridge   (MCP on stdio)
   ▲                             │
   └──────── loopback ───────────┘
   │
   └──▶ RuntimeHost (python3 host.py)          (the actual kernel)
```

`Aviary --mcp-bridge` is the same binary in a headless mode, so there is no second artifact to
keep in step. It holds no state: the tool list and every result come from the Aviary that
opened the bridge.

Loopback TCP with a token, not a Unix socket with file permissions. The token reaches the
courier through its **environment**, which another user cannot read, whereas anything in
`--mcp-config` lands in the courier's argv and is visible in `ps` to everybody on the machine.
Since this endpoint runs arbitrary Python on request, an argv-visible path to an
unauthenticated port would have been a real local privilege surface.

### The flags are the design

Three groups, none of them obvious:

- `--tools ""` empties the built-in tool set. The model does not then hallucinate tool calls;
  it reaches for the one tool that was attached.
- `--setting-sources ""`, `--strict-mcp-config` and `--disable-slash-commands` together are the
  difference between **286 input tokens and 80–106k**. That gap is the developer's own
  environment — global `CLAUDE.md`, plugins, skills, every claude.ai MCP connector — being read
  in as context.
- `--bare` is deliberately **not** used, despite being the documented mode for scripted runs.
  Bare mode never reads OAuth credentials or the keychain, so the flag designed for
  programmatic use is exactly the one that removes the subscription this engine exists to use.
  The docs say bare may become the `-p` default, which makes this a standing durability risk.

Two smaller traps: `--allowedTools` is variadic, so its value is comma-joined rather than
space-separated or it swallows whatever follows; and the strip-down is verified against the
run's own `system/init` frame rather than against the flags passed, because a hook has been
observed firing even with `--setting-sources ""`.

### What the environment can silently do

Claude Code's auth precedence puts `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and the cloud
provider flags *above* subscription OAuth. A machine with one set runs perfectly and bills
metered credit — a failure with no symptom, and the one that would make this whole engine
pointless. So `ClaudeCode.scrubbedEnvironment` strips them, `apiKeySource: "none"` in the init
frame is the check that it worked, and Health says so when your shell has one set.

Stripped alongside them: `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET`
and friends. Aviary is developed from inside Claude Code, so those are routinely in its
environment, and handing a child the parent's session id and messaging socket makes it a
participant in a conversation it knows nothing about. `CLAUDE_CODE_OAUTH_TOKEN` is *not*
stripped: it is the documented way to authenticate a headless subscription session, so somebody
who set one meant it.

### Reading the stream

`--output-format stream-json --include-partial-messages` emits raw Anthropic SSE frames.
Two findings there cost a capture each, and both contradicted what could be inferred:

**Thinking text is available.** The research this was built on concluded reasoning comes back
empty in `-p`. That is true of the *complete* block on some routes, but the `thinking_delta`
frames carry the real text — so a driven run shows visible reasoning, and
`--include-partial-messages` is not optional.

**The finished token counts are on `message_delta`.** An `assistant` frame arrives once per
completed content block, all sharing one message id, and each carries the `message_start`
snapshot — whose `output_tokens` is a stub of 2 or 3, with no `output_tokens_details` at all.
The `message_delta` figures are the real ones, and they sum exactly to the `result` frame's
aggregate. That is why the running total is summed per message rather than taken from `result`:
the transcript's own entries then add up to the number the Usage screen shows.

A related trap cost two wrong diagnoses. Turns were coming back as `input=2`, which looked like
a placeholder and was not: Claude Code caches aggressively and Anthropic reports cached context
*outside* `input_tokens`, so a real turn reads `input 2, cacheWrite 3953` and the next one
`input 2, cacheRead 3953`. So `totalTokens` here is cache-inclusive, diverging from
`AnthropicMessagesProvider`, which sums `input + output` only and would report 83 tokens for a
turn that processed about four thousand. The cache-inclusive sum is also what `Usage(json:)`
falls back to when no `totalTokens` was written, so it is the arithmetic the reader already
believes. **The Anthropic provider undercounting the same way is a separate bug, not yet
fixed.**

### Accounting

The provider is recorded as `claude-code`, not `anthropic`. Not cosmetic — which *client*
Anthropic sees is precisely what decides whether tokens came out of the plan or out of metered
credit, so it is the distinction the ledger has to keep.

No prices. A subscription run's tokens were not billed per token, and `total_cost_usd` in the
stream is documented as a client-side estimate, so pricing them at list would invent spending
that never happened. `sessionsWithoutPricing` already means "no rates published", which is
exactly the true thing to say. What *is* reported is the `rate_limit_event` frame:
`isUsingOverage` is the difference between the plan allowance and paying per token, and it is
surfaced rather than inferred.

### Claude Code is a provider in the catalogue

It would have been easy to leave the driven engine's model choice where it started: a small
`sonnet / opus / haiku` picker tucked inside the Engine card. That was wrong in a way worth
naming, because the New Run sheet then showed **two** model pickers — the ordinary
provider-and-model pair, still live and still ignored, and the real one below it. This app's own
stated rule is that it never offers a control which would quietly do nothing.

So `claude-code` is a provider in `BuiltInProviders`, alongside `openai-codex`. It has no
`baseUrl` and no key expression, because it is not an HTTP route and Aviary never sees the
credential — reachability comes from `claude auth status` and is passed into
`ModelCatalogBuilder.build` through `credentialed`, the same channel a configured provider's
resolved key uses. Its ids are Claude Code's own `--model` aliases rather than full model ids.

What that buys, beyond one picker instead of two: it appears on the Models screen, it can be
reordered, and it can be switched off — the same as everything else. "Which model is answering"
is the same question for a driven run as for any other, and answering it in a separate place is
what made the two pickers disagree.

The engine still comes first, and the Model card is filtered by it: the driven engine offers only
`claude-code` models, and the other two engines exclude them. Filtering rather than reordering,
because the engine decides who makes the request — Claude Code holds its own credential and
serves only Claude models, and neither of the other engines can drive Claude Code.

One rendering trap this exposed: the Models screen labelled built-in providers from
`auth.json`, which is where Codex keeps its credential. Claude Code's lives in the `claude`
binary's own keychain entry, so a reachable provider rendered as signed-out. The label now comes
from the catalogue's own spec.

### One assembly, two callers

`ClaudeCodeSession.prepare` builds the whole thing — auth check, kernel, gated skills and
memory, bridge, callbacks — and both the GUI driver and `--claude-code` call it. They each did
this independently at first, which is the arrangement where a windowed run and a terminal run
quietly stop being the same thing: while building, only the CLI gets exercised, so a divergence
lands in the GUI and is found by a person using it.

`--claude-code "<prompt>"` also has to close stdin once its prompt is sent. Claude Code with
`--input-format stream-json` waits on stdin indefinitely, which is right for a session that
stays open and means a one-shot never ends.


## The reachable-model catalogue

Which models are offered is worked out locally, by `ModelCatalogBuilder`. It used to be asked
of the engine over RPC — `get_available_models` — because built-in OAuth providers are absent
from `models.json` and the harness was the only thing that knew about them. Aviary has its own
`BuiltInProviders` now, so the answer can be assembled without booting Node, and opening the
Models screen no longer starts a process.

Reachable means the same thing it did: backed by credentials that resolve. A built-in provider
is reachable when its OAuth login is stored; a configured one when its `apiKey` expression
resolves to something non-empty, which means actually running the `!command` form. A provider
that is configured but has no working credential is kept and shown as unreachable, because
"you configured this and it is not working" is more useful than showing nothing. On this
machine the local build reproduces the RPC catalogue's count exactly: 18 from `models.json`
plus 13 built-in Codex models, 31 either way.

The precedence matches `AgentCLI.resolve` — a `models.json` entry beats a built-in with the
same id, because configuring a provider explicitly means you meant it.

If an Anthropic subscription login is added, it needs a `BuiltInProviders` entry too, or its
models will be missing rather than merely unreachable.

### Order and disabling are yours, and live outside models.json

`ModelPreferences` holds an order and a set of disabled models, stored in Aviary's
Application Support directory. Not in `models.json`: that file is hand-maintained and records
facts about providers, whereas "don't offer me this" is a fact about you — and writing a
cosmetic preference into a file another tool owns would mean rewriting it on every drag.

Four rules, each tested, all of them about not surprising you later:

- **Keyed on the qualified id** (`provider/model`). A bare model id is not unique: the same
  weights are often reachable directly *and* through a gateway, at different prices. Hiding one
  route must not hide the other.
- **Unlisted models sort last but keep catalogue order.** A model that appears in `models.json`
  tomorrow neither jumps to the top of your list nor disappears from it.
- **Disabled is a denylist, and it only affects pickers.** `ModelCatalog.find` ignores it, so
  disabling a model cannot break resuming a session that already uses it. A preference about
  what to offer is not a claim the model is gone.
- **Pinning one group leaves the others alone.** Reordering a provider's models re-pins only
  those ids, at the position the group already held, so another provider's ordering is not
  collateral damage.

Reordering and disabling re-derive the catalogue without re-resolving credentials — one of the
key expressions on this machine shells out through `zsh -ic`, and paying that per drag would
make the list feel broken.

Each provider's own model list is sorted to match the flat list, so a per-provider picker and
the flat switcher cannot disagree.

### Retired daemon surfaces

The harness runs a supervisor daemon: a long-lived process holding sessions, owning a socket and
an ownership lease, and managing a pool of IPython kernels and worker processes. The in-house
engine has none of that — it runs agents in-process and interpreters in a runtime host it owns.

Several screens described that daemon, and on the in-house engine they described it *wrongly*
rather than merely uselessly: a live in-house run still rendered "Nothing running" in the
sidebar and "the background service is holding no sessions" on Live. These are no longer
displayed:

| Surface | Where it lives now |
|---|---|
| Supervisor card (pid, build, socket, lease) | `HealthView.supervisorCard` |
| Processes card (kernels, engine procs, workers) | `HealthView.processCard` |
| Workers card | `HealthView.workersCard` |
| "Working now" card and its stat tile | `CockpitView.workingNow` |
| Kernels stat tile | removed inline |
| Daemon health and supervisor pid rows | removed inline from `CockpitView.environmentPanel` |
| "Running elsewhere" card | `RunningElsewhereCard` in `RetiredDaemonSurfaces.swift` |
| "Working agents" sidebar section | `WorkingAgentsSection` in `RetiredDaemonSurfaces.swift` |

Kept rather than deleted, because the harness is still selectable and retiring a screen is a
cheaper decision to reverse than rebuilding one. The already-extracted ones stayed where they
were; the two that were inline were extracted into `RetiredDaemonSurfaces.swift`. Nothing
references them, and Swift does not warn on an unreferenced view, so they cost nothing. Putting
one back is adding its name to the relevant `body`.

**Two things were deliberately kept.** The Health verdict, with its `Re-check`, `doctor --fix`
and `Force shutdown` controls, is the failure surface rather than a status card — while the
harness is still the default, a wedged daemon needs somewhere to be visible and fixable. And
the wedged-daemon and version-mismatch notice banners on the cockpit, for the same reason: they
appear only when something is actually broken. Both are worth removing once the in-house engine
becomes the default, not before.

`refreshDaemon` still runs. `liveSessions` feeds `annotateLiveState`, which marks a session row
in the catalogue as live — that is still true and still useful regardless of which engine is
running.

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

### Markdown is parsed as blocks, then inline within each block

Prose used to go through `AttributedString(markdown:)` in
`inlineOnlyPreservingWhitespace` mode. That mode was chosen for a real reason — full
markdown parsing collapses the newlines that structure an answer, and a long reply reflowed
into one blob is materially harder to read — but the price was that every *block* construct
rendered as its own literal syntax. A four-item numbered list was four lines starting with
a digit and a dot.

`MarkdownParser` (in `AviaryCore`, so it is testable without a window) resolves that rather
than picking a side: it splits prose into blocks, and inline markdown is parsed within each
block. Newlines survive because block structure is what decides them.

It is deliberately not CommonMark. Two of its rules are judgement calls about what agents
actually emit, and both are pinned by tests:

- **A table needs its delimiter row.** Prose containing a pipe (`grep x | head`) is far more
  common in agent output than a table is, and a permissive check turns any such line into a
  one-column table.
- **List depth follows the indent columns observed**, not an assumed two- or four-space step.
  Models mix both, sometimes within one reply, so depth is assigned in the order new columns
  appear and outdenting discards the levels it left.

Where it cannot recognise something it falls through to a paragraph, so unrecognised input
degrades to exactly the old behaviour instead of vanishing. Search wins over formatting:
while a query is active every block renders as highlighted plain text, because a match
inside a run that markdown consumed is a match the reader cannot see.

User prompts go through the same path. They were the only plain-text role in the
transcript, and a prompt is written in markdown like everything else.

## Reloading Aviary after the workshop changes Aviary

The workshop agent edits this app's own source, so the result of a request is invisible until
the binary is rebuilt and the process replaced. Quitting, rebuilding by hand and reopening is
three steps and a lost train of thought, for a change you asked for and are waiting on.

**Not hot reload in the code-injection sense.** The process is replaced, not patched — that
would need `-Xlinker -interposable` and an injection framework, and there is no Xcode here to
hang one off. What makes it *feel* like a reload is that the slow part has already happened:
the build starts the moment the request is marked done, in the background, so the click is
immediate — and the app comes back on the screen you were on with the agent reattached.

One fact makes it possible at all, and it was verified rather than assumed: **SwiftPM can
relink `Aviary` while `Aviary` is running.** The linker writes and renames, and macOS permits
renaming over the file backing a running image.

### The decisions, and why each one is a decision

`WorkshopReload` in the core holds them, so they are tested without a window, a process or a
compiler. Each is a place where the obvious shortcut is wrong.

**Fire on the transition into `done`, and never on first sight of it.** A request seen as done
for the first time is one that was already finished when the window opened. Treating that as
news makes the app rebuild itself on every launch — which is why the board is baselined
*before* the watcher starts.

**Read the launch mode off the running image.** `build/Aviary.app`, `.build/debug/Aviary` and
`.build/release/Aviary` are rebuilt three different ways, and rebuilding the wrong one succeeds
and changes nothing visible — the most confusing outcome available. A bundle is rebuilt whole,
via `scripts/bundle-app.sh`, because the plist, icon and ad-hoc signature are part of what
makes the running app the app.

**Compare the executable before and after.** A request that only touched documentation, the
agent's brief or the board itself builds cleanly and changes nothing, and offering a relaunch
for that teaches you to ignore the banner. This has a sharp edge worth knowing: a
**comment-only source change compiles to a byte-identical object**, llbuild skips the relink,
and the executable keeps its mtime. That is genuinely nothing to reload for — but while testing
this it reads exactly like the trigger having failed, and it cost two rounds of wrong diagnosis.

**Show the first errors, not the tail.** The tail of a failed `swift build` is `error:
emit-module command failed`, which says nothing. Two kinds of duplication have to go first: an
error repeats once per compilation its file takes part in, and every diagnostic is followed by a
source-excerpt line restating it under a caret — which contains `error:`, is not an identical
string, and so survives naive deduplication and doubles the banner.

**A failed build offers no relaunch.** The executable is unchanged, so relaunching would show
you the old app while you believed you were looking at the new one. Instead the banner offers
*Tell the agent*, which appends the compiler errors to the request as a note — the agent marked
this done and it does not compile, which is exactly the thing it needs to know and the one
thing it cannot observe, since it is not the process that builds.

### Replacing the process

macOS activates the existing instance rather than starting a second one with the same bundle
identifier, so the new app cannot start until this one is gone — and this one cannot start
anything after it has exited. So a detached `/bin/sh` waits for the pid to disappear and then
launches. Runs are stopped first rather than left to die with the process, so each closes its
session file and its runtime host exits cleanly; a killed host leaves a kernel process behind
and a transcript with no final entry.

What survives the replacement is what makes it a reload rather than a restart: the section you
were on, the request you had selected, and whether the workshop agent was attached — written to
`UserDefaults` with a timestamp, restored only if it is under three minutes old, and cleared
unconditionally either way so a stale position cannot fire on some unrelated launch days later.

### Automatic build, manual relaunch

The build is automatic. The relaunch is one click, and the default is deliberate rather than
timid: **right after the agent finishes a request, the session that finished it is usually still
attached and holding a live interpreter.** Relaunching ends it. The transcript survives and the
session can be resumed, but that interpreter's variables cannot — so the banner names the cost
at the moment of the decision, and there is a preference for those who would rather not be
asked.

`AVIARY_RELOAD_DEBUG=1` logs each step. Worth having because this path is invisible by
construction — it runs while you are looking at something else, and its most likely failure is
doing nothing at all, which has no symptom.

### Why the app needs a real signing certificate

Screen Recording is asked for once per *build* unless the app is signed with a certificate, and
the reason is worth writing down because the symptom points away from the cause.

`codesign --sign -` (ad-hoc) produces no certificate. macOS then has nothing stable to identify
the app by and derives its designated requirement from the code itself:

```
# designated => cdhash H"65480ad2c9b405e95d5a884ae24486ebb69ebd96"
```

TCC stores that requirement next to the grant. Any rebuild changes the cdhash, the requirement
stops matching, and macOS is right to treat it as an app it has never seen. Meanwhile System
Settings still lists Aviary with its switch on — the row is keyed by bundle identifier, while
the grant behind it is bound to a build that is gone. So the place you would go to fix it shows
nothing wrong and offers nothing to change.

`scripts/make-signing-cert.sh` creates a self-signed code-signing identity; `bundle-app.sh` uses
it when present and falls back to ad-hoc with a warning when not. With a certificate the
requirement becomes `identifier "works.duckbill.aviary" and certificate root = H"..."` — root
rather than leaf, because a self-signed certificate is both — and that is identical for every
build. `bundle-app.sh` prints the requirement on every build and calls out a `cdhash` one,
because that single line is the difference between grants that persist and grants that do not.

**The partition list is the part that bites.** A certificate can be present, trusted, and listed
by `security find-identity -v -p codesigning`, and signing can still be broken — because
authorising *codesign to use the key* is a separate setting. Without it `codesign` does not
fail; it blocks on a GUI password dialog. Interactively that is a nuisance; unattended, and the
workshop reload starts unattended builds, it is a hang that leaves a half-written `.cstemp`
inside the bundle, after which every signing attempt fails with "invalid or unsupported format
for signature" naming that temp file — which reads like a corrupt bundle and is not.

So the script proves its work by signing a throwaway binary under a deadline rather than
trusting that a healthy-looking identity works, and it is idempotent in the way that matters: it
repairs an existing identity instead of early-exiting on one, because the certificate and its
authorisation fail independently and the second failure looks like success.

Two smaller traps: `codesign` refuses a self-signed certificate that is not trusted for code
signing, so the trust step is not optional; and Apple's `security import` cannot read OpenSSL 3's
default PKCS#12 encryption, failing with "MAC verification failed … (wrong password?)", which
reads like a typo and is not one. Pass `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg
sha1`.

This matters more since the workshop reload landed. That feature exists to rebuild the app more
often, which means it multiplies exactly this prompt.

## Two switch statements over one enum

`AgentCLI` and `InHouseDriver` each mapped a provider's `api` to a client, and only one of them
had a case for `openai-codex-responses`. So the terminal ran Codex correctly while the GUI fell
through to the completions client and posted to `chatgpt.com/backend-api/chat/completions`,
which answers `404 {"detail":"Not Found"}`. That reads as a broken model, not as a missing case,
which is why it survived until somebody tried to resume a Codex session from the app.

`ChatProviderRouting.makeProvider` is now the only place that decision is made, and both
callers use it. `resolveSecret` is injected so it can be tested without shelling out to a
`!command` key expression. Codex is also the one route that supplies its own endpoint, so
`needsBaseURL` exists: for every other api a missing `baseUrl` is a real configuration error
worth reporting before the run starts.

The general shape is worth remembering, because this codebase has now produced it twice — the
other was `ClaudeCodeSession.prepare`, extracted after the CLI and the GUI assembled a driven
session independently. **Two code paths switching over the same set of cases will diverge, and
the one that is exercised less is the one that breaks.**

## A dead kernel must stop the model, not feed it errors

A driven session found in the wild had twenty-six consecutive
`the runtime host is not running` tool results. Claude Code owns the loop, so a tool that
errors is an invitation to try again — and against a kernel that is never coming back it will
retry indefinitely, spending plan quota on a fixed outcome.

Aviary cannot stop that loop from the tool side; it can only change what the result *says*. So
`ClaudeCodeKernel` counts consecutive machinery failures, and on the second one the message
stops being an error report and becomes an instruction: the interpreter is gone, do not call
this again, stop and report what you had. A tool result is the only channel available, so it has
to carry the control signal.

### Why the kernel died: teardown order, and SIGTERM as a request

`ClaudeCodeRun.stop()` closed stdin, called `terminate()`, and moved on. Two things were wrong.

`claude` **does not die on SIGTERM** — verified directly: a plain `kill` left it running and
only `kill -9` ended it. So a stopped run left an orphaned `claude` reparented to launchd,
still holding its MCP courier. One was found alive thirteen minutes after its Aviary had exited.

And the order was backwards. The kernel was being torn down while its caller was still alive,
which is what turns "the run stopped" into "the run keeps calling a session that is being
dismantled". Now the model process is ended first and *verified* — escalating to SIGKILL after
two seconds, the same escalation `RuntimeHost.stop` already did for its own child — and only
then does anything it might call go away.

Orphaned `host.py` processes from earlier sessions were found too, which suggests the in-house
path can leak a kernel the same way. Not yet chased down.

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
in an `NSWindow`, and writes a PNG per screen via ScreenCaptureKit. `ImageRenderer` cannot do
this job — it refuses `NavigationSplitView` and draws SwiftUI's "unsupported" glyph.

Capture asks the WindowServer for the composited window, the same way the Workshop's own
capture does and for the same reason. It did not always: it used `cacheDisplay`, and
`cacheDisplay` captures *NSView drawing* only, while most SwiftUI content lives in CALayers
with no backing NSView. The symptom was that cockpit, live, usage and health came out blank
while sessions, library, flock, models and workshop rendered — and the dividing line was
whether the detail pane held a `List`, which is AppKit-backed and therefore does draw. The
tell was a class histogram of the captured view tree: the screens that worked had 34-45
`ListTableRowView`s, the blank ones had only the 12 sidebar rows. Their content was never
missing; it was never an NSView. Swift Charts, being pure layer content, never appeared at
all.

Two things fall out of that fix. The window is raised with `.floating` and the app activated,
because `SCShareableContent` is queried with `onScreenWindowsOnly: true` and will not capture
a window it cannot see. And `cacheDisplay` stays as the fallback for a machine without a
Screen Recording grant, where it renders AppKit-backed content and nothing else — a degraded
shot rather than no tool.

Known limits, both in the capture path rather than the app:

- The window does not draw reliably until it has been through a couple of section
  transitions, so every screen is rendered twice and only the second pass is written.
  Longer settle times do not help; forcing a rebuild with `.id()` makes it worse.
- Without a Screen Recording grant the fallback path applies, and there the old limits
  return in full: the sidebar comes out white, vibrancy is absent, and layer-only content
  including every chart is missing. If a shot looks like that, check the grant before
  believing anything it shows.
- Read colours in `--bare` with suspicion: bare mode has no window background, so
  light-on-light text is an artifact of that, not a contrast bug.

### The greedy-child trap (2026-08-21)

Screens used to capture as identical blank frames, and the cause turned out to be three
separate things stacked on each other. Two were real layout bugs — worth knowing because
the symptom in each case was *a missing header* rather than anything that pointed at
height — and the third was the capture instrument itself:

1. `present()` pinned the hosting view with `.frame(width:height:)`. A
   `NavigationSplitView` given a hard frame lays out against a proposal it never receives
   in the real app, and its sidebar comes back empty. The hosting view is now sized by the
   window and autoresizes. This fixed the empty sidebar, and re-pinning reproduces it, so
   the fix is load-bearing — but it did **not** fix the blank frames. `cockpit`, `live`,
   `usage` and `health` stayed blank for two more rounds of investigation, which is worth
   recording: a real fix that changes the symptom you happen to be looking at is easily
   mistaken for the fix.
2. `EmptyStateView` applied `.frame(maxHeight: .infinity)` and *then* `.padding(40)`.
   Frame-then-padding makes a view report back more height than it was offered, so the
   parent re-proposes the larger value and the height runs away — measured at 3040pt and
   still climbing inside a 963pt pane. Padding now goes inside the frame.
3. `cacheDisplay` could not see layer-only content at all (above). This was the actual
   cause of the four blank frames, and it was the last thing checked because the two real
   bugs above made a layout explanation look overwhelmingly likely.

The lesson that generalizes: **a screen that resolves taller than its own pane does not
just clip.** `NavigationSplitView` re-solves the whole window for it, and the casualty is
whatever else shares the window — in this case the sidebar went blank on one tab and only
that tab. If a screen has a greedy child, pin the screen to `GeometryReader`'s size, and
measure with a geometry probe before theorising. Two `onChange(of: g.size)` probes found
in one build what four rounds of guessing did not.
