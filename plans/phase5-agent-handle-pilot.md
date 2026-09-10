# Phase 5 approval brief: host-owned agent children

Status: proposed, not authorized for implementation. 2026-09-10.

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

## Approval requested

Approve this agent-only, explicit-deadline pilot and its ownership/cancellation semantics before
changing Run teardown or canonical Handle terminality. Detailed capacity values and implementation
sequencing should be written against measured pilot behavior, not inherited from the older shaping
document's “mostly renaming” estimate.
