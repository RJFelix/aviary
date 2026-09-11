# Phase 5 approval brief: host-owned agent children

Status: approved for implementation by Ryan, 2026-09-10. Private Hosted/Python integration
is being verified; public service control and production activation remain incomplete.

Lifetime policy decided by Ryan, 2026-09-11: background agents run until they finish or are
explicitly stopped by default. Time, token, and spend limits are optional. This supersedes the
initial pilot's mandatory deadline and the unresolved-default references in older checkpoint
notes below. The existing runtime still requires a deadline; this decision is not an implementation
or activation receipt.

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
- Default to **no lifetime budget**: run until the agent finishes or an authorized caller
  explicitly stops it. GUI loss and parent End remain unrelated to child lifetime.
- Allow optional time, token, and spend limits, individually or together. A selected time limit
  covers queue and execution together; no hidden hold timeout substitutes for it. When multiple
  limits are selected, the first reached stops further work under that scope.
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
running execution. An optional deadline applies from original admission, including all queue
time. When no time limit is selected, there is no expiry timer.

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

## Service cancellation slice

Expose a distinct typed `cancel_agent_handle` operation, not a new meaning for active-Run Stop.
It requires the caller's exact attached Session relationship plus both Work `control` and
`cancel` grants. The child lifecycle envelope retains its original Run/Session; the cancellation
command separately identifies the authorized caller, which may be another attached Session.
Client-qualified command IDs share the existing Work command namespace, so reusing an ID for a
different Handle or Run command is a conflict, not another effect.

Retain bounded cancellation and terminal evidence in the canonical/exact/bounded Handle state.
The proof includes the actual Work/Handle envelope and append sequence/predecessor, not just a
response label. Cancellation cause links and physical predecessor links remain separate. A cold
duplicate can return its original cancellation cursor after terminalization without claiming
that the responding daemon authored it or that the child is still alive. Already-requested,
already-terminal, unavailable, and ambiguous responses must not fabricate a caller receipt.

The client forwards one explicit request. Connection loss does not trigger automatic cancellation
replay. The host admission drain includes this operation. Integration remains opt-in/internal;
production daemon launch, default deadlines, owner-liveness projection, and physical body reaping
are outside this slice's activation boundary.

### Cancellation checkpoint verification (2026-09-11)

The typed operation is implemented through the journal-backed service, socket transport, client
session, and daemon admission drain. Per-Work cancellation admission serializes preflight, one
owner call, and canonical reconciliation with bounded holders/waiters. Exact retries retain the
original proof after terminalization; altered command envelopes conflict. The reference service
explicitly refuses unmodeled children without advancing the Work cursor. Native child request and
result bodies use the existing authorized body transport; unrelated nested references confer no
read capability.

- `just compile`: Aviary and aviaryd pass; SelfTest product build passes.
- Phase 5 focused suite: 53 cases / 608 assertions pass, 22.24 seconds.
- Concurrent duplicate cancellation: five consecutive passes, each 1 case / 13 assertions,
  including exactly one durable cancellation event.
- Full traced suite: 1,161 cases / 17,754 assertions pass, 519.62 seconds, with idle sleep
  inhibited for the test executable. An earlier overnight run failed four assertions/errors
  across three cases after 41,044 seconds; it is not a green receipt. Those cases passed unchanged
  in isolation and in the fresh complete run.

The installed signed app/helper were not replaced or restarted. This proves the Core/service
boundary, not production child-owner liveness, a remote deployment, or GUI cancellation controls.

### Recorded child visibility

Thread a privacy-safe Work-owned agent fact through `LocalTimelineCatalog.WorkRow`, per-Work
canonical Session summaries, recovery projections, Reader Census, and the existing working-state/
activity presentation. Keep it separate from Run-owned Handles and older child-lifecycle records.
Retain origin, state, terminal outcome, cleanup state, and exact latest event; do not copy prompt,
result bodies, or runtime values into catalog metadata. Bound presentation with completion
blockers first and explicit omissions/unknown-domain behavior.

