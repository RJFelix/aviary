# Phase 5 approval brief: host-owned agent children

Status: approved for implementation by Ryan, 2026-09-10. Private Hosted/Python integration
is being verified; public service control and production activation remain incomplete.

The chat-first work has now exercised real Start, queued input, Stop after step, End,
GUI-only relaunch, retained drafts, and saved-review feedback. This supplies useful evidence
for the explicit Phase 5 design gate in `core-experience.md`; it does not complete every item
in Phases 1–4 or authorize checkpoint/restore writes.

## Keep the decisions already made

The Work Host owns ongoing work, not a GUI or conversation. Attachment is many-to-many;
disconnecting a GUI does not terminate work. Remote authorization is separate from identity,
and Python remains a trusted, full-capability runtime. None of these need reopening.

## The remaining gap

`AgentRunner` still owns spawned children in process-local maps/tasks and cancels them during
runner teardown. Existing Handle outcomes require the active originating Run. Durable child
status in the timeline is therefore not yet a durable, independently owned execution object.
Moving this ownership is not merely renaming the existing Future or adding a Flock card.

## Recommended first pilot

- Support **agent children only**, created through `spawn`. Defer shell, search, ask, nested
  scope trees, and a general scheduler.
- Give each child a **Work-owned lifetime**. Parent Run End, conversation archive, or GUI
  disconnect does not implicitly cancel it. Explicit Work destruction or scope expiry does.
- Require an **explicit scope deadline** in the pilot configuration, covering queue and
  execution together. Do not silently choose a product-wide expiration or add a second
  independent hold timeout. Select user-facing defaults after exercising this pilot.
- Persist queued, started, terminal, and reaped states with immutable origin Run/Session
  references, bounded labels, and addressable request/result bodies. A terminal result is
  write-once and may be recorded after the originating Run ends. Retain results with their
  Work until explicit destruction/retention policy; retained tombstones distinguish reaped
  objects from unknown IDs.
- An authenticated, authorized Work observer holding the Handle ID can read it. Cancellation
  additionally requires Work control authority and a durable, client-qualified command.
  Do not introduce an exclusive controller or automatic mutation replay.
- Use one bounded host-side agent queue with fair admission across Works. Preserve an explicit
  await-interest signal for `.result()` without starving non-awaited work. Publish the capacity
  and fairness rule before implementation; this is not permission to build a universal scheduler.
- Results are readable from another authorized Session. Automatic namespace rebinding applies
  only to explicitly transferred/originated bindings, never every attached conversation. Preserve
  durable labels; a collision is visible and does not overwrite an existing Python value.
- Across Work Host restart, prove lookup of already-terminal results. In-flight work is explicitly
  indeterminate/canceled unless execution recovery is independently proven. No claim of resumed
  provider calls, reconstructed Python state, or duplicated-effect safety from history alone.

## Required proof before broader rollout

One non-awaited child survives parent Run End and GUI disconnect, settles on the same host,
and is read from a second Session without consuming or rewriting the result. Two clients racing
cancel produce one serialized outcome. Queued expiry, running expiry, label collision, missing
body, and host loss remain visible. Work completion refuses outstanding policy-relevant children.
Cold/live reducers agree on post-Run completion and original provenance. Terminal lookup survives
host restart without implying that in-flight work resumed.

Keep the current bounded chat activity UI; do not bundle a Flock redesign or write-capable
checkpoint/restore interface into this pilot.

## Pilot admission policy

Initial limits are conservative testable policy, not measured optimal capacity: two executing
children per Work Host, at most one executing child per Work, eight queued children per Work,
and 32 queued children across the host. Admission refuses explicitly when a limit is reached.
The queue selects eligible Works round-robin. Within a Work it normally selects FIFO; explicit
await interest may promote a queued child, but at most one promoted child may pass the oldest
non-awaited child before that oldest child gets the next eligible slot. An await cannot preempt
running execution. Deadline expiry applies from original admission, including all queue time.

Retained terminal results are not automatically reaped to make room: initially a Work may retain
256 agent Handle identities, including reap tombstones. Further admission refuses at that bound.
Reaping drops explicitly selected bodies/resources and preserves terminal identity, not permission
to reuse a Handle ID. Raising these bounds requires measured evidence, not silent eviction.

## Implementation sequence

