# Aviary core experience: durable sessions, truthful actions, and calm control

Status: implementation in progress; Phase 0 and Phase 1 live-producer/local-catalog foundations implemented, phases not complete
Date: 2026-08-31
Scope: human-agent sessions, chat, action understanding/control, local/remote Work ownership, recovery, review, and multi-agent attention

Implementation checkpoint (2026-09-02): stable session/Work/run identity, serialized command
admission, immutable admission plus delivery receipts, writer-confirmed input delivery, live
transcript overlays, true steer/follow-up routing, scroll anchoring, truthful run states, explicit End
run, and cancellation/quiescence barriers are implemented in the current tree. Capability-scoped
safe-boundary cancellation, in-process Detach/Reattach, reversible Archive versus Trash, durable
failure/cancellation reload projection, and semantic accessibility labels for the live interaction
surface are also implemented. Quit and relaunch await one per-Work teardown barrier; failed
preparation and natural Claude exit reclaim their runtime hosts; duplicate cold resume is rejected
at Work identity; and partial Trash failures are reported without pretending transcript and artifact
movement were atomic. A deterministic real-Agent interaction scenario covers streaming, steering,
follow-up ordering, cancellation acknowledgement, durable handoff, and cold-reload convergence.

The Timeline v2 foundation now has authority-bearing Session and Work journal references, distinct
physical append and semantic conversation chains, structured actors and causal command receipts,
typed evidence links, explicit six-plane recovery coverage, bounded context crossings, pure
single-journal reducers, and a Session assembler that attaches multiple Works at exact cursors. Its
byte reader preserves exact ranges, adapts legacy records deterministically, retains unknown future
events, and quarantines malformed or truncated suffixes without overstating the valid prefix. The
versioned Reader Census fixture exercises branching, compaction, model change, queued input, child
completion, late steering, indeterminate actions, unknown events, legacy input, retained bodies, and
malformed/truncated tails across linked Session and Work journals. The production local Timeline
catalog now joins the Census. The production Flock UI consumes the same source-qualified,
unknown-aware Work projection exercised by the fixture, and the Sessions list plus command palette
consume a canonical Session search projection exercised by that same fixture. Native macOS
notifications now consume the same canonical Session/Work projection; service recovery remains
explicitly unwired.

A canonical catalog adapter now projects authority-qualified Session identities and attached Work
at independently verified requested/observed cursors. Only attached, exactly aligned Work with
valid structural and semantic reducer projections can lend the catalog lifecycle, model,
attention, or action facts; unavailable, stale, ahead, divergent, detached, and corrupt Work
remain visible without those facts. The production `SessionCatalog` now scans bounded native local
Session and Work journals, validates their declared owner/authority/locator rather than trusting
directory names, and publishes Work as an independent inventory. A same-ID legacy transcript joins
as one companion row: canonical lifecycle/model/attention/Work truth drives the UI while the legacy
file remains the compatibility target for transcript and artifact actions. Native-only sessions are
observe-only; legacy-only rows retain their prior behavior; corrupt, tailed, unknown, foreign,
duplicate, ambiguous, or symlink-misaligned records remain visible or diagnosed without lending
facts. Duplicate Work identities are excluded from Session assembly, invalid or tailed Sessions
publish no canonical summary, recoverable Work-prefix cursors remain explicit but non-projectable,
and unexpected directory failures are diagnosed rather than appearing as an empty catalog.
Unknown Session semantics also scrub legacy-derived title, message, usage, model, provider,
and lifecycle fields from a companion display rather than letting compatibility data refill an
unknown canonical projection. Continue re-reads native state at its action boundary and the native
bundle's owner lock remains the final admission guard; Trash holds that same persistent Session
owner lock across its fresh canonical read and transcript move. The Reader Census registers this
production consumer. Flock now inventories Work independently of Session, qualifies child identity
by Work, retains legacy trees only through explicit compatibility provenance, and withholds child
lifecycle when an unknown Work/runtime/external-effects domain may affect it. A separate bounded,
client-neutral attention projection retains authored/effective attention, independent Session/Work
cursors, attachment identity, integrity, tails, and unknowns; its `attentionRequirement` is
explicitly `unknown`, `none`, or `required`, without implying that the observing GUI has control
capability. Duplicate summaries become one unknown conflict row, and attachment, unknown-event,
and corruption evidence is independently bounded with omission counts. Canonical Session search is
an ephemeral, conflict-free projection over exact active-branch user/assistant conversation and
bounded title/model metadata; unknown or invalid native facts fail closed, legacy compatibility is
sanitized, identity matches are exact-or-prefix by field, and result bounds do not hide later corpus
rows. Search selection retains the GUI action identity and canonical EventRefs, native companion
rows cannot be refilled by legacy AgentTree prompts, and conversation lifecycle is kept separate
from attached Work liveness. The first notification adapter is now wired for needs-you,
failed-recovery, and ready-for-review transitions. It observes permission without prompting at
launch, baselines rather than replays attention accumulated while delivery is disabled, uses bounded
typed cold-click routes,
and preserves the route's Session/Work/action/cursor identity in the workspace. Session selection is
re-resolved canonically; reconciling every Work/action/cursor field against the current catalog before
labeling the focus as exact evidence is part of the Work-recovery follow-up. Unknown, corrupt,
unaligned, or conflicting rows cannot lend notification facts, while unrelated exact Sessions remain
independently actionable. Delivery checkpoints are bounded and persisted; cold-click queues are
bounded but currently in memory. An OS-acceptance crash window still provides at-least-once rather
than exactly-once delivery until a durable outbox is reconciled with pending/delivered platform
request identifiers. Child coalescing and incremental journal watching remain Phase 2/Phase 1
follow-up work. Service recovery remains
unwired. Work rows separately report
whether a supplied journal read is absent, exact, stale, ahead, foreign, divergent, or invalid;
`journalIntegrityValid` is nil only when no read was supplied and is false for every supplied
non-exact or tailed read. A supplied exact, canonical, tail-free read is required before assembly or
Work execution facts can project, while a tailed local journal retains a distinct non-projectable
committed-prefix cursor.

The production GUI and CLI paths now open the native paired Session/Work bundle before Start
admission and carry that exact bundle through `SessionCommandController`, `AgentRunner`, and
`Agent`. Native Work acceptance is authority; the legacy transcript is a downstream compatibility
projection, so a later projection failure cannot rewrite an accepted command as rejected. Exact
causal cursors survive admission, and accepted commands end in delivered, not-delivered, or
indeterminate delivery receipts with first-terminal-wins concurrency semantics. Journal ambiguity
latches the run and blocks later effects. End retains a deliberately degraded local teardown permit
so journal failure cannot strand resources.

The native producer foundation now includes a locked, synchronizing single-journal writer and a
paired `RunJournalBundle` for one Session journal plus one Work journal. Fresh creation opens both
files before semantic genesis, records the mirrored attachment and Run, and reports non-atomic
partial prefixes without deleting evidence. Cold reopen requires both valid journals, retains the
selected semantic conversation tip, existing command/action identities, effective model, and exact
next cursor, and refuses active or otherwise unfinished prior execution instead of claiming
recovery. Inputs have distinct accepted and delivered receipts, including queued delivery after a
later reopen; actions receive an effect permit only after intent and start are synchronized; action
IDs are single-use; terminal action and Run outcomes retain typed failure/retry state; and a FIFO
non-reentrant semantic gate prevents concurrent callers from reusing a host order or bypassing
identity/lifecycle checks while the actor awaits disk I/O. The pair deliberately does not claim a
cross-file transaction.

The live in-house path obtains native effect permits for provider and compaction requests, Python,
MCP, hooks and callbacks, runtime creation/teardown, web/search/extract, peer and self delivery,
memory, artifacts, images, and child dispatch. Transport loss after a possible effect is recorded as
`indeterminate_effect` with unsafe retry rather than a generic failure. Runtime callback admission
closes and drains before teardown; child running and terminal lifecycle records keep parent
provenance; and canceled callers cannot prevent action, Run, or checked-close terminal records.
This preserves Aviary's intentional capability-first, unsandboxed Python posture: hooks can govern
Aviary-dispatched calls but are not described as a containment or security boundary.

