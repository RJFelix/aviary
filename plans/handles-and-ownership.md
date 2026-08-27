# Handles: a third sort, owned by Aviary

*Shaping doc, 2026-08-26. Not yet built. Decisions marked **D**, open questions **Q**.*

## Where this came from

The Futures work raised a question four features share: **who owns dispatched work?** Today
the agent does — background children are cancelled when their starter's run tears down — and
that makes cross-agent awaiting, survival across resume, and meaningful cancellation impossible
rather than merely unbuilt.

**D1. Aviary owns dispatched work.** Agents get an interface to *request* actions on it, which
Aviary can usually be expected to honour. Full agent ownership cuts off too much.

## The sorts

We had two. Ownership introduces a third.

| Sort | Lives in | Lifetime | Cost of a value | Crosses agents? |
|---|---|---|---|---|
| **Value** | one interpreter | the session's namespace | free | no — objects cannot cross sub-interpreters |
| **Message** | a conversation | permanent, re-sent as context | a model call | only as text |
| **Handle** | Aviary | durable, reaped by policy | a lookup | **yes** — this is the shared sort |

A `Future` is a *local view* over a `Handle`. That is already how `spawn` works internally: the
child id is the handle, the Future polls it. Generalising it is mostly renaming.

## The shape

```
Handle = {
  id        : String              -- global, serialisable, the whole capability
  kind      : shell | agent | ask | search
  origin    : { session, label, created_at }
  request   : Text                -- the command, prompt or query, bounded
  state     : running | done | failed | cancelled | reaped
  value     : Option<Text>        -- write-once
  usage     : Option<Usage>       -- tokens and cost, for the kinds that spend
  lifetime  : { cancel_after, keep_result_until }
}
```

`request` is retained deliberately, bounded. It is what lets an agent that was *handed* a
handle re-run one case to check it, rather than trusting an aggregate it did not compute. See
"provenance" below.

## Laws

- **H1 — write-once.** Once `state` leaves `running`, `value` never changes. Reads are
  idempotent and unlimited. This is an IVar, not a channel, and that choice is load-bearing:
  it makes sharing free and passing a *copy* rather than a move, so there is no linear
  obligation to track who consumed what.
- **H2 — identity outlives its creator.** A handle stays resolvable after the run that made it
  ends, until reaped.
- **H3 — attach is a view.** `attach(id).result()` equals the value, for any agent, any number
  of times.
- **H4 — requests may be refused.** Agent-facing verbs return an outcome that can say no, and
  why.
- **H5 — reaped is not unknown.** Resolving a reaped handle reports *when it was reaped*, never
  "no such id". A stale handle must not look like a typo.

L5 from the Futures discussion still holds across all of this: `.result()` never costs a model
call; `.notify()` costs at most one.

## Handles are capabilities, not a directory

**D2. No global enumeration.** You hold a handle because you created the work or because
somebody passed you the id. There is no `all_handles()`.

This keeps the API at two new verbs, and it dissolves a family of scope questions — who may see
whose work, whether a handle leaks the existence of a run — into "you were told, or you were
not". `children()` stays, because your own children are not a directory of everyone's.

Passing work between agents therefore needs nothing new: `message(peer, f"... handle {h.id}")`,
and the receiver calls `attach`. Delegation *is* passing the string.

**Q1.** Should a handle be revocable — can the passer stop the receiver reading it later? Only
matters if we ever have agents that do not trust each other. Probably not now.

## The request interface

```
attach(id)  -> Future           # error names unknown vs reaped vs refused
cancel(id)  -> { ok, state, reason }
```

Both earn their place under the rule *add only what stdlib-plus-handles cannot express*: the
stdlib cannot resolve a foreign identity, and it cannot ask another process to stop.

Cancellation is genuinely a request, and the reason is per-kind:

| kind | what cancel can do | immediate? |
|---|---|---|
| `shell` | kill the process group | yes |
| `ask` | abort the HTTP request | yes |
| `search` | abort the HTTP request | yes |
| `agent` | stop the loop at its next turn boundary | **no** — an in-flight provider call cannot be interrupted without producing a conversation the provider rejects |

So the most expensive kind is the one that cannot stop instantly. That is the concrete
justification for `H4`: a signature returning `()` would be lying about the case that matters.

## Lifetime, or we have built an orphanage

This repo has form. The Flock view existed because the harness leaked sub-agent sessions, and
two orphaned `host.py` processes from 2026-08-21 were reaped during the session that removed
it. Owning work means owing it a lifetime.

**D3. Two clocks, because running work and finished results have different costs.**

- *Running* work has a `cancel_after`. Aviary cancels past it. Generalises the dispatched-work
  timeout that already exists (900s), and should be per-kind: a shell build and a sub-agent
  fan-out do not deserve the same ceiling.
- *Finished* results have a `keep_result_until`. They are small text; the retention that
  matters is the one on the session's artifacts, so reuse that.

**D4. Reaping is recorded, not silent** (see H5), and **visible** — see below.

**Q2.** Does a handle survive Aviary restarting? H2 says it outlives its *run*; surviving a
process restart means persisting the store to disk. Cheap for finished results, meaningless
for running work (the process is gone). Suggests: persist results, mark running work
`cancelled: aviary exited` on load.

## What this gives Flock back

Flock is currently hidden because it drew the harness's world — a forest of sessions held by a
supervisor. Aviary-owned dispatched work is a world with the same shape and a real referent:
work spanning runs, outliving the agent that started it, requestable but not commandable, with
a lifetime and a reaping policy worth watching. That is a screen worth drawing, and it is the
natural home for **D4**'s visibility requirement.

## Provenance

Not a primitive of the Future algebra — inside a cell a tuple does it, and by our own rule that
disqualifies it. But across an agent boundary it is unreconstructable locally, because the
thing that knew is in another interpreter.

**D5. Provenance is fields on the Handle** (`origin`, `request`, `usage`), not an operator on
Futures. It costs no description tokens, and it is metadata Aviary must keep anyway to own the
work at all.

Provenance is not attestation. The minion pattern's weakness is silent distributed error — a
weak model mapped over 500 chunks produces confident nonsense, and the reduce step sees only
the nonsense. Retaining `request` is what lets a frontier agent re-run a sample instead of
trusting an aggregate it did not compute.

## Implementation sketch

Contained, mostly renaming:

- `HandleStore` in `AviaryCore`, owned by the app rather than by `AgentRunner`, persisted
  beside session artifacts.
- `AgentRunner.startBackgroundChild` registers a handle instead of writing to a private dict.
- The prelude's watcher polls `handle(id)` rather than `children()`; `children()` becomes a
  filter over handles by origin.
- Teardown stops cancelling and starts *handing off*. Reaping becomes policy, not a side effect
  of a window closing.

**Q3.** `ask()` — the missing primitive for the minion pattern — needs a bounded pool, since
500 chunks is currently 500 threads and 500 concurrent requests. The bound has to be ours
because the agent cannot know the endpoint's concurrency. Is the pool per-provider, or global?

## Open questions, collected

- **Q1** Revocable handles — needed only for mutually distrusting agents. Probably not now.
- **Q2** Survival across an Aviary restart: persist finished results, mark running work
  cancelled on load?
- **Q3** `ask()` pool: per-provider or global?
- **Q4** Should `attach` to *running* work owned by a dead run succeed? Under D1 Aviary owns
  it, so the run dying need not kill it — but then a fan-out survives the window that started
  it, which is either the feature or the orphanage depending on `cancel_after`.