1. Add a distinct `agent_handle` lifecycle to the existing canonical Work journal. Preserve
   Run-bound Handle semantics. Immutable originating Run/Session/attachment evidence survives
   parent End; Work completion gates live children and destruction additionally gates unreaped
   resources. Extend exact and bounded projections together, invalidating disposable caches.
2. Give each child an independently owned Python host and execution resource. A host-owned
   coordinator, not the parent runner, owns scheduling, the scope deadline, durable outcomes,
   and cancellation. Nested child spawning is explicitly unsupported in this pilot.
3. Route child appends through one per-Work writer admission path: borrow the current Run's
   writer under its semantic gate, or use a short-lived writer after the Run closes. Never open
   a competing writer behind a live writer's sequence cache, or bypass its advisory owner lock.
4. Add authorized Handle lookup/control and explicit Python attachment/await-interest, followed
   by the parent-End, second-Session, expiry, cancellation-race, and cold-result proofs above.
   The existing production path remains unchanged until this integrated proof is available.

Build verification has one owner; implementation lanes freeze all owned sources and tests before
the shared package is compiled. Isolated primitives are not reported as completed pilot behavior.

## Current implementation boundary

The canonical lifecycle, independent Python execution resource, admission queue, per-Work
writer route, and coordinator are implemented with focused regression coverage. An internal-only
Hosted opt-in now routes all Run opens through the coordinator and supplies Work-owned `spawn`,
explicit `attach_agent`, and retained-result Futures. Public service control and production
activation are still in progress; ordinary launch configurations leave the opt-in unset.
Pilot request admission is limited to 64 KiB (the execution resource's supported input); retained
result bodies are limited to 8 MiB. These are explicit refusals, not truncation.

The current writer preflight uses an exact in-memory reduction of the Work journal, not a
bounded-cost persistent lookup. Historical display-index limits must not prevent a child's
terminal record. Read output is bounded; full journal replay and retained identity sets remain a
performance limitation to measure before broad rollout.

Reap events currently establish only canonical lifecycle semantics. They do not prove deletion
of shared content-addressed body objects. No coordinator reap/destruction API may claim that
physical retention policy has completed until safe body/resource ownership and deletion are
implemented and verified. Directly unlinking a shared body by digest is not an acceptable shortcut.

Before activation, propagate independent-child obligations into service recovery/shutdown and
catalog/activity projections. A parent's idle or ended runtime is not evidence that its Work has
no background execution. Service recovery currently conservatively withholds idle when a child
blocks completion; fresh child-coordinator liveness must be integrated before making that state
actionable. Keep parent Run End separate from Work completion/destruction throughout.

## Private integration proof (2026-09-10)

The isolated real-Python Hosted test passes parent `spawn` without awaiting, observer detach,
explicit parent End with the parent's Python process stopped, independent child completion,
fresh-coordinator terminal lookup without journal mutation, and a second canonically attached
Session reading the same result twice. Explicit namespace collision preserves the existing value.
This is a Core/Hosted integration receipt, not a signed GUI, network authorization, remote process
restart, or active-execution-recovery proof.

Callback admission is memoized before parent journal preflight so an at-least-once callback can
recover an already-admitted Handle after the parent action journal fails. The local Future never
turns a scope deadline into a fabricated terminal outcome; the coordinator owns expiry and only
canonical terminal evidence settles the observer. `result(timeout)` remains a local wait bound,
and `Future.cancel()` does not issue a Work cancellation. Await interest is observer-qualified.

Next integration boundary: add a typed authorized Work-Handle cancellation/read path through the
service and its transport, keeping cancellation distinct from active-Run Stop. Preserve exact
client command identity and canonical evidence under duplicate/conflicting requests. Then include
coordinator liveness/drain and independent-child obligations in shutdown, recovery, and bounded
activity projections before enabling the pilot in the daemon or installed app. Body reaping and
the default user-facing scope deadline remain explicit, unresolved rollout gates.

Verification checkpoint: the private integration tree passed `just compile` and the complete
self-test suite (1,143 cases, 17,492 assertions; 545.71 seconds). A subsequent conservative
service correction shares the parent-ended child recovery predicate across bootstrap, command
admission, scan, descriptor, and idle reconstruction. Its real-journal regression passes
16 assertions: live and cleanup-indeterminate children remain recovery-required; Start and
Complete refuse without Work/Session/control writes or actor creation, even after the disposable
registry recovery fact is removed. This is not a service activation or child-owner liveness proof.