Every in-house provider and compaction request now crosses one native preparation boundary. Aviary
first retains the full semantic `ChatRequest` components in a content-addressed body store, then
appends a metadata-only `context.assembled` Session event, then appends the causally linked provider
action intent/start on Work, and only then invokes the provider. Components carry stable content and
per-request inclusion identities, source authority where known, hashes, a named semantic byte
measurement basis, delivered/full sizes, explicit truncation and omissions, and cumulative bytes for
the Run. The body file, directory hierarchy, and rename are synchronized before the journal crossing;
the bundle resolves and verifies every referenced body, owns exact per-Run cumulative totals, and
restores those totals from cold reduction. Live and cold paths share overflow-safe manifest and
Work/Work Host/Run provenance validation. Manifest or Work-action failure returns no effect permit.
Reducers and Reader Census retain the latest complete manifest without copying bodies or inspecting
Python `repr` values.

System-prompt provenance is now assembled producer-side instead of inferred from provider wire
text. The exact flattened system `ChatMessage` remains the replay authority, while an ordered,
bounded source manifest records stable opaque identity, kind, status, UTF-8 sizes and digests,
full/delivered/rendered body addresses, and the exact delivered-byte offset inside each rendered
slice. The live writer binds the concatenated source bytes and assembly digest to that retained
system message before appending an immediately causal `context.sources_observed` /
`context.assembled` pair with exact Session, Work, Work Host, and Run identity. Native cold resume
reconstructs the same bytes only from retained bodies and independently rechecks present,
truncated-prefix, framing, media, and observation relationships. Reader Census exposes the latest
recorded provider crossing as bounded metadata—not as a promise about the next request—and keeps
raw source and compaction content behind explicit inspection. Working directory, base instruction,
context-file, generated goal, and compaction sources are individually represented. SkillGate and
MemoryGate output is intentionally one block-level source each in this slice; individual skill and
memory identities and included-versus-listed provenance remain owed.

Native cold resume now captures an immutable replay seed while the canonical Session/Work pair is
locked and before the replacement Start command can append its prompt. The seed requires exact
Session and Work tip cursors, the mirrored attachment at that Work tip, a causally linked and
terminal ordinary provider action, every retained message and tool-schema body, and a complete
sendable conversation tail. It rejects compaction-provider boundaries, unknown body media, missing
or corrupt bodies, stale or tailed reads, unrepresented post-boundary actions, dangling tool calls,
and text-only assistant rows that cannot prove tool-call absence. Native authority never silently
falls back to the legacy transcript. The replacement Run records the six-plane recovery matrix;
the runner restores retained pinned instructions, verifies the live tool schemas before the first
provider call, uses a fresh Python namespace, and reports Futures/Handles as lost and repository,
artifact/memory, and external-effect coverage as unknown. Structured assistant bodies are retained
before their Session events, while tool-only assistant events remain in model history without
creating an empty visible chat row.

The Apple Swift 6.3.3 compiler accepts the SDK emitted by Apple Swift 6.3.2; the compatibility probe
configures its own writable module cache and succeeds both directly and through every gate. At this
checkpoint, the full suite passes 499 cases / 5,592 assertions in 47.06 seconds and `just compile`
is clean. Phase 1 passes 208 cases / 3,661 assertions in 16.45 seconds. The versioned 100,000-event
benchmark reads and reduces a 46,766,700-byte input in 5.769 seconds on the checkpoint machine
(generation 0.880 seconds). The visual gate renders all 9 canonical screens; it also caught and
closed a SwiftPM snapshot crash by making the UserNotifications adapter available only from a real
application bundle. Final Sol review found
no remaining must-fix issue after exact cursor/attachment/read authority, local action-time
revalidation and owner locking, unknown-domain display scrubbing, duplicate non-projection,
slash-injective Work identity, provider-action causality, exhaustive retained-body decoding,
structured assistant replay, pre-Start capture/cleanup, source-assembly binding, truncated-source
replay, metadata-only inspection, parent-qualified legacy selection, multi-Session attention,
bounded evidence, conflict projection, Work-liveness separation, bounded search allocation, and
wrapper-only injection findings were remediated. A second notification-specific Sol review found no
P0/P1 blocker after typed turn outcomes, turn/run transition deduplication, per-Session conflict
isolation, authorization gating, bounded typed routes, and cold-click routing were remediated.

Phase 0 still owes real VoiceOver/keyboard UI automation and broader driver focus/race proof. Phase 1
still owes the remaining canonical consumer migrations (service recovery and other named legacy
readers); individual skill/memory identity and included-versus-listed
provenance inside the now-durable block-level prompt sources; independent native Work bundles for
children; actual disk-full and permission fault reachability; and a measured
peak-RSS budget. The semantic component measure is deliberately not claimed to be provider-specific
HTTP wire size. The 100,000-event benchmark fixes an encoded-input and read/reduce baseline, but does
not claim incremental rendering or bounded peak memory. The out-of-process Work Host,
GUI-independent process survival, and remote multi-client ownership remain Phase 3 rather than being
implied here.

## Outcome

Aviary should feel less like a chat window wrapped around a process and more like a reliable
workspace for a continuing collaboration. A person must always be able to answer:

1. What is the agent doing now, and why?
2. What has it changed or caused outside the conversation?
3. Does it need me, or can I safely leave?
4. What will each control do, and when will my message be delivered?
5. If Aviary, the runtime, or the machine dies, what survives and how do I recover?
6. What evidence supports the final answer?

The primary human-facing object is therefore a **durable session workspace**, not a transcript and
not a process. But a session is not the ultimate owner of executable work. Aviary also needs an
independently addressable **Work** object, owned by a **Work Host**, that can outlive the GUI and its
originating conversation. Sessions attach to ongoing or completed Work for observation, control,
evidence, or continuation.

The canonical record is correspondingly linked rather than monolithic: a session journal records
conversation and attachment decisions; a work journal records execution, actions, artifacts, and
outcome. Chat, activity summaries, diffs, review, Flock, recovery, and audit views compose
projections of those records without copying or pretending that the GUI owns either one.

This direction preserves Aviary's strongest existing property—an inspectable, local, crash-readable
record—while fixing the seams where the current interface promises more than the runtime can
guarantee.

## Orientation: what Aviary already has

Aviary is not starting from zero. The current code has unusually good raw material:

- `SessionWriter` creates an append-only, complete-line JSONL record before work begins. The
  legacy Session bridge now synchronizes command intent before dispatch and latches writer
  failure; the native split Session/Work timeline writer and per-action durability denominator
  remain required work.
- `SessionParser`, `SessionResume`, and the transcript tree reconstruct usable history defensively,
  including compaction and unfinished tool-call cases.
- `Agent` already distinguishes model deltas, tool start/finish, steering, follow-ups, child agents,
  compaction, dispatched work, success, and failure internally.
- The in-house agent remains attached across turns, so a conversation can continue without
  recreating its interpreter every message.
- One transcript renderer is used for live and historical in-house sessions.
- Tool calls and results are paired, reasoning can be collapsed, raw records remain inspectable,
  and usage/provenance are not hidden.
- Core self-tests cover parsing, replay, resume, steering, follow-ups, and many failure cases.
- `Future`, callback recording, Flock, and the proposed Handle model point toward durable work and
  multi-agent coordination rather than a single synchronous request/response loop.

These are the hard parts many competitors retrofit late. The plan should deepen them rather than
replace them with an unrelated UI state store.

## Current breaks in the product contract

This section is the planning baseline, retained so the reason for each phase remains reviewable.
The implementation checkpoint above names the Phase 0 breaks already addressed; unchecked items
remain current until verified through the phase exit criteria.

The most important problems are cross-layer seams, not missing decoration.

### Chat and controls are not yet truthful

- `InHouseDriver` collects streaming text and thinking, but `LiveRun` does not project those fields
  into `TranscriptView`. The user sees a generic streaming indicator, then the completed turn.
- The composer advertises separate **Steer** and **Queue follow-up** operations. The UI adapter's
  follow-up path calls `send`, which becomes steering while busy; the queue shown in the UI is not
  populated. The core agent supports the distinction, but the product surface currently does not.
