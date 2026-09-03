# Splitting Aviary into GUI, Work Host, and kernels

**Status:** implementation in progress. Stage 1's adoptable runtime transport and the
transport-neutral Work-service contract are implemented and tested as foundations; no production
path yet persists adoption descriptors or moves Work ownership out of the GUI. Stages 2–4 remain
unimplemented. Updated 2026-09-02.

The goals, stated as tests:

1. **Closing or relaunching the GUI without an explicit terminate command must not disturb work in
   progress.**
2. **A later session must be able to attach to ongoing or completed Work, including from a GUI on a
   different device once a secure remote transport is added.**
3. **GUI↔Work is many-to-many:** one GUI observes/controls local and remote Work across many hosts;
   one Work is observed/controlled by many GUIs without an exclusive controller lease.

Everything below is judged against those tests, and against the fact that this project's whole
point is changing Aviary often — which is what makes a long-lived service awkward, and which most
designs for this quietly assume away.

The architectural noun is **Work Host**, not “background GUI.” Work is owned by the host service;
sessions and GUIs attach to it. Local and remote use the same logical contract even when the first
transport is a Unix-domain socket.

## Where the three-way split is already true, and where it isn't

**Kernels are already separate processes.** `RuntimeHost` spawns
`/usr/bin/env python3 runtime-hosts/python3/host.py`, and one host holds many sessions
(`createSession` / `sessions` / `destroySession`), each with its own interpreter. So there is no
work to do in *separating* them. The work is making them **outlive and be re-attachable**, which
is a different and smaller problem.

The original blocker was the transport, not the process model: the runtime-host protocol used
line-delimited JSON on stdin and stdout, whose pipes were bound to the parent that created them.
Protocol v3 now carries the same bounded JSONL contract over an identity-checked Unix-domain
socket. This removes the keystone transport constraint, but production discovery and adoption
still require Stage 2 to persist the descriptor under service-owned Work.

**"The part of the harness that owns sessions" is not the right description of #2.** On the
in-house engine there is no harness — the loop is Aviary's own `Agent` + `AgentRunner`, running
in-process inside the UI. So this is not extracting something from the harness; it is moving
Aviary's own loop out of the app. Worth being precise about, because it means there is no
existing component to lift, and also no existing protocol to reuse.

**The same-host read path is already solved, and this remains useful.** `InHouseDriver` does not render
from memory — it tails the session JSONL and re-parses it (`SessionWatcher` + `SessionParser`).
The transcript is an append-only event log with a single writer. This means a local UI does not
need an ephemeral push bus: it can always reconstruct from a durable cursor.

It does **not** mean the product should expose filesystem tailing as the GUI/service contract. A GUI
on another device cannot open the host's file, and an attachment from another session should not
copy the log. The Work Host therefore needs a small durable read surface—describe/snapshot,
events-after-cursor, and fetch-artifact—alongside commands. Same-host file reading may remain an
optimization behind the same `WorkServiceClient` interface. The canonical journal, rather than a
live stream, still pays most of the event-plumbing cost.

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

## Recommendation: five stages, and stage 1 buys most of the benefit

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

This substrate now proves:

- A fresh `RuntimeHost` client can adopt the same verified host instance after the original client
  disconnects. **Variables survive in the tested interpreter.** No GUI path performs this yet.
- Callback requests keep a stable request ID across at-least-once replay. Late/duplicate results
  are rejected explicitly; durable effect deduplication belongs to the service-owned Work action
  boundary in Stage 2.
- It is needed for **every** later stage: if kernels are children of a service, a service
  restart kills them, and this project restarts services.

Filesystem permissions rather than a token, unlike `KernelBridge`: that one uses loopback TCP
with a token because the courier's endpoint is passed in `--mcp-config` and argv is visible in
`ps`. A Unix socket in a 0700 directory has no port to collide and no secret to leak.

The old stdio protocol was replaced rather than retained as a compatibility mode. Aviary-owned
development state and interfaces are disposable; the v3 socket contract, its safety tests, and its
adoption descriptor are the only runtime-host path going forward.

### Stage 2 — `aviaryd` becomes the local Work Host; the GUI becomes a client

A `launchd` **user agent** (`~/Library/LaunchAgents/works.duckbill.aviaryd.plist`, `RunAtLoad`,
`KeepAlive`, `ThrottleInterval`) rather than a hand-rolled supervisor. launchd already does
restart, throttling, logging, and — the part that matters — it owns the process, so nothing the
UI does can take it down.

**Give it as little as possible.** Everything in the service is something you cannot hot-reload,
so the boundary should be drawn to keep the reloadable side fat:

| In the service | Stays in the UI |
|---|---|
| The agent loop (`Agent`, `AgentRunner`) | Rendering, every view |
| Kernel connections, and the MCP bridge for driven runs | Session/Work catalogue cache and projections |
| The `claude -p` child, and its lifecycle | Usage analytics, the model catalogue |
| Authoritative Work registry, client/session attachments, command actors/cursors | Multi-host inbox grouping and presentation state |
| Work/session journals — one host-side writer per journal | Skill/memory *presentation*; the Workshop board |
| Scheduled jobs (which today only tick while a window is open) | The reloader, which now only relaunches the GUI |

Transport: Unix socket first, with a transport-neutral protocol for `list`, `describe`, `attach`,
`detach`, per-client observe/control capability, `snapshot`, `events-after-cursor`, `fetch-artifact`,
`start`, `prompt`, `steer`, and explicit scoped stop/destroy commands. Many clients may control one
Work; the host serializes accepted commands with client/session provenance and causal cursors rather
than assigning one controller lease. Client/service boundaries use an unambiguous
`WorkRef = {work_host_id, work_id}` rather than letting a local catalogue or bare Work ID silently
choose a host. Reads remain journal-backed, not an ephemeral event channel.
Aim for a protocol small enough to fit on one page, because every field in it is a two-sided
deployment.

### Stage 3 — the GUI becomes disposable

Which is where you started. Once no work lives in the UI process, the existing reload feature
stops needing to stop runs before relaunching, `reloadCost` becomes empty, and auto-relaunch
becomes a safe default rather than the off-by-default compromise it is now.

### Stage 4 — enable a remote GUI without changing ownership semantics

Add an authenticated encrypted transport (or SSH-tunneled transport) and Work Host discovery/manual
connection over the same logical protocol. Work IDs are identities, not bearer credentials;
authorization is checked separately. Model/repository credentials and the unrestricted Python
runtime remain on the Work Host. Client clocks, filesystem paths, PIDs, and network connection
liveness never define ordering, control ownership, or lifetime.

The conformance test is stronger than “the socket connects”: two controlling clients with
independent cursors attach to the same Work and issue concurrent commands; the host records one
deterministic accepted order and explicit stale/conflict outcomes. One client loses its connection;
Work and the other client's capabilities continue; reconnect duplicates neither commands nor
effects. Separately, one GUI aggregates local and remote Work across multiple hosts while one host is
slow/unavailable. A new session can later attach to completed Work after the originating
conversation is archived.

## The thing that will actually bite: version skew

The service is the part that does not reload. An agent that edits Aviary hourly will routinely
leave a UI built from commit N talking to a service from commit N−3.

Design for it rather than against it:

1. **Version-stamp the handshake** with the same string the build already prints.
2. **Skew + no live sessions → the service replaces itself, silently.** No banner, no decision.
   This is the common case and it should be invisible.
3. **Skew + live Work → say so plainly** and let it finish on the old build: *"the Work Host is
   running an older build; three Work items will finish on it."* Never migrate live
   Work across a version boundary.
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
