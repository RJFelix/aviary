# Handles: a third sort, owned by Aviary

*Shaping doc, 2026-08-26. Not yet built. Decisions marked **D**, open questions **Q**.*

## Where this came from

The Futures work raised a question four features share: **who owns dispatched work?** Today
the agent does — background children are cancelled when their starter's run tears down — and
that makes cross-agent awaiting, survival across resume, and meaningful cancellation impossible
rather than merely unbuilt.

**D1. Aviary owns dispatched work.** Agents get an interface to *request* actions on it, which
Aviary can usually be expected to honour. Full agent ownership cuts off too much.

## Remote-first ownership clarification, 2026-08-31

The owner named by D1 is a durable **Work Host**, not the GUI process and not the originating
conversation.

- **D13. GUI detachment carries no termination intent.** Window close, GUI quit/relaunch, network
  loss, and device sleep only detach that client. Work continues according to its host-side scope
  and resource policy until an explicit durable terminate request or policy deadline.
- **D14. Sessions attach to Work; they do not consume it.** Many sessions may observe ongoing or
  completed Work, and many GUIs may control it concurrently. The Work Host serializes accepted
  commands with client/session provenance and explicit conflict/stale outcomes; it does not assign
  one exclusive controller lease. Connection liveness is not ownership. Completed results are
  immutable, write-once values; continuation makes linked new Work rather than rewriting them.
- **D15. Local and remote are one logical model.** A Future remains a local view over a Handle, but
  the Handle resolves at its Work Host. GUI, agent, and session attachment may be on another device.
  One GUI may attach to Work across many local/remote hosts, and each Work may have many attached
  GUIs. The first transport can be a Unix-domain socket as long as identity, commands, cursors, and
  event ordering contain no local path, PID, client clock, or GUI-lifetime assumption.
- **D16. Identity is not remote authority.** A Handle/Work ID names the object and preserves
  provenance; a remote Work Host separately authenticates and authorizes the attaching client.
  This endpoint boundary does not sandbox the trusted Python agent running on that host.

## The sorts

We had two. Ownership introduces a third.

| Sort | Lives in | Lifetime | Cost of a value | Crosses agents? |
|---|---|---|---|---|
| **Value** | one interpreter | the session's namespace | free | no — objects cannot cross sub-interpreters |
| **Message** | a conversation | permanent, re-sent as context | a model call | only as text |
| **Handle** | Aviary Work Host | durable, reaped by policy | a lookup | **yes** — this is the shared sort |

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

Under D16, “capability” describes authority *inside an already authenticated Work Host trust
domain*. An unguessable ID is not a remote login credential. The host first authorizes the client;
possession of a Handle then narrows which Work that client may resolve. No global enumeration still
holds.

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
  matters is the one on the Work's artifacts, so reuse that.

**D4. Reaping is recorded, not silent** (see H5), and **visible** — see below.

**Q2, split by D13.** A Handle and its Work **must** survive GUI restart/disconnection because the
GUI is only a client. Work Host restart is the real recovery question: terminal results persist;
running Work reconnects to host-owned processes where possible and otherwise receives an explicit
indeterminate/canceled outcome. A missing client is never evidence that the process is gone.

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

- `HandleStore` in `AviaryCore`, owned by the Work Host rather than by the GUI or `AgentRunner`,
  persisted beside Work journals/artifacts.
- `AgentRunner.startBackgroundChild` registers a handle instead of writing to a private dict.
- The prelude's watcher polls `handle(id)` rather than `children()`; `children()` becomes a
  filter over handles by origin.
- Teardown stops cancelling and starts *handing off*. Reaping becomes policy, not a side effect
  of a window closing.

**Q3.** `ask()` — the missing primitive for the minion pattern — needs a bounded pool, since
500 chunks is currently 500 threads and 500 concurrent requests. The bound has to be ours
because the agent cannot know the endpoint's concurrency. Is the pool per-provider, or global?

## Answers, 2026-08-26