- **Abort** tears down the attached driver and runtime rather than canceling only the active turn.
- Cancellation is only observed at agent-loop boundaries, so the label also overstates immediacy.
- Auto-scroll follows new content unconditionally instead of preserving a reader's position and
  offering a clear “Jump to latest” affordance.
- The launcher exposes thinking, persistence, and context controls that are not passed consistently
  through the in-house start path. Payload recording also receives an unrelated identity, so the
  running session cannot reliably expose its own wire log.
- Send admission is checked before `isStreaming` is set inside a newly scheduled task, leaving a
  rapid double-send race.

### A live run is an in-memory UI object

- `AppModel.runs` is the source of active state. Relaunch loses the active registry and automatic
  attachment.
- Closing or stopping a run tears down runtime-owned background children.
- Cockpit excludes exited work and Sessions treats persistence as a separate experience. There is
  no durable “needs you / working / ready for review / recent” inbox.
- A fixed polling wait for dispatched callbacks is not ownership. UI-process death can still mean
  work death or an orphaned result.

### Actions are observable but not yet a product model

- The current activity model is primarily tool names plus raw Python input/output. It does not
  represent intent, affected resources, optional human decisions, expected effects, reversibility,
  artifacts, or a durable action lifecycle.
- Some useful live events are observer-only rather than recorded facts, so reloading can yield a
  less informative account than watching live.
- Aviary intentionally inherits Prime-Agent's capability-first, trusted-execution posture: the
  general Python interpreter may perform file, process, socket, and network effects directly.
  Hooks remain useful for advice, workflow policy, confirmations, and observability, but are not a
  containment boundary. Comprehensive agent sandboxing is deliberately deferred until evidence
  justifies the capability and complexity cost.
- A final answer is not structurally linked to the commands, tests, diffs, screenshots, child-agent
  results, and unresolved risks that justify it.
- Persistence itself currently fails open: many model-loop journal writes discard errors. Disk-full,
  permission, or other I/O failure can therefore let external work continue after its audit record
  has stopped. “Append-only” is valuable only if failure policy is explicit.

### The information architecture reflects implementation eras

- Cockpit, Live, Sessions, and Flock each expose part of the same collaboration but do not form one
  continuous workspace.
- Binary running/exited state is too weak for real work. Waiting for user input, waiting for
  confirmation, held, disconnected, recovering, and ready for review all require different attention.
- Multi-agent activity is visible as a separate topology but not integrated into the parent
  session's “now, why, next, result” story.
- The current Sessions view gives large injected-context blocks and aggregate counts more visual
  weight than the human/agent exchange. A `needs_input` session exposes its next step as a small
  inspector link rather than an obvious composer or decision card.
- Current Cockpit and Live copy still names removed prime-agent/RPC architecture. Stale internal
  architecture presented in primary UI is a trust defect, not a documentation nicety.

## Competitive bar

Current peers have converged on a durable task workspace with explicit state, queue/steer/stop
semantics, progressive action disclosure, review artifacts, approvals, checkpoints, and an
attention inbox. No single peer owns the whole experience:

- OpenAI Codex makes long-running goals, parallel chats/worktrees, notifications, subagents, and a
  review pane part of the same workflow.
- Claude Code/Desktop is a strong reference for resumable sessions, background work, separate
  tasks/diff/preview/terminal surfaces, and independently restoring code or conversation.
- Cursor is especially clear about queued messages versus steering and about editable/reorderable
  pending input.
- Devin/Cascade is strong at explicit blocked/ready states and scoped approval cards.
- GitHub Copilot has a strong repository-native audit chain from session activity to commits and PRs.
- Google's Antigravity and Jules are useful references for typed activities and human-readable
  artifacts rather than raw tool-log narration.

Advertised features are not evidence of peer reliability, and preview features should not become
requirements merely because they demo well. Aviary's advantage can be a smaller surface with
stronger truth, recovery, and provenance.

## The experience to build

### One durable session workspace

Replace the conceptual split between Live and Sessions with one session that moves through time.
The primary navigation is an attention-oriented inbox:

- **Needs you** — confirmation, question, conflict, or failed recovery.
- **Working** — agent or background action is making progress.
- **Ready for review** — work stopped intentionally with evidence to inspect.
- **Recent** — idle, completed, canceled, or failed sessions.

These are derived priority groups, not exclusive persisted session states. A session can be
disconnected, still working remotely, and waiting for one confirmation while another result is ready
for review. The list shows the highest-priority attention group plus secondary state badges.

Opening any item shows the same workspace whether the agent is currently attached, disconnected,
or historical. The persistent header stays compact: title/goal and primary attention state.
Project/directory, branch or worktree, Work Host, model, run identity, and provenance live in a
secondary inspector rather than crowding the conversation.

### Local, remote, and remote-first share one ownership model

The GUI is a client and projection; it never becomes the lifetime owner merely because it launched
the work. GUI↔Work is explicitly many-to-many and location-independent:

```text
                 Work A                 Work B                 Work C
                 local Host A          remote Host B         remote Host C
GUI A                 ●                     ●                     ●
GUI B                                       ●                     ●
GUI C                 ●                                           ●
```

- Closing a view, losing the network, quitting the GUI, or switching devices only detaches that
  client. Termination requires a separate durable command expressing user intent.
- One GUI may maintain attachments across its local Work Host and many remote Work Hosts. Its inbox
  is a projection across those hosts; it does not invent a total order between unrelated hosts.
- Many GUIs and sessions may observe **and control** the same ongoing Work. There is no exclusive
  controller lease or implicit handoff. The Work Host serializes accepted commands into the Work
  journal and records client actor, session context, command ID, causal cursor, acceptance/rejection,
  and effect.
- Concurrent controls are never silent last-writer-wins. Operations declare preconditions: the host
  orders compatible queue/steer commands, rejects or surfaces stale/conflicting commands, and makes
  terminal/destructive operations first-accepted with later attempts receiving the durable outcome.
- A session attaching to ongoing Work resumes from a durable cursor. A session attaching to
  completed Work receives its immutable outcome/evidence. Continuing completed Work creates a new
  linked Work and Run—with explicit ancestry and recovery coverage—rather than adding a Run to or
  otherwise rewriting the terminal Work.
- Work identity and protocol semantics contain no local path, PID, wall-clock, or device assumption.
  The Work Host reports its environment and capabilities; the GUI renders them.
- Local and remote use the same logical protocol. Local transport can be a Unix-domain socket;
  future remote transport can be an authenticated encrypted channel or SSH tunnel without changing
  session, Work, event, or command semantics.
- Remote client authentication and transport encryption protect who may reach a Work Host. They do
  not constrain the trusted agent inside that host. Secrets and execution credentials stay on the
  Work Host; client-visible events/artifacts follow an explicit disclosure policy.

### Conversation first, activity progressively disclosed

Human and agent messages remain the visual spine. Between them, related actions collapse into calm,
deterministic summaries such as:

> Read 12 files · ran 3 commands · changed 4 files · tests passed

Expanding a summary reveals typed action cards and exact output. A pinned activity strip answers:

- **Now** — the current safe-boundary action.
- **Why** — the turn, plan step, or user instruction that caused it.
- **Next** — the expected next step, wait, or decision.

This summary must be derived from the same recorded events as the detail view. It must never be a
second model-generated story that can disagree with the audit record.

### Input delivery is explicit

The composer has one primary send control plus a clearly labeled delivery-mode selector. While work
is active, the available modes are:

- **Steer after current action** — changes the active turn at the next declared safe boundary.
- **Queue after this turn** — starts a later turn after the current one settles.

Cancellation is a separate capability-aware control, not a delivery mode. It requests cancellation
of the named stream or action scope and shows canceling until the runtime acknowledges.

Pending input lives in an editable tray with delivery state, ordering, edit, delete, and “send now.”
When delivered, the item moves into the canonical timeline with an acknowledgement. Engine
capability differences are stated before the user acts, not after a failed attempt.

“Send now” must declare whether it steers at the next safe boundary or first requests interruption;
it cannot be an unnamed third behavior. The composer also preserves one unsent draft per session
across navigation and relaunch, supports multiline and IME-safe input, restores focus predictably,
and makes attached files/images and quoted timeline context visible before delivery. If an engine
cannot accept an attachment type, it is rejected before the message is accepted.

### Actions are legible and controllable

Every consequential action has:

