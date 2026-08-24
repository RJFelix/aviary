# Splitting Aviary into UI, session service, and kernels

**Status:** shaping. Nothing implemented. 2026-08-24.

The goal, stated as a test: **relaunching the UI must not disturb work in progress.** Everything
below is judged against that, and against the fact that this project's whole point is changing
Aviary often — which is what makes a long-lived service awkward, and which most designs for this
quietly assume away.

## Where the three-way split is already true, and where it isn't

**Kernels are already separate processes.** `RuntimeHost` spawns
`/usr/bin/env python3 runtime-hosts/python3/host.py`, and one host holds many sessions
(`createSession` / `sessions` / `destroySession`), each with its own interpreter. So there is no
work to do in *separating* them. The work is making them **outlive and be re-attachable**, which
is a different and smaller problem.

The blocker is the transport, not the process model: the runtime-host protocol is
**line-delimited JSON on stdin and stdout** (`docs/runtime-host-protocol.md`). Pipes are bound
to the parent that created them. A kernel on stdio cannot be adopted by a new process, no matter
who spawned it. **This is the keystone constraint for the entire plan.**

**"The part of the harness that owns sessions" is not the right description of #2.** On the
in-house engine there is no harness — the loop is Aviary's own `Agent` + `AgentRunner`, running
in-process inside the UI. So this is not extracting something from the harness; it is moving
Aviary's own loop out of the app. Worth being precise about, because it means there is no
existing component to lift, and also no existing protocol to reuse.

**The read path is already solved, and this is the good news.** `InHouseDriver` does not render
from memory — it tails the session JSONL and re-parses it (`SessionWatcher` + `SessionParser`).
The transcript is an append-only event log with a single writer. That means the UI needs **no
IPC at all for reading**: no event stream to design, no replay-on-reconnect, no lost events if
the UI dies mid-turn. A service needs only a small *command* surface. Most of the cost people
associate with this kind of split is the event plumbing, and it is already paid.

## The prior art is in this repo, and so is the scar tissue

The harness daemon **is** this architecture: a supervisor socket, per-session workers, ownership
leases. We have spent this month retiring its surfaces from the UI. Before rebuilding it,
inherit its failure modes deliberately:

- **A wedged daemon still answers `doctor`.** It completes the handshake and reports
  `status: current` while refusing every real command. `DaemonInspector` cross-checks with a
  `list` call for exactly this reason. Any health check that only proves the socket answers is
  worthless.
- **Ownership leases get poisoned** and only `shutdown --force` clears them. Whatever guards
  "one owner per session" needs a recovery path that does not require understanding it.
- **Version mismatch is a real, user-visible state** — the cockpit has a banner for it.

That third one is the important one here, and it is worse for us than for the harness, because
the harness is not being edited hourly by an agent. **In this project, the service will be
version-skewed against the UI constantly.** Any design that assumes "the service is long-lived
and rarely restarts" is assuming away the actual working conditions.

## Recommendation: four stages, and stage 1 buys most of the benefit

### Stage 0 — stop leaking (mostly done)

Two `host.py` processes orphaned since 21 Aug were found on this machine, and a `claude -p`
alive thirteen minutes after its app had exited. `ClaudeCodeRun.stop()` now escalates to
SIGKILL, and the in-house path is suspected of the same leak. Nothing further is safe to build
on top of a process model that loses track of its own children.

### Stage 1 — adoptable kernels (the keystone)

Runtime-host protocol **v3: the same JSON, over a Unix domain socket** instead of stdio. The
host listens on `~/Library/Application Support/Aviary/kernels/<id>.sock` in a 0700 directory,
and is started detached (`launchd`, or `posix_spawn` with a new session so it is not in the
app's process group).

Then:

- A UI relaunch reconnects to the same kernel and the same interpreter. **Variables survive.**
- Combined with `SessionResume.replay`, which already exists and already handles a transcript
  that ends mid-tool-call, a relaunch costs the turn that was in flight and nothing else.
- It is needed for **every** later stage: if kernels are children of a service, a service
  restart kills them, and this project restarts services.

Filesystem permissions rather than a token, unlike `KernelBridge`: that one uses loopback TCP
with a token because the courier's endpoint is passed in `--mcp-config` and argv is visible in
`ps`. A Unix socket in a 0700 directory has no port to collide and no secret to leak.

Cost: a protocol revision with a documented spec, plus a compatibility window where hosts speak
both. Small, self-contained, independently valuable.

### Stage 2 — `aviaryd`, and the UI becomes a client

A `launchd` **user agent** (`~/Library/LaunchAgents/works.duckbill.aviaryd.plist`, `RunAtLoad`,
`KeepAlive`, `ThrottleInterval`) rather than a hand-rolled supervisor. launchd already does
restart, throttling, logging, and — the part that matters — it owns the process, so nothing the
UI does can take it down.

**Give it as little as possible.** Everything in the service is something you cannot hot-reload,
so the boundary should be drawn to keep the reloadable side fat:

| In the service | Stays in the UI |
|---|---|
| The agent loop (`Agent`, `AgentRunner`) | Rendering, every view |
| Kernel connections, and the MCP bridge for driven runs | The session catalogue and its cache |
| The `claude -p` child, and its lifecycle | Usage analytics, the model catalogue |
| `SessionWriter` — the single writer | Skill/memory *presentation*; the Workshop board |
| Scheduled jobs (which today only tick while a window is open) | The reloader, which now only relaunches the UI |

Transport: Unix socket, LF-delimited JSON, **commands only** — `start`, `prompt`, `steer`,
`stop`, `list`, `attach`. Reads keep going through the transcript. Aim for a protocol small
enough to fit on one page, because every field in it is a two-sided deployment.

### Stage 3 — the UI becomes disposable

Which is where you started. Once no work lives in the UI process, the existing reload feature
stops needing to stop runs before relaunching, `reloadCost` becomes empty, and auto-relaunch
becomes a safe default rather than the off-by-default compromise it is now.

## The thing that will actually bite: version skew

The service is the part that does not reload. An agent that edits Aviary hourly will routinely
leave a UI built from commit N talking to a service from commit N−3.

Design for it rather than against it:

1. **Version-stamp the handshake** with the same string the build already prints.
2. **Skew + no live sessions → the service replaces itself, silently.** No banner, no decision.
   This is the common case and it should be invisible.
3. **Skew + live sessions → say so plainly** and let them finish on the old build: *"the session
   service is running an older build; three sessions will finish on it."* Never migrate a live
   session across a version boundary.
4. **Keep the protocol tiny**, so most changes do not touch it at all. If a change adds a field
   to the command surface, that is a signal it might belong in the UI instead.

## The alternative worth naming

For **UI-only** changes — which you expect to be the majority — there is a much smaller answer:
true hot reload. `-Xlinker -interposable` plus an injection package swaps view code into the
running process with no restart and no architecture change. No Xcode needed; it is a SwiftPM
dependency.

I would not build the process split *instead* of this, or this instead of the split. They solve
different halves: injection handles "I changed a view" in under a second, and the split handles
"work should survive, and should continue with no window open". If only one gets built, the
split is the one with compounding value — scheduled jobs that actually fire, and a workshop
agent that keeps working while Aviary is closed, are both features rather than conveniences.
