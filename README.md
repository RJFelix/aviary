# Aviary

A native macOS workspace for coding agents, backed by a cross-platform headless Work Host.

It started as a GUI over the Prime Agent harness and now has its own agent: its own provider
clients, loop, Python runtime host, memory, canonical journals, and Work-service protocol. The
inherited Node harness is gone. In-house Work runs under Aviary's own `aviaryd` process so it can
outlive the GUI that started it and be observed or controlled by another authorized client.

Prime Agent was the useful starting point: one IPython kernel as the only tool, a
hundred-odd provider routes, recursive sub-agents, compaction, a daemon that keeps sessions
alive after you close the terminal. All of it is driven through a TUI, which means the parts
that are *structural* — a fan-out of twelve sub-agents, where the tokens went, why a
provider 401s, which of four processes is wedged — are things you reconstruct by reading
scrollback.

Aviary is the view of that structure.

```
aviary/
├── app/         SwiftUI GUI, pure-Swift core, aviaryd, and self-tests.
├── runtime-hosts/  The Python runtime-host processes used by in-house Work.
├── scripts/     Bundling and the icon (drawn in Python, not checked in as a binary).
├── docs/        Architecture notes.
└── justfile     Every task worth naming.
```

## Running an agent

Aviary runs agents itself — no inherited harness or Node runtime:

```sh
just build
Aviary --agent "count the swift files under app/Sources" --model litellm/claude-haiku-4-5
```

Sign in to ChatGPT for the Codex models with `Aviary --codex-login` (add `--paste` if the
browser redirect cannot reach this machine). Credentials live in Aviary's own `auth.json`.

Flags: `--cwd <path>`, `--host python3-shared` (for numpy/pandas), `--record` (capture request
payloads), `--budget <tokens>` and `--minutes <n>` (a goal the agent can see and plan against),
`--quiet`. A prompt starting with `/name` expands a prompt template. In the GUI, the Chats view's
launcher picks between the in-house engine and Claude Code driving.

What the agent gets: one tool, `python`, running in a persistent interpreter where variables
survive between calls. Inside it, `sh(command)` with a working directory and environment that
*persist* across calls, `spawn(prompt)` for sub-agents, `conversation(limit)` to read its own
history, and `remember`/`recall` for things worth keeping. Skills are ranked against the prompt
rather than all injected. MCP servers from `settings.json` appear as individual tools.

`just host` drives a runtime host by hand, which is the fastest way to explore one or to check a
new one against [docs/runtime-host-protocol.md](docs/runtime-host-protocol.md).

## Letting Claude Code drive

The other engine, and the one arrangement that is upside down on purpose:

```sh
Aviary --claude-code "which file in AviaryCore is the largest, and by how much?"
```

**Claude Code owns the loop; Aviary's kernel is the only tool it gets.** It has no Read, Edit,
Grep or Bash — one `python` tool in Aviary's interpreter, which can already do all of that. So
the interpreter, `sh()`, the gated skills, `remember`/`recall`, your `AGENTS.md` and the
transcript format all stay Aviary's, while the turn-taking belongs to somebody else.

It is that way around because Claude Code will not accept a conversation history — it reads
`user` lines from its input stream and silently discards `assistant` lines. Keeping Aviary's
loop would mean flattening every turn into one giant user message or feeding tool results back
as prose, which drifts away from the format the model was trained on and does it quietly.
[plans/claude-code-as-transport.md](plans/claude-code-as-transport.md) has the experiments;
`docs/architecture.md` has the design.

The reason to want it: tokens come out of the Claude plan rather than metered API credit, and
Aviary reports which — `plan usage (five-hour)` or `extra usage`, read from Claude Code's own
rate-limit frame rather than guessed. What you give up is steering, sub-agents, mid-run model
switching, and resuming an Aviary session, because the conversation belongs to Claude Code.

## Seeing what the workshop built