- intent and the instruction/plan step that caused it;
- actor and parent/child lineage;
- lifecycle state and timestamps;
- target resources and expected effects;
- requested human decision, if any, and resulting constraints;
- command/input, exact output, exit status, and artifacts where applicable;
- observed effects, including changed files or external targets;
- reversibility and checkpoint coverage;
- durable error or cancellation outcome.

The default card emphasizes the human question—“what is happening and what could it affect?”—with
raw records one expansion away.

### Completion means proof, not prose

A Work goal may have explicit completion criteria. The completion surface links each claimed
outcome to receipts: diff, file, command, exit code, test report, screenshot/recording, child result,
commit, or PR. Missing verification and irreversible external effects remain visible. Work cannot
be marked completed while an awaited action or handle is nonterminal; a conversation may detach or
archive without rewriting Work state.

## Canonical model and laws

Use these terms consistently across core, storage, UI, tests, and documentation:

- **Session** — durable identity of a human-agent conversation and its chosen context.
- **Work** — durable identity of an executable objective and its outcome; it may be attached to
  multiple sessions over time.
- **Work Host** — the Aviary service and execution environment that owns Work, journals it, and
  applies its lifetime/resource policy. It may be local or remote relative to the GUI.
- **Session Attachment** — durable semantic relationship between a conversation and Work, including
  context/evidence provenance.
- **Client Attachment** — resumable GUI/device relationship to Work, including observe/control
  capabilities and cursor. Many clients may hold control capability concurrently; this is not
  lifetime ownership.
- **Run** — one execution attempt for Work on a Work Host.
- **Turn** — one user instruction and the agent work it induces.
- **Activity** — any durable timeline fact.
- **Action** — a potentially side-effectful unit with a declared lifecycle.
- **Handle** — durable identity for work that can outlive a turn or run.
- **Artifact** — a versioned plan, patch, diff, report, image, recording, or other reviewable result.

Session/workspace state is a reduced product of orthogonal facets, not one linear enum:

- **lifecycle** — draft, active, completed, archived, destroyed;
- **execution** — aggregate projection of attached Work: idle, preparing, working, hold_requested,
  held, canceling, failed;
- **attention** — none, input, confirmation, error, review;
- **connectivity/recovery** — attached, disconnected, recovering, orphaned.

Inbox group, notification priority, and available controls are derived from the full product. A
completed or ready-for-review session may be continued as a new turn without rewriting its prior
outcome; archiving and destruction remain separate operations.

Proposed action execution states:

`proposed → queued → running → cancel_requested → succeeded | failed | canceled | indeterminate_effect`

Human-confirmation state (`not_requested | requested | confirmed | denied`), blocked reason,
checkpoint coverage, and recovery status are orthogonal facts rather than overloaded execution
states. Most actions legitimately skip confirmation. The reducer validates legal combinations.

Every terminal or failed action also records `failure_kind` (`task | infrastructure | policy |
timeout | cancellation | indeterminate_effect | other`) and `retry_safety` (`safe | idempotent |
unsafe | unknown`) where applicable. “Failed” alone is not enough information for recovery.

`indeterminate_effect` means an external effect may have happened but its durable outcome is
unknown. It routes the session to Needs you, blocks ordinary completion until explicitly resolved
or acknowledged, and makes any retry warn about possible duplication. Reaping is a handle/process
ownership outcome, not an action execution outcome.

Holding Work is narrowly defined: **hold after the current safe boundary** permits the current
provider/action boundary to finish, then prevents new turn actions from starting. It does not
suspend an arbitrary shell process or Work-owned background handle. Unsupported engines do not
offer the control.

### State placement, crossings, and recovery coverage

“Recovered” is not one state. Live host reattachment, cold conversation resume, runtime-state
reconstruction, and forking have different coverage. Every resume/reattach/checkpoint/restore/fork
operation emits a `RecoveryCoverage` record with one status per state plane (`preserved |
reconstructed | referenced | unknown | lost | not_applicable`), its evidence/cursor, and caveats:

| State plane | Authoritative placement | Coverage question |
|---|---|---|
| Session and Work timelines | host-side journals | Are exact events/tips present and replayable? |
| Effective next-model context | versioned context snapshot | Will the model receive the same selected instructions, history, summary, attachments, and omissions? |
| Runtime/Python working state | live kernel or declared reconstruction | Is the namespace live, reconstructed, inspectable only, or lost? |
| Futures/Handles/background Work | Work Host/Handle store | Which identities remain running, terminal, reaped, or indeterminate? |
| Memories, artifacts, and repository state | their stores/checkout with revisions | Which exact versions remain addressable or restorable? |
| External effects | external systems plus observed receipts | Which effects are verified, reversible, indeterminate, or outside coverage? |

A GUI must never summarize these as “session recovered” without exposing the matrix. In particular,
reattaching to a live Work Host may preserve a Python namespace; replaying conversation history on a
new host does not imply that it did.

Every transfer into model context is also a named crossing. A `ContextComponent` records stable
identity, source event/Work/Handle/artifact, provenance, full-body locator/hash, delivered size for
this inclusion, and truncation/summary status. Large tool, child, search, and artifact results remain
addressable outside the conversation; the model receives a bounded manifest by default. Cumulative
component-size measurements make context carriage observable without duplicating full bodies.

Core laws:

1. Every accepted user input gets one durable identity and one unambiguous delivery outcome.
2. Every started action eventually has a durable terminal outcome, including
   `indeterminate_effect` when an unclean death makes the external result unknowable.
3. Intent is recorded before an external action begins; observed outcome is recorded afterward.
4. Replaying a journal prefix produces the same user-visible snapshot as was shown live at that
   prefix, except explicitly ephemeral deltas.
5. Reconnect and retry never duplicate an already-committed action without an explicit retry event.
6. Closing a window detaches a client and carries no cancellation intent. Canceling a turn does not
   destroy a session; ending a run does not reap Work; deleting a session does not destroy Work
   that another session can attach to.
7. A parent cannot be completed while an awaited child or handle is nonterminal.
8. New readers/reducers losslessly retain unknown events. Older readers ignore future records
   without corrupting the known history they can understand.
9. Summaries can omit detail but cannot contradict the underlying record.
10. Security and checkpoint claims name their coverage and exclusions.
11. Work identity, ownership, and progress do not depend on a GUI connection, local filesystem path,
    client PID, or client wall clock.
12. Attaching to completed Work never mutates its record. Continuing it creates a new linked Work
    and Run with explicit ancestry and environment/checkpoint coverage.
13. A Work ID names an object; it is not, by itself, a remote authorization credential.
14. GUI↔Work is many-to-many. Work lifetime does not depend on attachment cardinality; accepted
    commands are host-ordered and retain client/session provenance.
15. Every recovery/checkpoint/resume/fork claim carries the state-plane coverage matrix; no broad
    “recovered” label may imply namespace, background Work, repository, or external effects survived.
16. Every value crossing into model context is bounded, provenance-bearing, and linked to an
    addressable retained source; truncation is explicit rather than silent.

## Trust matrix

The plan should be evaluated as a matrix of promises, not a list of UI features:

| Surface | Persisted truth | User control | Recovery invariant | Ship signal |
|---|---|---|---|---|
| Message | accepted, queued, delivered, superseded | edit/delete before delivery; steer or queue | no lost or duplicate delivery | live/reload projection tests pass |
| Active turn | state, safe boundary, cancel request/ack | steer, hold-after-boundary, cancel when supported | reconnect identifies exact turn | kill tests at every boundary pass |
| Action | intent, scope, input, output, effects, terminal state | confirm/constrain when requested; cancel when supported | retry is explicit; idempotency and duplication risk are named | no silent nonterminal actions |
| Background Work | Work Host, lifetime, actor, result | inspect, notify, cancel | survives GUI and run death by policy | automatic reattachment passes |
| Work attachments | work/host/client/session identities, capabilities, cursor | observe/control from many clients, detach, continue | network/client loss never implies termination | many clients reconstruct the same snapshot and command order |
| Optional confirmation | requested action/target/effects and decision | confirm, constrain, or deny | unresolved request returns to Needs you | replay never invents a decision |
| Change/artifact | provenance, revision, coverage | review, comment, restore where truthful | checkpoint lists captured and external state | every completion claim opens a receipt |
| Session | conversation, attachments, attention, outcome | continue, detach Work, archive/delete conversation | GUI/runtime/machine death have defined results | recovery matrix is green |