Prove that parent End does not erase a child, indeterminate cleanup remains a completion blocker,
and quiescent terminal/reaped records are not presented as live execution. Add a separate Census
fixture for the lifecycle rather than weakening the existing unknown-domain fixture. Regenerate
disposable reports with a projection-rules version bump; no compatibility decoding is needed.
This slice requires no new RPC or lifecycle event and does not enable execution or cancellation
controls. Fresh owner-liveness, shutdown accounting, deadlines, and physical retention remain
separate activation gates.

The recorded projection now has one shared metadata fact across local Work rows, exact attached
Session summaries, recovery rows, Census, and working-state presentation. Recovery and display
bounds retain completion blockers before settled records and report omissions. Facts affected by
unknown Work/runtime/external-effects domains are unavailable, not a claim that there are no
background agents. A disconnected chat may retain its last canonical facts, but the activity
disclosure explicitly separates that recorded state from current process liveness.
Attached-Session readers additionally require known reciprocal attachment evidence on both
journals. Work-only readers may retain child records when only attachment state is unknown;
that does not grant a Session visibility or make Continue/Trash safe. Invalid lifecycle/cleanup
metadata is rejected on decode and cannot produce a completed recovery disposition.

The activity sheet and chat strip label this group **Recorded background agents**, separately from
Run-owned Handles and older child-lifecycle counts. The Census projection rules and fixture manifest
are version 2. Its `variants/work-agent-handle-lifecycle.jsonl` follows two children through parent
End, a successful quiescent terminal and reap, and an indeterminate terminal that still blocks
completion. Prefix, incremental, catalog/recovery parity, metadata privacy, unknown-domain, and
incomplete-tail checks exercise the same records. This does not enable GUI cancellation controls.

Next: establish fresh coordinator ownership/liveness evidence, include children in host shutdown
accounting, and prove deadline/retention behavior before promoting the private execution pilot.
Recorded queued/running state alone must never authorize reconstruction or claim a surviving
process. The installed app/helper are a separate deployment boundary from source/test receipts.

#### Recorded visibility verification

Verification of recorded visibility (2026-09-11): `just compile` builds Aviary and aviaryd without
warnings; the SelfTest product builds. The focused Phase 5 suite passes 66 cases / 947 assertions
in 23.43 seconds. The final complete traced suite passes 1,174 cases / 18,095 assertions in
516.16 seconds with process-scoped idle-sleep inhibition. Narrow (520-point) and stale activity
fixtures were rendered from the debug app and visually inspected; these are deterministic
presentation checks, not installed-app or public-pilot activation proof. The signed installed
app and helper were not replaced or restarted. Independent review corrections cover unknown
attachment-domain visibility, destructive-action gating, invalid metadata/identity bounds,
Codable round trips, and the unavailable-only activity entry point.

#### Next bounded slice: fresh owner observation and shutdown admission

`WorkAgentChildCoordinator.Entry` is the live owner; neither a registry `.live` row nor a recorded
Handle state proves that ownership. Add a bounded coordinator observation/freeze seam before
any public liveness presentation. Distinguish locally owned queued/running/cancel-requested,
ambiguous admission, and terminal-but-unquiesced entries. An empty fresh coordinator means no
locally proven owner, not proof that recorded work is dead or reconstructable.

Daemon shutdown already closes service admission and checks durable recovery obligations. It
must also close child admission and atomically inspect coordinator obligations before stopping
the host. Refuse shutdown while any ownership or cleanup remains unresolved. Parent End must
not invoke this shutdown barrier: its independent children intentionally outlive the parent.

Required race proofs: shutdown versus private admission/pump before its first append; parent End
with a live child; terminal outcome before quiescent cleanup; ambiguous started/cancellation
append without replaying a factory; and a fresh coordinator over recorded running work. Keep the
pilot opt-in while proving these seams. Default deadline policy and physical retention remain
separate from the recorded-view and ownership-observation checkpoints.

#### Owner observation and daemon shutdown