The workshop agent edits Aviary's own source, so its work is invisible until the app is
rebuilt. Aviary watches its own board: when a request is marked done it starts the build in the
background, and a banner offers to replace the running process — coming back on the screen you
were on, with the agent reattached.

Not hot reload in the code-injection sense; the GUI process is replaced, not patched. What makes
it feel like a reload is that the build has already finished by the time you look, so the click is
immediate. In-house Work remains owned by `aviaryd` across the GUI relaunch and the new client
reattaches; a Claude Code-driven session has different survival capabilities and is labeled
accordingly. Preferences → Workshop turns either half off.

## What it does

| Screen | What it answers |
|---|---|
| **Chats** | Write a request, continue a conversation, understand activity, and review changes. Native requests are saved before agent startup; a failed start leaves the prompt and recovery controls in the chat. Advanced attachment controls live under Manage agent connections. |
| **History** | Read recorded and imported transcripts. Python cells next to their output, thinking collapsed, injected context folded away, tool errors flagged, per-message token and cost accounting. |
| **Workshop** | Capture, track, and review improvements to Aviary. Improve Aviary is always available at the foot of the sidebar and with ⇧⌘I. |
| **Flock** | The sub-agent tree: who spawned whom, with what instructions, on which model, and a timeline showing whether that fan-out actually ran in parallel. |
| **Models** | Every provider and model, and whether the credential will resolve — see below. |
| **Usage** | Tokens and cost across every session on disk, by model, provider, project, and day, plus cache-hit and tool-error rates. |
| **What was sent** | Optional per-run recording of every provider payload, decomposed: system prompt, each discovered context file, every skill description, tool schemas, messages — with each part's share of the input you were billed for. |
| **Library** | Skills, prompt templates, extensions, packages — and every directory that was searched, including the empty ones. |
| **Diagnostics** | Inspect runtime and connection health; distinguish agent-service readiness from Python availability. |

⌘K searches all of it at once.

## Two design decisions worth knowing

**The GUI is a client; the Work Host owns execution.** Session parsing, catalogs, reducers,
credentials, analytics, and the transport-neutral Work-service contract are Swift. `aviaryd`
owns in-house agents, journals, and runtime-host processes; the GUI can disappear without issuing
End, then reconstruct and reattach through canonical cursors. The first transport is a private
Unix-domain socket. SSH stream-local forwarding proves the protocol can cross devices, but native
remote discovery and device authentication are still future product work.

**Aviary hands local subprocesses your login shell's environment.** A macOS app inherits
launchd's environment, not the one `.zshrc` builds. So at startup Aviary snapshots `zsh -ilc env`
once and uses it for local subprocesses. The Models screen resolves each key expression through
the same path and tells you which of the three forms (`!command`, environment variable, literal)
applied and what happened, without displaying credential values.

## Where did my input tokens go?

A short conversation can still carry a large model context: instructions, discovered context
files, skills, tool schemas, and earlier messages all contribute. Native in-house runs record
a bounded context manifest for each provider crossing and, before dispatch, retain the message,
tool-schema, and prompt-source bodies needed by guarded cold conversation resume. Resume still
requires valid retained bodies and compatible runtime capabilities. **Context and working state**
in the chat shows the last recorded crossing and its
source decomposition, separately from runtime state. It does not predict the next request or
prove that a Python namespace survived a restart.

For additional provider-wire inspection, start a run with **Record what's sent to the model**.
This captures the provider payload at its request boundary and offers a separate wire breakdown:

```
PART                                               chars   tokens   share
system prompt                                      66627    15523   89.5%
  available skills — 68                            46713    10883   62.7%
  (base instructions)                              10200     2376   13.7%
  AGENTS.md                                         6335     1475    8.5%
input — 1 message                                   6086     1417    8.2%
tools — 1 schema                                     785      182    1.1%
```