## Delivery plan

Each phase must leave the product more truthful and usable than it found it. Do not begin with a
large service rewrite; first make semantics explicit and make the linked journals/reducers
authoritative.

### Phase 0 — stop lying at the interaction seams

Goal: make the existing in-process experience trustworthy before changing architecture.

Deliverables:

- Introduce one serialized session controller for start/send/steer/follow-up/cancel/end admission
  before wiring individual controls. Every producer uses it: launcher/resume, composer, scheduler,
  peer messages, Claude follow-ups, notifications, and later service commands.
- Allocate stable session and Work IDs, new run ID, and command IDs before driver startup. Phase 0
  may keep session↔Work one-to-one, but it must not conflate their identities. Resume keeps session/
  Work IDs and creates a run ID; writer, payload log, runtime endpoint, and UI share them.
- Project in-house and Claude streaming deltas as typed ephemeral overlays with stable turn/message
  IDs. Reconcile success, cancellation, provider failure, and reload into one committed message—no
  synthetic transcript rows and no duplication.
- Wire the UI's follow-up control to the core follow-up queue; publish real queue contents.
- Show acknowledgement and delivery state for steering and queued messages.
- Replace **Abort** with capability-aware commands for cancel-model-stream and
  cancel-current-action. Separate **Detach view**, **End run**, **Archive session**, and
  **Move session to Trash**; reserve **Destroy Work** as a separately scoped destructive operation.
  Disable unsupported scopes instead of implying that current Python or subprocess work can be
  interrupted, and confirm only destructive scope.
- Add explicit preparing, idle, working, waiting, canceling, failed, and completed presentation
  states where current information permits.
- Preserve reader scroll position; show unread count and Jump to latest when detached from bottom.
- Remove or update stale Live/Cockpit/daemon/harness copy that describes behavior no longer present.
- Add adapter-level tests—not only `Agent` tests—for live delta projection, queue versus steer,
  cancellation, and reload parity.
- Close the rapid double-send race and derive enabled controls from controller state.
- Pass one `RunConfiguration` and stable session/Work/run identity end to end, including thinking,
  persistence, context injection, payload recording, and engine-specific capabilities.
- Remove or disable in-house `persistSession=false` until an ephemeral journal has explicit
  deletion, display, and crash semantics; forwarding an otherwise unsupported boolean is not a fix.
- Correct first-class rendering for the current `python` tool and verify child-agent model selection
  reaches the child runner instead of silently reverting to parent settings.
- Establish focus and announcement invariants now: streaming and replay do not steal keyboard focus;
  controls name their delivery/cancellation scope; expand/collapse relationships are semantic;
  state is not color-only; VoiceOver announcements are throttled to meaningful transitions.

Exit criteria:

- A checked control × engine × lifecycle × current-action contract table covers every enabled and
  unsupported command using deterministic event-sequence tests through the controller.
- A scripted long turn demonstrates live text, true queueing, true steering, supported cancellation
  request/ack, focus preservation, and identical durable history after reload.
- No control labeled cancel or stop destroys a broader scope than its label names.

### Phase 1 — make the linked timelines and reducers canonical

Goal: derive live, historical, and cross-session attachment views from linked versioned records.

Deliverables:

- Introduce a versioned `TimelineEvent` envelope with an explicit `JournalRef` (authority, journal
  kind, journal ID), session/work/work-host/client/client-attachment/run/turn/action/handle IDs,
  structured actor, `event_id`, `previous_event_id`, `caused_by_event_id`, `parent_activity_id`,
  per-journal monotonic sequence, host-recorded timestamp, schema and payload versions, declared
  affected domains, and a forward-compatible payload. Each session or Work journal has one
  host-side actor as its sole sequence allocator/writer; client clocks never order shared work.
- Keep the physical append chain separate from semantic conversation ancestry. Sequence and
  `previous_event_id` validate host journal order; explicit conversation-parent and tip-selection
  records choose the visible branch. Appending an action, label, or unknown event must not silently
  change the conversation tip.
- Use a globally unambiguous `WorkRef = {work_host_id, work_id}` at every client/service boundary;
  neither a local catalogue entry nor a bare Work ID may silently select a host.
- Keep `caused_by_event_id` and `parent_activity_id` as the simple primary edges, plus a bounded list
  of typed links (`derived_from`, `supports`, `contests`, `supersedes`, `retries`, `produced`,
  `verifies`) to events/artifacts/claims. This supplies many-to-many evidence semantics without a
  parallel graph store or prose inference.
- Record optional session ancestry separately: parent session ID, base turn/checkpoint, and fork
  reason. This preserves provenance without committing to an elaborate branch-management UI.
- Record user-input acceptance and its delivery mode, turn lifecycle, model activity, action intent
  and outcome, human decision requests, artifacts, child/handle lifecycle, compaction, recovery,
  and completion.
- Record session-attachment and client-attachment creation/detachment, observe/control capabilities,
  source session/client, durable cursor, and capability changes. Record every control command's
  causal cursor and host-assigned order. A lost connection changes connectivity, not ownership or
  other clients' control capability.
- Treat provider/model requests and Claude CLI execution as external-cost/data actions alongside
  Python, MCP, and child work; they are part of the audit denominator.
- Include the minimum fields required for honest semantic action/confirmation cards now:
  human-readable intent, actor, target/scope, lifecycle, decision request/response where present,
  result, and artifact links.
- Mark intent, expected effects, observed effects, reversibility, and result fields as declared,
  system-observed, inferred, or unknown, with observation coverage.
- Record terminal `failure_kind` and `retry_safety`; retries link to the prior action and must not
  infer safety from a generic failure state.
- Build pure `WorkReducer` and `SessionReducer` components in `AviaryCore`. `WorkReducer` consumes
  exactly one Work journal. `SessionReducer` consumes exactly one Session journal. A separate pure
  `SessionAssembler` composes a Session snapshot with attached Work snapshots at explicit cursors;
  it never invents a global timestamp order across journals. Cockpit/inbox, chat, menu bar, Flock,
  and historical views use those projections.
- Preserve streaming deltas as an explicitly ephemeral overlay until committed text lands; test
  that the overlay collapses into the same durable message.
- Migrate Aviary-owned JSONL state and fixtures into the canonical Session/Work journals, then
  remove superseded readers and UI interfaces rather than keeping a parallel compatibility model.
  Claude Code- and Codex-owned stores remain valuable and read-only; any importer first copies a
  bounded, provenance-bearing sample into Aviary-owned space and transforms only that copy.
  Forward-compatible canonical readers still preserve unknown events and their raw payload/position,
  expose an unterminated final record as an uncommitted tail, and quarantine unverifiable suffixes.
- Stop discarding writer errors. Define which record failures make execution terminal, which enter a
  clearly visible degraded/read-only state, and what synchronization boundary acknowledges durable
  intent before an Aviary-dispatched action.
- Latch journal failure in the session controller. Failure to commit intent prevents any subsequent
  Aviary-dispatched model, Python, MCP, process, or child action until durable recovery or explicit
  abandonment; no later controller command quietly resumes dispatched work.
- Add deterministic activity grouping and summaries; raw events remain available.
- Record context assembly and compaction as versioned artifacts: pinned instructions, selected
  history/context sources, summary boundary, summary content, and omissions/unknowns. Resume tests
  compare the effective context snapshot, not merely the visible transcript. Every included
  component has stable identity plus delivered byte/token size and cumulative inclusion metrics.
- Add sequence/cursor-based incremental reads so a renderer never reparses an entire growing file.
- Migrate every producer and consumer through the canonical snapshot or a documented adapter:
  Agent, Claude normalization, SessionResume, SessionCatalog, analytics, live watchers, scheduler,
  wire-log lookup, subagent ledger, AgentTree/Flock, menu bar, chat, and inbox.

Exit criteria:

- Live projection equals cold replay at randomized journal prefixes.
- Two sessions attached at the same Work cursor reduce to the same Work snapshot; session-local
  messages remain separate, and detaching one does not mutate the other or the Work journal.