The coordinator now exposes bounded, process-local counts for admitting, queued, starting,
running, cancellation-requested, settling, ambiguous, and terminal-unquiesced ownership. It
does not serialize these as durable liveness evidence. Freeze tokens close only new admission;
existing children continue independently. Token-qualified thaw cannot release another caller's
freeze, and terminal sealing is irreversible for that coordinator instance.

Graceful daemon shutdown drains service admission, atomically freezes private child admission,
and refuses immediately on local ownership before attempting a potentially locked canonical
scan. An empty owner observation still requires the existing durable recovery check. Refusal
reopens only the attempt's own freeze. Successful stop, forced stop, and failed startup seal
child admission; they do not fabricate child cleanup or End events. Parent End is unchanged.
The journal-backed composition obtains this barrier from its installed private child canceller;
an adapter without the actual ownership barrier fails closed. No default pilot activation,
public liveness wire contract, deadline policy, or retention policy is introduced here.

The synchronous, lock-backed irreversible seal is shared by admission and thaw. The daemon
retains the freeze lease and seals it before the first forced-stop suspension; a delayed thaw
therefore cannot admit a child in the gap before an asynchronous coordinator call. Hosted pilot
configuration must name the exact coordinator installed in the journal-backed service.

Focused verification passes: 77 Phase 5 cases / 1,064 assertions and 16 daemon cases / 133
assertions. These cover admission/start boundaries, ambiguous ownership, bounded independent
freeze tokens, indeterminate cleanup, fresh-owner absence, refusal/reopen, graceful sealing,
and forced-stop overtaking a suspended shutdown. The final complete traced macOS suite passes
1,185 cases / 18,214 assertions in 515.55 seconds under process-scoped `caffeinate -i`.
`just compile` builds Aviary and aviaryd, and the SelfTest product build passes without warnings.
Installed app/helper remain unchanged; no new Linux runtime receipt or public pilot activation
is claimed by this checkpoint.

#### Physical retention remains separate

The existing `agent_handle.reaped` transition preserves body references and readable retained
content. It is not proof of unlinking body files. There is no production coordinator/service
reaper; `ContextBodyStore` is shared by digest and has no reference-ownership deletion protocol.
Do not turn metadata reaping into a shortcut around physical-cleanup or destruction requirements.

The next bounded work is to define exact, explicit reap intent and body ownership evidence,
including other references to the same digest and crash ordering. Keep the 256-identity bound
and refuse further admission instead of silently evicting results. Execution deadline expiry
must not imply result-retention expiry. Any automatic deletion remains a separate product
decision before broader activation; lifetime defaults are now decided above.

#### Optional execution limits: implementation requirements

- Represent absence explicitly in the canonical record, coordinator, queue, executor, and Python
  Future payload. Do not replace an absent deadline with a distant timestamp or a large sentinel.
  Invalidate disposable derived caches when changing the canonical contract.
- Remove hidden child-turn/model-call ceilings from the default Work-owned path. The current
  executor's default `maxIterations = 20` would otherwise contradict "until finished or stopped."
  Concurrency, admission, frame/body size, and per-operation failure bounds remain distinct
  operational protections, not implicit lifetime budgets.
- Time is wall-clock scope time, including queueing. Token and spend limits cover cumulative
  Aviary-owned model usage for that child. Show what is counted; provider output-token limits
  per request are not cumulative child budgets.
- Check a configured budget before dispatch and reconcile actual usage afterward. Record the
  specific limit that stopped execution, consumed amounts, and any overshoot/unknown accounting.
  A reached limit is not successful task completion, and cancellation still requires truthful
  resource-quiescence evidence.
- Spend controls must distinguish measured usage, price estimates, and unavailable prices.
  Do not advertise an exact hard dollar ceiling when in-flight requests or missing accounting
  prevent proving it. Arbitrary external effects/charges from trusted Python are not covered by
  a model-spend limit or a new sandbox boundary.
- Test no-limit execution beyond the former iteration ceiling, every optional limit separately,
  combined-limit precedence, queued time expiry, delayed/missing usage, cancellation races, and
  cold/live record parity. Existing parent-End and daemon-shutdown proofs must continue to pass.
