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