**Q1 — no revocation.** Agreed. Two reasons, and the second generalises: untrusted agents would
need a wholly different set of primitives, so *mutual trust is a stated precondition of this
design, not an oversight*. And revocation-as-signal ("I revoke your handle, which means X") is
overloading absence to carry meaning — if you want to signal, signal. **D6. Do not encode
intent in the withdrawal of a capability.**

**Q2 — lifetime belongs to a scope, not to a handle.** The eventual model is a tree of
namespaces with their own scope and duration, with handle lifetimes attached to their
namespace's lifecycle. That is better than D3's per-handle clocks: it is region-based rather
than object-based, so a fan-out can be given a child scope and discarded wholesale. D3 survives
as the degenerate case — scope = Work — which keeps it forward-compatible without making a
conversation attachment the lifetime owner. Larger design, deliberately deferred.

**Q3 — globally managed.** `ask()` is a request Aviary *may* fulfil; when, whether, and in what
order is the runtime's to decide. There is a global ceiling because of physics, but how it is
allocated across sessions and workstreams is policy — priority, fair share, or first-come —
and it is the driver's to set. This is the same law as H4 appearing a second time: **the agent
proposes, Aviary disposes.**

Two consequences:

- **D7. `queued` is a distinct state from `running`.** A Future can be outstanding without
  having started, so latency is no longer a property of the work alone.
- **D8. Priority is inferred from the elimination form, not declared.** Awaited work is
  blocking a cell; dispatched work said it could wait. `.result()` versus `.notify()` is a
  scheduling signal at zero API cost, and an honest one — the agent revealed the preference by
  acting on it rather than asserting it.

**Q4 — a dying run does not kill its work.** It may schedule it for reaping, but survival must
not be forbidden: runs die for many reasons, resuming them is normal, and work that completes
during the dead period is work saved rather than lost. The distinction is **stopping versus
destroying** — a run or session attachment may stop freely; Work is destroyed only by an explicit
authorized request or well-understood host-side lifetime policy.

**D9, revised by D13–D16. Death and detachment are different events:**

| Event | running Work | handles/results |
|---|---|---|
| Run stops | follows Work scope; not implicitly killed | live |
| GUI exits or network disconnects | unaffected | live and attachable |
| Work Host exits | recover/reconnect where possible; otherwise explicit indeterminate/canceled outcome | terminal results persist |
| Originating session archived/destroyed | unaffected unless an explicit Work lifetime policy says otherwise | live and attachable from other authorized sessions |
| Work explicitly destroyed or expires | canceled deliberately | reaped, with a timestamp |

Work Host death is the remaining involuntary seam. It needs a durable outcome and recovery policy;
it must never be inferred from a missing GUI connection.

## Q5 resolved — one clock, derived

Three options, and the framing turned out to be the defect.

**A — the ceiling excludes queue time.** Guarantees delivery: anything that runs, reports. But
the hold becomes unbounded in wall-clock, so a saturated scheduler can hold a run for an hour
of queue plus its execution ceiling, keeping an interpreter and a runtime session alive
throughout. That is exactly the property the ceiling existed to protect.

**B — the hold distinguishes the states.** B1 (do not hold for queued work) reintroduces the
silent loss. B2 (a second, longer ceiling) creates two timeouts that must agree, which is how
the defect got in. B3 (hold, and *cancel* if the ceiling expires while still queued) is the
good one: the failure becomes an explicit cancellation — "no capacity, cancelled, not lost" —
and it costs nothing, because work that never started has nothing to lose.

**The real defect is two independent clocks on one event.** The hold has its own ceiling and
handles will have their own lifetimes from their scopes; any disagreement is a silent loss, and
B2 makes that structural.

**D10. The hold has no clock of its own.** Every handle takes a deadline from its scope, and the
scheduler is obliged to bring every handle to a terminal state — done, failed or cancelled —
within it. The run holds while it has any non-terminal handle it is waiting on, and that is
guaranteed to end because terminalisation is guaranteed. One clock, derived rather than
duplicated.