That is a real reading of a real request: 68 installed skills were 63% of the input on
*every* call. Character counts are measured; token counts are estimated at four characters
each, then rescaled by each part's exact share of the provider's own input count — so the
figures are anchored to something billed rather than to a heuristic. On the payload above
the raw estimate came within 7% of the billed total.

Optional wire recording is off by default and per-run, because it writes your full system prompt
and conversation to a file. This switch does **not** disable the native retained context bodies
used for guarded cold conversation resume; those also contain sensitive prompt content. The wire
breakdown is available from a shell:

```sh
Aviary --analyse-wire ~/Library/Application\ Support/Aviary/wire/run-*.jsonl --input-tokens 17351
```

**Reasoning tokens.** Where a route returns thinking as text, Aviary shows each block's
size inline. Where it doesn't — the Codex route encrypts its reasoning — Aviary preserves
`output_tokens_details.reasoning_tokens`, so at least the count survives.

## Build and run

### Optional OpenTelemetry tracing

Tracing is off by default and backend-neutral. Enable it for each process at launch with
`AVIARY_OTEL_ENABLED=1` and `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` pointing to an OTLP/HTTP
protobuf collector (for example, `http://127.0.0.1:4318/v1/traces`). An already-running Work
Host keeps its original configuration. Remote collectors require HTTPS; use a local collector
for authenticated forwarding rather than putting credentials in the endpoint URL.

Spans record bounded operational metadata and hashed identities, not prompts, code, thinking,
tool bodies, or raw errors. They are diagnostic and may be lost; canonical journals remain the
authority for delivery and recovery. Current coverage, known gaps, and verification are in the
[observability plan](plans/opentelemetry.md).

Diagnostics shows this app process's queue and export-result counters separately from agent-service
health. The exporter holds at most 1,024 queued/in-flight spans and drains against one bounded
deadline on ordinary exit. Collector failures never retry Work or prevent quitting. HTTP success
is not proof of backend retention, and abrupt termination can still lose traces.

### Building

The GUI requires macOS 15+ and a Swift 6 toolchain (Command Line Tools is enough — no Xcode).
The headless Work Host and selected Core/self-test surfaces also build on Linux.

```sh
just build          # build the app bundle → build/Aviary.app
just run            # build and launch
just test           # run the core test suite
just compile        # build the GUI and aviaryd
just shots          # render every screen to PNG, headless
```

Or without `just`:

```sh
cd app && swift build -c release --product Aviary
../scripts/bundle-app.sh release
open ../build/Aviary.app
```

The app bundle contains `aviaryd` and the runtime-host assets used for in-house Work. Development
builds resolve those assets only from the enclosing checkout; there is no home-directory fallback.

## Screenshots, headlessly

`just shots` boots the app against your real agent directory, renders every screen to a
PNG, and exits. It exists because a view that compiles, has correct data, and lays out to
an empty rectangle is a bug no unit test catches — and because producing that evidence
should not require a display server or screen-recording permission.

```sh
just shots                                  # all screens → build/shots/
just shot sessions                          # one screen
just shot cockpit --bare                    # without the navigation chrome
```

Two known limits of the capture path, neither affecting the running app:

- The **sidebar column renders white**, and so does any column the capture has not drawn
  before — the Sessions inspector comes out black. Both render correctly in the running
  app (verified by eye). An unpainted region in a snapshot is not evidence of a bug.
- Each screen is rendered **twice** and only the second pass is written. The window does not
  draw reliably until it has been through a couple of section transitions; no amount of
  settle time on a single view fixes it, and forcing a rebuild makes it worse.

## Tests

`app/Sources/AviarySelfTest` is an executable, not a `.testTarget`: a Command Line
Tools–only toolchain ships neither XCTest nor swift-testing, so `swift test` cannot run
here. `just test` runs it; non-zero exit on failure, usable from CI unchanged.

The suite pins the behaviours where a silent mistake is invisible — a dropped session
branch, a mispaired tool result, a record split on a Unicode line separator, the
missing-export credential trap — because all of those still render as a plausible screen.