- Many controlling clients issuing concurrent commands reduce to one deterministic host-accepted
  order with durable rejection/conflict outcomes and complete actor provenance.
- Old fixtures still parse, unknown-version fixtures remain inspectable, and corrupted tails fail
  locally rather than hiding earlier history.
- No listed producer or consumer maintains an undocumented interpretation of session state.
- Injected disk-full and permission failures cannot produce unrecorded continued dispatched work.
- Named old/new/truncated/unknown/disk-failure fixtures and fault-injection reachability assertions
  run under the recorded toolchain. A 100,000-event fixture meets the versioned latency/memory
  budget fixed from the pre-phase baseline using a published benchmark command.
- The Reader Census fixture below passes for every registered reader, with differences allowed only
  through checked-in declared projection rules.

### Phase 2 — unify the session workspace and attention model

Goal: ship the principal conversation improvement on top of truthful state without waiting for the
runtime/service program. Initially, in-process sessions remain labeled as such and do not claim to
survive relaunch.

Deliverables:

- Replace separate Live/Sessions navigation with the durable attention inbox and one session
  workspace. Preserve Flock as a useful multi-session/actor projection, not a separate ontology.
- Make **New Session** a selected inline card in that workspace. Before first send, choose/confirm
  Work Host, project or directory/worktree, engine/model, execution location, and available
  capabilities; advanced context and budget settings expand in place.
- Make Work Host the first environment choice; project/worktree/model pickers query that host rather
  than assuming the GUI device's filesystem or installed runtimes.
- Add **Attach Work** for authorized ongoing or completed Work by durable identity/recent-host list.
  Observation is the safe default; adding/removing this client's control capability, detaching,
  and continuing completed Work are distinct visible operations. Gaining control does not evict
  other authorized controllers.
- Aggregate local and remote Work in one inbox while preserving host identity, per-host connection
  health, and partial ordering; one unavailable host must not block the rest of the GUI.
- Record setup/preflight activities for executable resolution, directory/worktree readiness,
  authentication kind (never secret values), scrubbed environment availability, runtime
  capabilities, and failures. Preparing opens exact steps with repair/retry instead of a spinner.
- Apply a strict responsive hierarchy:
  - persistent: title/goal, primary attention state, conversation, and composer;
  - temporarily prominent: blocker/confirmation/current action;
  - secondary inspector: Work Host, environment, model, run identity, and provenance;
  - collapsible: historical actions, injected context, analytics, and raw records.
- Add a contextual Now/Why/Next activity strip only while it is useful. Why cites an actual
  instruction or plan step; Next says “unknown” when the runtime has not declared it.
- Add the editable pending-input tray and explicit delivery selector.
- Preserve durable drafts per session, restore focus safely, and add attachment/context previews.
- Make a goal/plan an optional first-class artifact with completion criteria and progress.
- Show two separate truthful projections:
  - **Next model context:** pinned instructions, selected history, context/compaction boundary,
    summary, attachments, omissions, component identities, and delivered sizes;
  - **Runtime working state:** cwd/environment identity, non-perturbing namespace metadata from
    `RuntimeHost.inspect`, pending Futures/Handles, relevant memories, and artifacts.
- Do not persist or display raw namespace `repr` by default; it can contain credentials or large
  values. Show names/types/sizes/provenance and reveal values only through an explicit bounded path.
- Show recovery coverage by state plane, so a live reattachment, cold resume, or reconstructed
  namespace cannot all collapse into the same “resumed” badge.
- Support an optional Work resource envelope for time, tokens/cost, action count, and parallelism;
  show remaining budget and durable rate-limit/backoff or limit-reached attention states.
- Keep injected context, raw payloads, protocol records, and aggregate analytics available but
  collapsed by default behind semantic labels. The initial viewport should privilege the human
  request, agent response, current activity, required decision, and result.
- Add deep-linked native notifications only for needs-you, failed recovery, and ready-for-review
  transitions that exist in the current capability set; coalesce noisy children under parents.
- Add session and action search, keyboard navigation, VoiceOver labels, reduced-motion behavior,
  contrast validation, and responsive narrow/wide layouts.
- Virtualize or page large histories with stable scroll anchors. Loading older history must not move
  the content under the reader.

Exit criteria:

- A person can start, converse, steer/queue, leave, resume from the inbox, and review evidence
  without switching conceptual products.
- A second session/GUI can attach to and control ongoing Work alongside existing controllers, and
  can attach to completed Work as immutable evidence or create an explicitly linked continuation.
- The UI states its current in-process survival limit rather than implying automatic recovery.
- No state requires reading raw logs to know whether attention is needed.
- Accessibility Inspector plus keyboard/VoiceOver UI tests cover every control and transition.
  In moderated tasks, at least 90% of primary start/send/queue/steer/review/continue tasks succeed,
  with zero misinterpretations of destructive scope; record sample and failures rather than hiding
  them behind a binary “passes.”

### Phase 3 — separate the durable Work Host from disposable clients

Goal: make GUI relaunch, network loss, device change, and Work Host recovery explicit states rather
than ownership or data-loss events. Build the local path through a transport-neutral boundary so
remote execution is enabling work, not a second architecture.

Deliverables:

- Gate the process split already shaped in `plans/process-split.md` as three independently verified
  stages:
  - **3A, adoptable kernel:** move each runtime host to an authenticated/permissioned Unix-domain
    socket and test stale sockets, process identity, protocol skew, and reconnect;
  - **3B, local Work Host:** move ownership of Agent/AgentRunner, Work/Session writers, runtime
    connections, Claude child, MCP bridge/clients, schedules, and background children to a minimal
    `aviaryd` service;
  - **3C, remote-ready client boundary:** require every GUI read/control path to go through a
    transport-neutral `WorkServiceClient` contract. Ship local Unix-socket transport first and a
    non-file loopback conformance transport; add real remote transport/host discovery later.
- Keep journals canonical and host-side. The read protocol pages snapshots/events by durable cursor
  and fetches artifacts; it is not a lossy live-event bus. A same-host file reader may remain an
  optimization behind the same interface, never a GUI assumption.
- Give the logical protocol a small device-independent surface: list/describe Work, attach/detach,
  update this client's observe/control capability, snapshot/events-after-cursor, fetch artifact,
  start/send/steer/queue, hold, supported cancellation, and explicit end/destroy commands.
- Persist Work/session/run registry, stable Work Host identity, runtime endpoint, process start
  identity, protocol version, environment provenance, session/client attachments, command actor and
  causal cursor, and durable read cursors. PID is diagnostic, not ownership.
- Automatically reattach on launch or reconnect; distinguish client detached, network disconnected,
  Work alive, Work Host recovering, dead-with-complete-record, indeterminate, and orphaned.
- Add command IDs and idempotent acknowledgement for the commands that exist at this phase: send,
  steer, queue, hold-after-boundary, supported cancellation, detach, and end-run. Journal acceptance
  before execution and version the protocol so confirmation/retry commands can arrive later.
- Define GUI/Work-Host/runtime version negotiation and a drain/restart policy for incompatible
  hosts. Never migrate live Work across a version boundary implicitly.
- Make window close, GUI quit, application relaunch, network loss, and client-device sleep detach
  events only. Work continues under host-side lifetime/resource policy until an explicit durable
  terminate command or policy deadline.
- Keep model credentials, repository credentials, environment secrets, and unrestricted runtime
  access on the Work Host. Remote attachment exposes only the protocol's declared metadata,
  journal, and artifact surfaces.
- Add repair UX: reattach, inspect, retry from a proven safe boundary, mark abandoned, or fork the
  durable conversation with explicit environment/checkpoint coverage. An indeterminate external
  effect requires acknowledgement and a duplicate-effect warning; never silently restart it.
- Every repair option previews and then records `RecoveryCoverage` for timeline, effective context,
  runtime namespace, background Work, memory/artifact/repository state, and external effects.

Exit criteria:

- A fault matrix kills the GUI, runtime host, Work Host, and network connection during model
  streaming, action execution, user/decision wait where currently produced, compaction, and queued
  delivery.
- After restart, every accepted input and action has exactly one known outcome or one explicit
  indeterminate-effect/orphaned state; none disappear or silently run twice.