The honest cost: run liveness now depends on a scheduler invariant actually holding. So keep a
backstop — but as an **assertion**, generous and loudly logged as "the scheduler failed to
terminalise", never as a routine timeout. A routine timeout hides that bug forever; an
assertion surfaces it the first time.

## Q6 resolved — automatic, and it needs a new arrow

**D11. Re-attachment is automatic, and transfer should look like passing a reference.**

Every crossing so far has been Value → Message: `notify` and `message` turn a value into text.
Handing over a handle cannot be that, or the receiver gets text and still has to `attach`. To
look like reference-passing, delivery must land in **both sorts at once** — text into the
conversation *and* a binding into the receiving namespace. That is a Value → (Message × Value)
arrow, and it is the first of its kind here. It is also the first time Aviary writes into an
agent's namespace from outside, which is a real change in what a namespace is; deliberate under
the scope model, a violation without it.

**D12. Labels are the durable names.** Handles survive a run; variable names do not, because
they lived in the interpreter that died. So `spawn(..., name='researcher')` rebinds as
`researcher` on resume, and unlabelled work returns keyed by id — honest about having had no
name to preserve. `name=` earns a second purpose beyond display, and the agent gains a reason
to name things, which helps every surface that lists this work.

## Timelines, not namespaces

The scope model wants a better noun. A **namespace** is a set of bindings at a moment; a
**timeline** is a sequence of events from which the bindings at any moment are derivable.
Lifecycle becomes the central feature rather than an attribute, scopes become intervals,
handles become entries, and forking is copying a prefix.

**The timeline already exists.** It is the transcript: append-only JSONL, ordered, durable,
already a *tree* via `parentId`. So this is not "add a timeline" — it is "promote the one you
have to primary and make the namespace derived".

**The obstacle is named in `docs/expansion.html`, with measurements.** The Python namespace is
not a fold over the transcript; it is a side effect of executing it. That doc puts it exactly:
*"the message tree forks and the image cannot"* — and measures the afterlife at **105 artifact
directories, 58 MB of dill, median 16 saved names, max 185, zero garbage collection**. Its
"Checkpoint rail" entry proposes giving the image the branching the transcript already has, and
names the hard part: *"an old image under a new transcript must move together or declare the
mismatch out loud."*

**But the algebra we have just built supplies the seam.** The impure operations are exactly the
ones that go through callbacks — `sh`, `spawn`, `search`, `read_url`, `ask` — and their results
are already recorded in the transcript. So replay need not re-execute them:

> **Replay the code; serve recorded results for the callbacks.**

That is record/replay, with the callback boundary as the impurity boundary. It makes replay
faithful without dill, makes forking a prefix copy, and makes transferring a session between
devices a matter of shipping the JSONL. The namespace stops being a 58 MB artifact to move and
becomes a cache to rebuild.

**Q7.** What escapes the seam? `time`, `random`, threads, and any socket the agent opens
directly rather than through `sh`. Faithful replay would need those pinned or declared
non-deterministic. How much does that matter in practice, given the agent is told to work
through the builtins?

**Q8.** The same doc counted forks in 80 real sessions: *"Median one real leaf, zero forks."*
Nobody branched. That is a real argument against building for branching — tempered by the fact
that forking was awkward in the harness, and availability shapes use. Worth re-counting on
Aviary's own sessions before investing.

## Still open

- **Q5.** The hold versus the queue. A run is held open while dispatched work is outstanding,
  bounded by a timeout. With D7, work can be outstanding *and not started*, so a scheduler
  under load could let the hold expire on work that never ran — silently converting "tell me
  later" into "never told". Either the ceiling excludes queue time, or the hold needs to
  distinguish the two states.
- **Q6.** Resuming a run that stopped while its work continued: does it re-attach automatically,
  or does the agent have to be handed its own handles back? Automatic is friendlier; explicit
  is honest about the fact that the namespace holding the Futures is gone.

## Original questions (all answered above)

Q1 revocation · Q2 restart survival · Q3 `ask()` pool · Q4 attach to work whose run died.
