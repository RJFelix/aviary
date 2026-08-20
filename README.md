# Aviary

A native macOS app for working with the Prime Agent harness — and a hard fork of the
harness itself, to evolve as needed.

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

## What it does

| Screen | What it answers |
|---|---|
| **Cockpit** | What is running, what just ran, what needs a decision. Credential and daemon problems appear here before they cost you a session. |
| **Live** | Start a run and steer it mid-flight. Runs Aviary owns are drivable; runs started in a terminal are observable — the UI never offers a control that would quietly do nothing. |
| **Sessions** | Read any transcript. Python cells next to their output, thinking collapsed, injected context folded away, tool errors flagged, per-message token and cost accounting. |
| **Flock** | The sub-agent tree: who spawned whom, with what instructions, on which model, and a timeline showing whether that fan-out actually ran in parallel. |
| **Models** | Every provider and model, and whether the credential will resolve — see below. |
| **Usage** | Tokens and cost across every session on disk, by model, provider, project, and day, plus cache-hit and tool-error rates. |
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

- The **sidebar column renders white**. `NavigationSplitView`'s sidebar background is an
  AppKit vibrancy material, and materials do not rasterize through `cacheDisplay`.
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