- At every injected kill point, tests assert unique command/event cardinality, last durable cursor,
  process identity, and the exact recovered facets shown in the inbox/workspace.
- Killing every attached GUI leaves every 3B-owned process alive by process-tree assertion, not
  merely a restored registry row; stage 3A alone does not claim GUI disposability.
- Two independent clients attach to the same ongoing Work, reconstruct the same Work snapshot from
  different cursors, and control it concurrently. The Work Host produces one durable command order;
  closing any client neither terminates Work nor changes other clients' capabilities.
- A new session attaches to completed Work after the originating session is archived and retrieves
  the same immutable outcome/artifacts.
- Protocol conformance tests inject delay, loss, reconnect, duplicate delivery, out-of-order client
  clocks, stale causal cursors, and conflicting concurrent commands without losing or
  double-executing accepted commands.
- No remote-ready GUI path requires a Work Host filesystem path or PID. Reattachment target is under
  2 seconds on typical local Work, subject to baseline revision.

### Phase 4 — action transparency, confirmations, changes, and review

Goal: make actions comprehensible, reviewable, and recoverable while preserving the full-capability
Python model. This is an observability and human-control program, not a sandbox program.

Deliverables:

- Gate this program in order: **4A typed action instrumentation and optional confirmations**, then
  **4B change/review and checkpoint UX**.
- Define typed action kinds for provider/model request, Claude CLI, shell/process, file change,
  network/HTTP, MCP, browser/UI, dispatched/background work, subagent, and artifact production.
- Maintain an explicit boundary table for each operation: intercepted, observed only, or out of
  scope. Instrument helper-mediated actions with intent, optional confirmation, start, observed
  effects, and terminal outcome; do not imply that direct Python effects were intercepted.
- Where a workflow deliberately asks the human to confirm a costly or hard-to-reverse action, show
  target, expected effects, data leaving the machine, reversibility, and duration. Support
  deny-with-reason or a constrained/edited action without turning this into a universal permission
  system.
- Provide an integrated change/review surface: per-turn and session diff, file list, inline feedback,
  stage/revert/commit hooks where appropriate, and a revision loop back to the agent.
- Record base hashes/revisions, attribute observed external edits where possible, and check drift
  before writes/restores. Concurrent human or agent changes enter an explicit conflict state;
  restore never silently clobbers manual edits.
- Add checkpoints that can independently cover conversation position, Aviary-owned file changes,
  repository state, and artifacts. List uncaptured external effects before restore.
- State the execution posture plainly: **trusted, full-capability runtime**. Do not add classifier
  approvals, allowlist theater, or trust-mode chrome without a concrete threat and validation plan.

Exit criteria:

- Every instrumented action opens to recorded input/output, provenance, effect summary, confirmation
  decision where present, and checkpoint coverage; unavailable or unobserved fields are labeled.
- Restore UX distinguishes reversible local state from irreversible or unobserved external effects.
- The shipped boundary table matches integration tests; no observed-only or direct-Python action is
  presented as intercepted or contained.

### Phase 5 — durable handles and multi-agent attention

Goal: make background and delegated work survive the initiating turn without becoming an attention
tax.

Decision gate: renew design approval of the central Handle/ownership semantics after Phases 1–4 produce
real event, recovery, and attention evidence. The existing Handle plan is valuable shaping, not
pre-authorized implementation of a global scheduler.

Deliverables:

- Implement the Handle/ownership model in `plans/handles-and-ownership.md` with explicit lifetime:
  turn-, run-, Work-, or durable-owned. Session attachment is not lifetime ownership.
- Move handle state to the Work Host, not the GUI process, originating session, or an `AgentRunner`
  child map.
- Make queued work distinct from started work; derive time from one monotonic clock and persisted
  state.
- Write terminal events even when no GUI is open. Reattach results to authorized attached sessions
  by durable cursor/reference rather than copying ownership to the first consumer.
- Support observe-many and control-many. The Work Host serializes accepted commands, not controller
  ownership; every outcome retains client/session provenance. A Handle/Work ID is stable identity,
  while remote authorization is checked separately by the Work Host.
- Nest child agents/actions in the parent activity story while retaining Flock's cross-session
  overview. Show lineage, goal, Now/Why/Next, result, cost/usage where known, and individual control.
- Make session completion enforce awaited-handle terminality; define reaping rules for session
  destruction and machine restart.

Exit criteria:

- Stopping a run, detaching a GUI, or archiving/deleting the originating conversation does not kill
  Work. Explicit Work destruction or host-side lifetime policy reaps it, with a durable event.
- Child results arrive once after automatic reattachment, including across UI and host restart.
- Another authorized session can attach to a running or terminal handle and observe the same
  write-once result without changing the source session or consuming the result.
- Fifty active child actors remain performant and notification-coalesced. Set comprehension targets
  from observed one-to-five and higher-fan-out workloads rather than optimizing the primary UI for
  an arbitrary fleet-demo count.
- In recorded representative workloads, users find the sole blocking child and its required action
  within the task threshold set before implementation; the test records notification count and
  misidentification rate as well as time.

### Phase 6 — lead with the flight recorder and evidence graph

Goal: build advantages that follow naturally from Aviary's architecture instead of copying every
peer feature.

Deliverables:

- **Observer lane:** ask read-only status or “why?” questions against the composed session + attached
  Work snapshots without interrupting the agent, invoking tools, or adding noise to the main
  conversation. A useful answer can be cited or promoted into the session deliberately.
- **Evidence graph:** connect goal criteria and final claims to actions, tests, artifacts, diffs,
  commits, screenshots, and unresolved gaps. Make “known,” “reported,” “inferred,” and “unobserved”
  explicit. Build it from the bounded typed timeline links rather than inferring relationships from
  prose or creating a parallel source of truth.
- Represent auditable completion claims as identified records with receipt links. Ordinary prose
  that has not been promoted into a claim record remains visibly unaudited; “every claim” refers to
  this explicit denominator, not subjective sentence extraction.
- **Forensic recovery:** show the last safe boundary, last committed effect, active process/handle
  inventory, and exact options after a crash.
- **Coverage-aware checkpoints:** make the captured versus uncaptured world visible before rewind,
  rather than presenting time travel as magic.
- **Natural-language session search:** answer what changed, what was validated, why a decision was
  made, and which action produced an artifact—with links to the exact timeline facts.
- Instrument demand for conversation branching and deterministic replay before prioritizing them.
  Existing history shows resume/recovery is the immediate need; elaborate branch UI is not yet
  justified.

Exit criteria:

- Observer questions cite durable facts and leave session and attached-Work journal cursors/hashes
  unchanged; they issue no tools, writes, control requests, or Work commands.
- Every identified completion claim opens its evidence graph or is labeled unsupported; ordinary
  prose is never silently counted as verified.
- Recovery choices explain possible duplicated/external effects before the person commits.

## Verification program

Reliability must be a product program, not a final test pass.

Before any phase claims green, self-check the supported Swift/Xcode/SDK combination and writable
module-cache path, run it in CI, and publish the exact verification command plus artifact. The
checked-in probe now demonstrates that the installed Swift 6.3.3 compiler accepts the macOS 6.3.2
SDK, and `just test` passes through the repository-owned module cache; this compatibility check is
the gate, rather than an exact-version equality rule. Every benchmark records hardware, toolchain,
fixture, command, latency, and memory budget so an exit criterion is reproducible rather than
adjectival.

### Deterministic model tests

- Property-test all legal and illegal session/action/handle state transitions.
- Fuzz old, new, truncated, duplicated, reordered, and unknown timeline records.
- Assert live-overlay-to-durable-message convergence and live-versus-replay equivalence.
- Assert non-vacuity: every fault injection point is reached and every expected terminal state is
  observed.

### Reader Census

Maintain one adversarial fixture directory: a manifest, linked Session and Work journals, a legacy
journal, and retained body/artifact fixtures. It contains a branch with explicit tip, unknown event
with declared affected domains, incomplete tool call, compaction, model change, queued input, child
completion, late steering, indeterminate action, two clients' concurrent commands in host order,
attachments, malformed interior suffix, and truncated tail. Run every reader against it, including
randomized incremental byte chunks and journal prefixes:

- live and cold reducers;
- resume and next-model-context assembler;
- SessionCatalog/inbox;
- AgentTree/Flock;
- notifications and search;
- WorkService snapshot/events recovery when that consumer lands.

