# Aviary

A native macOS app that runs coding agents, and reads every agent session on the machine.

It started as a GUI over the Prime Agent harness and now has its own agent: its own provider
clients, its own loop, its own Python runtime host, its own memory. No Node, no daemon, no
version conflicts. The vendored harness is still selectable, and nothing requires it.

Prime Agent is a genuinely good agent runtime: one IPython kernel as the only tool, a
hundred-odd provider routes, recursive sub-agents, compaction, a daemon that keeps sessions
alive after you close the terminal. All of it is driven through a TUI, which means the parts
that are *structural* — a fan-out of twelve sub-agents, where the tokens went, why a
provider 401s, which of four processes is wedged — are things you reconstruct by reading
scrollback.

Aviary is the view of that structure.

```
aviary/
├── app/         The macOS app: SwiftUI + a pure-Swift core. No dependencies.
├── harness/     Forked prime-agent. The execution engine.
├── scripts/     Bundling and the icon (drawn in Python, not checked in as a binary).
├── docs/        Architecture notes.
└── justfile     Every task worth naming.
```

## Running an agent

Aviary runs agents itself — no harness, no Node, no daemon:

```sh
just build
Aviary --agent "count the swift files under app/Sources" --model litellm/claude-haiku-4-5
```

Sign in to ChatGPT for the Codex models with `Aviary --codex-login` (add `--paste` if the
browser redirect cannot reach this machine). Credentials go in the same `auth.json` the harness
uses, so one login serves both.

Flags: `--cwd <path>`, `--host python3-shared` (for numpy/pandas), `--record` (capture request
payloads), `--budget <tokens>` and `--minutes <n>` (a goal the agent can see and plan against),
`--quiet`. A prompt starting with `/name` expands a prompt template. In the GUI, the Live tab's
launcher picks between the in-house engine, the vendored harness, and Claude Code driving.

What the agent gets: one tool, `python`, running in a persistent interpreter where variables
survive between calls. Inside it, `sh(command)` with a working directory and environment that
*persist* across calls, `spawn(prompt)` for sub-agents, `conversation(limit)` to read its own
history, and `remember`/`recall` for things worth keeping. Skills are ranked against the prompt
rather than all injected. MCP servers from `settings.json` appear as individual tools.

`just host` drives a runtime host by hand, which is the fastest way to explore one or to check a
new one against [docs/runtime-host-protocol.md](docs/runtime-host-protocol.md).

## Letting Claude Code drive

The third engine, and the one arrangement that is upside down on purpose:

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

Not hot reload in the code-injection sense; the process is replaced, not patched. What makes it
feel like a reload is that the build has already finished by the time you look, so the click is
immediate. The relaunch is a click rather than automatic for one specific reason: the session
that just finished your request is usually still attached and holding a live interpreter, and
relaunching ends it. Preferences → Workshop turns either half off.

## What it does

| Screen | What it answers |
|---|---|
| **Cockpit** | What is running, what just ran, what needs a decision. Credential and daemon problems appear here before they cost you a session. |
| **Live** | Start a run and steer it mid-flight. Runs Aviary owns are drivable; runs started in a terminal are observable — the UI never offers a control that would quietly do nothing. |
| **Sessions** | Read any transcript. Python cells next to their output, thinking collapsed, injected context folded away, tool errors flagged, per-message token and cost accounting. |
| **Flock** | The sub-agent tree: who spawned whom, with what instructions, on which model, and a timeline showing whether that fan-out actually ran in parallel. |
| **Models** | Every provider and model, and whether the credential will resolve — see below. |
| **Usage** | Tokens and cost across every session on disk, by model, provider, project, and day, plus cache-hit and tool-error rates. |
| **What was sent** | Optional per-run recording of every provider payload, decomposed: system prompt, each discovered context file, every skill description, tool schemas, messages — with each part's share of the input you were billed for. |
| **Library** | Skills, prompt templates, extensions, packages — and every directory that was searched, including the empty ones. |
| **Health** | Process topology, three cross-checked liveness signals, and one-click repair for the failure modes that don't self-heal. |

⌘K searches all of it at once.

## Two design decisions worth knowing

**The harness runs the agent; Aviary does everything else natively.** Session parsing, the
catalog, the sub-agent tree, daemon introspection, `models.json` editing, credential
resolution, cost analytics — all pure Swift reading the same files the harness writes. Live
runs go over the harness's documented RPC protocol (LF-delimited JSON over stdio), spawned
straight from the app. There is no bridge service, no port, and no second thing to keep
alive. A consequence worth having: **the whole app still works when the daemon is wedged**,
which is exactly when you want to look at what happened.

**Aviary hands the engine your login shell's environment.** A macOS app inherits launchd's
environment, not the one `.zshrc` builds. The harness resolves a bare environment-variable
name in `models.json` client-side, and when the variable is *absent* it does not error — it
sends the variable's own **name** as the credential. The provider answers 401 with a message
that reads like a typo in your config, and the same config works fine in Terminal. So at
startup Aviary snapshots `zsh -ilc env` once and uses that for every subprocess. The Models
screen resolves each key expression the same way the harness would and tells you which of
the three forms (`!command`, environment variable, literal) applied and what happened.

## Where did my input tokens go?

A two-message session can bill 17,000 input tokens, and nothing on disk explains it: the
transcript holds messages, while the system prompt, the discovered `AGENTS.md` files, the
skill catalogue and the tool schemas are assembled at request time and persisted nowhere.

Start a run with **Record what's sent to the model** and Aviary captures each provider
payload through the harness's `before_provider_request` hook, then breaks it apart:

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

Recording is off by default and per-run, because it writes your full system prompt and
conversation to a file. The same breakdown is available from a shell:

```sh
Aviary --analyse-wire ~/Library/Application\ Support/Aviary/wire/run-*.jsonl --input-tokens 17351
```

**Reasoning tokens.** Where a route returns thinking as text, Aviary shows each block's
size inline. Where it doesn't — the Codex route encrypts its reasoning — the fork preserves
`output_tokens_details.reasoning_tokens`, which upstream discards, so at least the count
survives. See `harness/FORK.md`.

## Build and run

Requires macOS 15+, a Swift 6 toolchain (Command Line Tools is enough — no Xcode), and
Node 22+ for the harness.

```sh
just build          # build the app bundle → build/Aviary.app
just run            # build and launch
just test           # run the core test suite
just build-engine   # npm install + build the forked harness
just shots          # render every screen to PNG, headless
```

Or without `just`:

```sh
cd app && swift build -c release --product Aviary
../scripts/bundle-app.sh release
open ../build/Aviary.app
```

Aviary finds an engine in this order: the bundled fork's built CLI, then any installed
`prime-agent` resolved through your login shell. Health shows what it found and lets you
switch.

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

## The fork

`harness/` is [PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent)
at `c75a637` (0.7.4-beta.531.1), vendored with its history dropped and no upstream remote.
It is a hard fork by intent: when Aviary needs the engine to expose something, the engine
changes. There is no compatibility obligation and no merge path back.

As of this commit the harness source is unmodified — everything Aviary needs so far, the
harness already offered. See `harness/FORK.md`.

## Tests

`app/Sources/AviarySelfTest` is an executable, not a `.testTarget`: a Command Line
Tools–only toolchain ships neither XCTest nor swift-testing, so `swift test` cannot run
here. `just test` runs it; non-zero exit on failure, usable from CI unchanged.

The suite pins the behaviours where a silent mistake is invisible — a dropped session
branch, a mispaired tool result, a record split on a Unicode line separator, the
missing-export credential trap — because all of those still render as a plausible screen.