Each reports each journal's committed tip/cursor/integrity, visible conversation, effective model
context component/inclusion identities and omissions, runtime-state coverage, attention requirement,
outstanding commands/actions/Handles, model/run identity, attachment/client state/capabilities, and
unknown record references. Differences are allowed only through explicit checked-in versioned
projection rules; a new reader must join the census before shipping.

### Fault and recovery matrix

Inject death or disconnection:

- before and after input acceptance;
- during provider streaming;
- before action intent, after intent/before effect, during effect, and after effect/before outcome;
- while waiting for confirmation or user input;
- while steering, queueing, canceling, compacting, or attaching a child result;
- during GUI, runtime-host, Work-Host, network, client-device, and host-machine restart;
- while a command acknowledgement or event page is delayed, duplicated, or lost.

For each case, assert message cardinality, action cardinality, durable cursor, visible state,
available controls, and whether retry could repeat an external effect.

### Interaction contract tests

Use the real adapter/view-model path for:

- queue, reorder, edit, delete, steer, send-now, supported cancel scopes, hold-after-boundary,
  end-run, detach, add/remove this client's control capability, archive session, destroy Work,
  resume, and recover;
- attach a second session/client to ongoing Work; close the originating GUI; attach to the completed
  Work after the originating session is archived; create a linked continuation;
- issue concurrent queue/steer/cancel commands from multiple controlling GUIs and verify accepted
  order, visible conflicts/rejections, actor provenance, and consistent projections;
- scroll anchoring during streaming and history pagination;
- Needs you and Ready for review transitions plus deep-linked notification routing;
- optional confirmation and denial/constrained-action feedback;
- parent/child attention coalescing;
- diff comment and agent revision loop.

### Performance and scale

Establish baselines before freezing SLOs. Provisional targets:

- provider delta appears within 100 ms of receipt at p95;
- cached session switch under 100 ms p95 and local cold open under 500 ms p95;
- automatic local reattachment under 2 seconds p95;
- no typing or scroll hitch visible at 60 Hz during background updates;
- usable history at 100,000 events, 12+ MB journals, 20 simultaneous sessions, and 50 child actors;
- one GUI remains responsive while aggregating Work from multiple hosts with one slow/unavailable;
- bounded memory through incremental parsing, caching, and virtualization.

### Accessibility and comprehension

- Full keyboard route through session inbox, chat, pending input, actions, confirmations, and review.
- VoiceOver announces state transitions without narrating every token or tool event.
- Status never depends on color alone; reduced motion and large text retain hierarchy.
- Streaming, queue edits, cancellation, errors, and reload preserve focus and semantic
  expand/collapse relationships.
- Moderated tests ask users to identify Now/Why/Next, pending delivery mode, affected resources,
  recovery risk, and completion evidence without opening raw JSON.

### Peer workflow benchmark

Quarterly, run the same scripted workflow in Aviary and selected current peers:

1. Start a scoped repository task and review/adjust its plan.
2. Steer once, queue once, cancel once, then resume.
3. Leave the app during a long action and return from a needs-you notification.
4. Review changes, test receipts, child-agent work, and an external action.
5. Kill the UI and runtime at injected points; recover without loss or duplication.
6. Explain why a final claim is trustworthy from the durable record.
7. Attach a second session/client to ongoing and completed Work; verify detachment, control, and
   continuation semantics without copying or mutating the source record.
8. Control one Work concurrently from two GUIs and one GUI's local plus several remote Work items;
   verify deterministic host ordering and independent host failure.

Compare correctness and comprehension before click counts. Public documentation establishes claimed
capability; hands-on testing establishes quality.

## Sequencing and team shape

The critical dependency chain is:

`truthful controls → canonical journals/reducers → unified workspace → durable Work Host → action transparency/review → durable handles → advanced evidence/search`

Parallel work is safe only where contracts are already fixed:

- Phase 0 UI fixes and a Phase 1 event-schema prototype can proceed together behind fixtures.
- Once `SessionSnapshot` stabilizes, workspace UX, long-history rendering, and notification design
  can fan out.
- Action-card visual design can proceed against fixtures while instrumentation is built, but
  observation coverage cannot be overstated.
- Handle UI can use fixtures early; ownership must remain behind the durable runtime gate.

Every phase should have one independent seam review that follows a fact from producer through
journal, reducer, UI, restart, and user control. A green component test is insufficient if the
visible promise is wired to the wrong operation.

## Decisions to hold until evidence exists

- Do not build conversation branching or deterministic replay as a headline feature before recovery
  is proven and usage data shows demand.
- Do not unify all engines by erasing capability differences. Use one product vocabulary and expose
  engine-specific support truthfully.
- Do not replace JSONL merely for fashion. Add an index/cache if scale requires it while retaining
  an append-only transferable source record.
- Do not put all action detail inline. Progressive disclosure and stable summaries are part of the
  reliability experience.
- Do not treat worktrees as full isolation; databases, ports, credentials, networks, and vendor APIs
  remain shared unless separately controlled.
- Do not build comprehensive agent sandboxing, restrictive allowlists, or generalized permission
  policy without evidence of an actual requirement. Prefer capability, transparency, recovery, and
  evidence. Authentication/encryption for a remote GUI-to-Work-Host connection is a separate
  endpoint-access requirement, not agent containment.
- Defer automatic strategy epochs, semantic garbage collection, speculative namespace branches,
  and durable semantic “offices.” Instrument stable identities, typed links, context carriage,
  attachment patterns, and recovery coverage so evidence can justify them later.
- Do not call a checkpoint complete if it omits shell side effects, manual edits, databases, remote
  services, or other external state.
- Do not preserve compatibility merely because Aviary generated an older local format. Aviary-owned
  transcripts, artifacts, caches, and fixtures are disposable development state: migrate or replace
  them and delete superseded interfaces. Claude Code- and Codex-owned data is valuable/read-only;
  copy it into Aviary-owned space with source provenance before using it as mutable test/import data.

## Initial implementation slices

The first four shippable slices should be deliberately narrow:

1. **Truthful composer and live transcript** — live deltas, real steer/queue, capability-gated
   cancellation, queue tray, scroll anchoring, and adapter tests.
2. **Timeline v2 and linked reducers** — session + Work identities/journals, durable action/turn/
   attachment state, old-record adapter, live/replay equivalence, incremental cursor.
3. **One conversation workspace** — attention inbox, responsive session view, honest in-process
   capability labels, semantic activity, drafts, and stable scroll/focus.
4. **Relaunch without fear** — adoptable runtime, local Work Host, transport-neutral client,
   automatic cross-session attachment, command idempotency, and the kill/recovery matrix.

Only after those slices are green should the product add richer action instrumentation, review, or
multi-agent surfaces. That order delivers the central UX earlier without letting polished UI
launder ambiguous state.

## Research references

Product behavior changes quickly; these links were checked during this plan's 2026-08-31 research
pass and should be revalidated before implementation decisions based on a specific peer feature.

- OpenAI: [long-running work](https://learn.chatgpt.com/docs/long-running-work),
  [code review](https://learn.chatgpt.com/docs/code-review), and
  [projects](https://learn.chatgpt.com/docs/projects)
- Anthropic: [Claude Code desktop](https://code.claude.com/docs/en/desktop),
  [checkpointing](https://code.claude.com/docs/en/checkpointing), and
  [permission modes](https://code.claude.com/docs/en/permission-modes)
- Cursor: [agent overview](https://cursor.com/docs/agent/overview) and
  [run modes](https://prod.cursor.com/docs/agent/security/run-modes)
- Devin: [Agent Command Center](https://docs.devin.ai/desktop/agent-command-center),
  [Cascade](https://docs.devin.ai/desktop/cascade/cascade), and
  [long-session renderer engineering](https://devin.ai/blog/rebuilding-devins-chat-renderer)
- GitHub: [manage and track Copilot coding-agent sessions](https://docs.github.com/en/copilot/how-tos/copilot-on-github/use-copilot-agents/manage-and-track-agents)
- Google: [Antigravity artifacts](https://antigravity.google/docs/artifacts) and
  [Jules activities API](https://jules.google/docs/api/reference/activities/)
