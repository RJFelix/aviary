# Aviary core experience: durable sessions, truthful actions, and calm control

Status: implementation in progress; Phase 0/1 foundations and the Phase 3A–3C durable Work Host checkpoint are implemented; exact Work/Session continuation, production service/control-reader cutover, Session-qualified Run routing, and GUI new-Session-to-existing-Work composition have completed integrated macOS/Linux/cross-device verification; the first Phase 2 canonical workspace, explicit input-delivery, dual context/working-state inspector, paged service-backed conversation history, Phase 4A Action Lens, and Phase 4B observed-repository-review slices are implemented
Date: 2026-09-06
Scope: human-agent sessions, chat, action understanding/control, local/remote Work ownership, recovery, review, and multi-agent attention

Product steering, 2026-09-07: Ryan's first real signed-app journey exposed a startup failure,
lost pre-launch prompt, overlapping navigation, and machinery-first vocabulary. Further
checkpoint/restore expansion is paused for the [chat-first experience reset](chat-first-experience.md).
Its acceptance bar is the real user journey, not only component tests or design fixtures.

Transactional projection foundation (2026-09-04): the first Darwin/Linux disposable projection
store now publishes a checksummed, generation-fenced `HEAD` only after its content-addressed bucket,
recent-page, reducer-head, and deterministic sealed-bucket-reference objects cross the store's
durability boundary. The independently content-addressed exact-state radix nodes are deliberately
rebuildable cache material: they use private no-follow writes and atomic installation but do not
issue an `fsync` for every immutable node or directory entry. If a crash loses one, validation
rejects the `HEAD` and rebuilds from canonical JSONL; the cache never becomes durable authority.
Every
load requires a fresh canonical source observation; the production bootstrap seam supplies the
checksummed stored boundary and exact indexed terminal row to a synchronous source validator rather
than exposing an unvalidated cache header. Journal/source generation, cursor, byte range, canonical
event-line digest, prefix hash chain, recent event bodies, seek anchors, and exact pending read-
acknowledgement requests are mutually checked. A partial bucket can only extend or seal its exact
predecessor, nonzero prefix seeds cannot skip buckets, same-tip metadata commits remain possible,
and ordinary reads/commits stay constant-work even when historical anchors are retained. Replaced
bounded payloads are reclaimed after publication; crash or unlink-failure orphans remain harmless,
while total namespace quota/semantic garbage collection remains explicitly deferred policy rather
than a claimed hard disk bound.

The local source lease, typed bounded Work/Session heads, shared one-event reducer transitions,
copy-on-write radix map, and exact persistent Work and Session reducer roots are now implemented on
both platform source lists. The production local projection reader publishes each bounded head and
exact root atomically, authenticates the retained prefix separately, validates the root before
reuse, and continues stateful Work and Session semantics across reopen. Session growth decodes and
applies only the append-only suffix to both exact and bounded presentation state. Work growth applies
only the suffix to its exact reducer root, but still streams from byte zero to rebuild and authenticate
the bounded index/query head; it therefore does not yet satisfy the stronger no-byte-zero normal-read
goal below. The lease distinguishes strict unchanged-source proof from an explicit
cooperating-writer append contract held under the canonical owner lock; it does not claim to detect
an arbitrary external middle rewrite followed by an append. Typed heads separate controlling
scalar truth from per-index completeness, retain active/unsettled rows before historical rows, and
keep raw messages, payloads, error reasons, prompt labels, and unhashed identity keys out of
persisted metadata.

The production service/control verification path now consumes those projections for cold sources
and uses an actor-serialized canonical observation while a Hosted run owns open writers. A bounded
head is never fed back into the canonical reducer as though it were an exact checkpoint. The
control journal still reads the small immutable registration prefix needed to prove the exact
published Work/Session relationship; that is bounded identity evidence, not a lifetime semantic
scan. Disposable cache damage triggers a strict rebuild and does not relax source, cursor, owner,
unknown-event, corruption, or tail checks. Exact suffix continuation remains dependent on
cooperating canonical writers and the authenticated persistent root; absence or mismatch fails
closed instead of manufacturing a partial projection.

Live actor reads also remain addressable after their one-million-record resident-envelope limit.
The locked scan retains a path-free file identity, bounded genesis prefix, sparse byte anchors,
prefix-digest chain, reducer state, and exact terminal/run evidence; raw resident events may then
be dropped without making the Work unavailable. Service pages reopen the exact fenced inode and
stream from the nearest authenticated anchor. A reduced-limit end-to-end fixture forces this path
after two records and proves first-page/continuation correlation plus alternating Session ownership.

The first-class service operation for creating a new Session attached to existing active or
terminal Work is implemented with independent Session identity, a paired Work mirror where the Work
is mutable, client-qualified attachment/capability records, a two-record durable control
reservation/result, exact retry after restart, detach/revocation, bounded relationship counts, and
transport correlation. Duplicate reconciliation preserves the immutable creation relationship but
uses the current attachment row and capabilities when that attachment still exists; a detached
historical attachment is evidence only and cannot regain authority. The GUI exposes both explicit
new-Session-on-existing-Work and attach-another-client-to-an-existing-Session paths.

Executable routing is now Session-qualified. Each active Run records the exact Session and
Session-attachment owner; multiple GUI clients attached to that same Session may control it, while
a different Session may observe but cannot write conversation or command events. After explicit End
has reached both the Hosted ended/closed boundary and canonical Work has cleared its active Run, a
later replacement may select any canonically attached Session. Alternating Session A→B→A across a
service restart preserves Work identity, changes only the explicit Run owner tuple, and launches
fresh model context for the newly selected Session unless an exact same-Session cold-resume proof
exists. End acknowledgement and actor teardown remain deliberately distinct observable boundaries;
replacement does not race an accepted receipt as though it proved teardown was complete.

Phase 2/4A visible-experience checkpoint (2026-09-05): Cockpit now projects the bounded canonical
attention inventory instead of treating this GUI's live objects as the workspace. NEEDS YOU, local
attachments, working, ready-for-review, and other rows remain authority-qualified by Work Host,
Work, Session journal, and exact attachment. A selected row opens the conversation and composer in
place; multi-Work Sessions keep an explicit relationship selector; Attach/Inspect remains a
distinct capability-checked operation. Transcript pages are prepared once per canonical cursor
under count and byte bounds, missing canonical time renders as unknown, row-local corruption does
not erase unrelated healthy Work, and every bounded omission is stated in the primary experience.

The same conversation surface now has a canonical Now/Why/Next Action Lens. All typed action kinds
share one privacy-safe presentation with host timing, state, bounded intent/target/scope, failure
kind, retry safety, provenance, source event, and typed evidence links. Unsettled actions outrank
resolved history at the projection cap; concurrent current actions remain selectable; an open
sheet resolves the latest canonical state instead of freezing a stale copy. The boundary text says
plainly that Python is a trusted full-capability runtime whose direct file/process/socket/network
effects may be unobserved and are not contained by hooks. Evidence omission counts are bounded at
in-process constructors and validated at native draft/writer, decode, journal, local projection,
Work Host control, and transport crossings; saturated counts render as lower bounds rather than
false exact values.

Unsent text belongs to the exact attached `LiveRun`, so navigation and detach/reattach do not
destroy a draft. Service-backed drafts now also survive GUI process relaunch in a private,
attachment-qualified store: filenames reveal only a digest; records and directories enforce owner
and mode; reads are bounded and row-local; explicit edits may repair disposable malformed records;
symlinks and insecure files fail closed. Typing persists through a serialized off-main-actor
debounce, accepted delivery clears immediately, and normal quit/reload flushes the latest value
before disconnecting from the Work Host. A nonempty flush failure cancels quit/reload before any
Work teardown, restores editing, and remains visible beside the composer rather than silently
claiming durability. Composer submission first persists an exact command-id/kind/body-digest
handoff marker; an accepted/delivered canonical command or correlated receipt clears only the
submitted bytes, a rejected/not-delivered/stale command returns them to the composer, and absent or
indeterminate evidence blocks resubmission until another exact read or an explicit “Return to
composer” decision. Every store mutation uses a generation compare-and-swap, so a stale GUI process
cannot overwrite an existing newer process draft for the same durable client attachment. A retained
bootstrap Start also blocks any newer Start: only its exact command ID and prompt bytes may cross
until canonical evidence resolves it. Retry, abandon, explicit return-to-composer, polling
resolution, and direct/automatic Start all share the same operation barrier as composer commands,
so marker mutation is exclusive in both interleaving orders and quit waits for the owner. Quit
freezes new admission, joins commands already crossing the Work Host boundary, settles their
marker, then flushes and disconnects without synthesizing `End`. Process-owned engines retain only
the in-memory behavior because their Work does not yet survive this GUI process.

The current generation token deliberately scopes its cross-process guarantee to existing rows.
Absent-row creation/deletion is not yet linearizable: a durable per-key tombstone/watermark would be
needed to prevent an absent-row ABA across simultaneous GUI processes. Such an ABA can at worst
resurrect GUI-owned draft text; it cannot mutate canonical Work or automatically resubmit a command.
Likewise, the bounded 32-row store still needs an explicit enumerate/prune repair surface before
orphaned drafts from permanently removed attachments can be reclaimed. Both are instrumented,
bounded residuals rather than claims hidden behind “draft saved.”

The snapshot harness now has three explicit deterministic design-fixture routes: a populated
multi-Work Cockpit, a wide service-backed conversation with Action Lens and unresolved durable
draft handoff, and a 520-point narrow conversation with a compact action summary. Their current
composited captures are `cockpit-fixture.png` (1600x1032), `service-chat-fixture.png` (1600x1032),
and `service-chat-narrow-fixture.png` (520x932); the extra 32 pixels are the captured native window
title bar, and repeated narrow renders are byte-identical. These are useful visual-design fixtures,
not production-path certification: they deliberately use in-memory presentation values and cannot
prove `CockpitView` selection, `RunPane` synchronization, canonical queue delivery, notification
routing, or persistence wiring. At least one populated route through the production view/model path
was therefore still required; the production routes below close that rendering gap without upgrading
the fixtures into transport evidence. Focused verification covers action
presentation (4 cases / 247 assertions), attention projection (10 / 441), controller bounds
(1 / 16), evidence-link journal decoding (1 / 17), writer propagation/validation (2 / 28),
transport page bounds (1 / 20), and service-backed draft storage/relaunch/tamper behavior
(12 / 193), plus pure GUI command-pairing/barrier behavior (7 / 69 across the GUI-orchestration
suite). Core, SelfTest, and GUI targets build. A subsequent uninterrupted broad run completed
950 cases / 13,420 assertions in 378.69 seconds; the earlier apparent Phase 1 bridge “hang” was the
suite's long quiet service phase, not a deadlock, so no speculative synchronization was added.

Input-delivery experience checkpoint (2026-09-06): the canonical Work command ledger and Session
message projection now retain the typed command kind, runtime crossing mode, accepting Run, client,
Session attachment, and exact cross-journal cause needed to answer whether a human input was merely
accepted, delivered, proven not delivered, or left with unknown effect. The bounded pure join rejects
foreign journals, duplicate identities, wrong client/attachment/Run tuples, and malformed delivery
evidence; a crash between Work acceptance and Session append remains visible as a metadata-only
host-owned row. Incomplete sources downgrade unresolved acceptance rather than creating a false
pending or retry-safe claim. Persistent Session exact state retains the join metadata privately across
reopen without retaining message bodies.

The production conversation renders these states on the exact user row, and its host-owned pending
and uncertain tray is distinct from the GUI draft, draft-handoff marker, transport mutation, and
process-local steering/follow-up lists. Host-owned rows are inspection-only until a real queue-mutation
protocol exists; the GUI does not fake edit/delete/reorder. While Work is active the composer has one
labeled primary action and a capability-derived delivery selector for “Steer next” versus “Queue
follow-up”; cancellation remains separate. Narrow layouts use compact but labeled lifecycle controls,
keep delivery Review reachable without the inspector, and no longer let the Action Lens consume the
conversation's vertical space.

Two additional deterministic routes, `production-delivery-fixture` and
`production-delivery-narrow-fixture`, render the actual `RunPane`, `TranscriptRow`, Action Lens,
pending tray, inspector, and composer hierarchy at 1600×1000 and 520×900 content sizes. They close
the production-view pixel-path gap above while still injecting deterministic presentation state; they
do not certify that transport or persistence produced that state. Current focused receipts are the
canonical join (2 cases / 61 assertions), native queued cancellation outcome (1 / 16), persistent
Session join metadata across reopen (1 / 7), and attached controller reconstruction/recovery
(29 / 228), plus Work service client ownership (5 / 24) and transport correlation (27 / 335).
The production fixture renders are byte-stable on repetition and were visually inspected at both
widths. Core, SelfTest, GUI, daemon, and signed release-app assembly pass. Final independent review
found no remaining P0/P1/P2 issue in this slice, including after an adversarial 64-category omission
mutant proved that locally derived input-attention disclosures cannot be crowded out by upstream
diagnostics. The uninterrupted broad run passes 953 cases / 13,492 assertions in 377.45 seconds.

Context/working-state inspector checkpoint (2026-09-06): the service-backed Run inspector now
separates the last canonical provider-bound context crossing from the durable Work/Session state at
the controller's exact cursors. The context card reports measured and cumulative delivery bytes,
component/source counts, producer-side source status, body addressability, compaction presence, and
bounded omissions without copying prompt text, source labels/paths, omission prose, or compaction
content. It explicitly says the next request has not yet been assembled. The working-state card
reports lifecycle/execution, cursor positions, active Run/Turn presence, bounded action/Handle/child/
artifact counts, independent artifact/attachment index completeness, and the six-plane recovery
matrix. Artifact rows expose fixed media categories and addressability only; aggregate omissions and
per-row truncation flags both make metadata loss visible without double-counting. Malformed artifact
records make the index explicitly unknown, and duplicate artifact identities within the retained
window make describe/fetch fail closed rather than selecting an arbitrary row. An omitted artifact
window explicitly lacks whole-history identity proof; fetching any selected identity scans the
canonical source and rejects duplicates even outside that window. Remote Python namespace inspection
is currently an
explicit `not_exposed` state rather than an empty namespace or a claim that conversation recovery
reconstructed memory. Invalid or source-incomplete projections retain only identity/cursor/source
status and suppress derived lifecycle, model, action, Handle, artifact, recovery, and namespace facts.

Reader Census and the production GUI now consume this one metadata-only Core projection; the older
parallel Census context interface was removed instead of retained as a compatibility surface.
Provider wire logs remain available as an explicitly inferred diagnostic view and no longer claim
canonical source provenance or that unrecorded context was “stored nowhere.” Recovery evidence is
bounded fairly across Work and Session journals, keeping the current Run and newest claims from each
source. Compaction is reported only when it was part of the exact recorded provider crossing, never
from a newer independent Session summary. Focused coverage is 2 cases / 108 assertions plus the
20-case / 232-assertion prompt-provenance suite, 18-case / 350-assertion Reader Census suite,
20-case / 385-assertion service suite, 27-case / 338-assertion transport suite, and a real
journal-backed artifact loss/reopen fixture at 1 case / 22 assertions. The actual production RunPane
and inspector have deterministic desktop and narrow fixture routes; narrow layouts reach the dual
inspector through a compact sheet button and Option-Command-I instead of consuming conversation
height. The final wide, narrow-chat, and narrow-inspector render hashes are recorded in the working
receipts and were visually inspected cleanly. Final independent review found no remaining P0/P1/P2
defect after the malformed artifact producer/DTO/transport boundaries were aligned. The
uninterrupted integrated run passes 956 cases / 13,640 assertions in 389.43 seconds; `just compile`
and signed release-app assembly pass. The release fixture hashes are `ac797b96dc3e...06a6`,
`0f44c6a28e40...9845`, and `4628581ac791...5fe1` respectively, identical across rerenders.

Conversation-history paging checkpoint (2026-09-06): Work service protocol v3 adds an
observe-authorized reverse Session-history operation with an exclusive message cursor, frozen
physical journal tip and prefix digest, selected-branch identity, bounded canonical event envelopes,
and a response-local evidence digest recomputable from exactly the delivered rows. Physical control
events and off-branch messages are never relabeled as conversation. Appends after the frozen tip are
safe; replacement, truncation, branch mismatch, foreign identities, forged boundaries/digests,
oversized first events, and incomplete sources fail closed. Pre-v3 daemons fail the handshake rather
than accepting a GUI operation they cannot decode.

Each attached GUI owns an independent 768-message/512-KiB presentation window. Loading earlier rows
does not advance canonical reducer cursors, read acknowledgements, control cursors, or Work commands;
another GUI can remain at the latest window. Duplicate top triggers admit one read, a refresh racing
the suspended page retains the reader's frozen rows and marks newer output, explicit Return to latest
supersedes a late success or failure, and every rejected page leaves authenticated rows intact for an
explicit retry. Branch replacement preserves the old window as stale evidence until Return to latest.
The production transcript distinguishes bounded prepend, bounded tail rotation, streaming text
mutation, and Session replacement by stable event-derived identity. Prepend reanchors the former
first row; tail output follows only when already at bottom and otherwise produces an unread/Jump
control. Wide and 520-point deterministic production-view fixtures keep Load earlier and Return to
latest labeled, keyboard-reachable, and non-color-dependent. GUI checkpoint schema v5 deliberately
invalidates disposable pre-cursor snapshots; persistent Session exact-state reconstruction now also
restores the exact message source cursor.

Persistent selected-branch history checkpoint (2026-09-06): nonresident reverse paging no longer
depends on the journal-backed host's resident record cache or a lifetime `SessionReducer` message
array. A versioned, private, content-addressed Session index stores metadata and exact canonical JSONL
row evidence but no message bodies. One advisory-owner lease covers source observation, cold index
construction or cache validation, bounded parent traversal, canonical range reads, and the final
source fence. Every returned body is reread from the Session journal and checked against its event,
Session, physical predecessor, sequence, role, text, branch parent, line, prefix, and source evidence.
The Work Host independently revalidates current Work, control, client-attachment, and Session-
relationship authority around that content read; a frozen conversation view never freezes access.
Alternate attached Sessions derive their own journal and opaque index directory rather than borrowing
the creation Session's source.

The scale fixture cold-builds 100,000 physical events with 10,000 visible messages using bounded line
buffers and no lifetime event/body array, then pages through at most `limit + 1` authenticated
metadata/parent lookups and only the selected canonical line ranges. Cold construction remains an
explicit O(journal) operation and retained metadata remains O(events/messages); after a Session append,
proving current relationship authority may currently require one full latest-index rebuild before an
older frozen page can be served. Failed attempts increment the service history call counter, but a
late-failing scan cannot yet publish partial event/byte metrics. Disposable index corruption is
rebuildable from an intact canonical source; source replacement, middle rewrite, unknown Work,
Session, or Work Host control semantics, relationship disagreement, forged physical predecessors,
and incomplete/tampered authority fail closed. The cache is not a sandbox: completeness assumes the
private cooperative builder and owner-lock protocol, and a same-user process deliberately recomputing
a coherent cache is outside the current trust boundary.

The independent GUI window, race, scroll-anchor, keyboard, and visual-fixture contract above remains
unchanged. Final independent review found no remaining P0/P1 defect after the authority reread became
relationship-only, Work comparison was scoped to the requested and creation attachments, and durable
attachment identities became single-use across detach. The uninterrupted macOS suite passes 984
cases / 13,985 assertions in 470.59 seconds; the focused history matrix passes 36 cases / 394
assertions, including the 100,000-event path and authority/race mutants. `just compile` passes and the
release renderer produced all 9 screens; Live and Sessions were visually inspected cleanly.

A fresh Ubuntu 24.04.4 x86_64 snapshot with Swift 6.0.3 and the complete sibling `runtime-hosts`
payload builds `aviaryd` and `AviarySelfTest`; Session-history coverage passes 2 cases / 131
assertions and real-daemon round trips pass 3 cases / 70 assertions. A macOS Swift 6.3.3 client also
completed a handshake through SSH streamlocal forwarding to that Linux daemon. These are capability
and transport proofs for the private same-user Unix-socket/SSH path, not a claim of remote principal
authentication, sandboxing, or hostile-host containment.

Observed repository-review checkpoint (2026-09-07): after a successful native model turn and while
that exact Run and Turn are still active, the Work Host performs one bounded Git observation of the
current working tree relative to HEAD. The observation is a typed artifact action, and its retained
body is published before a metadata-only `artifact.recorded` event and before `turn.finished`.
Artifact identity, source event, Run, Turn, action-start cause, Session owner, body authority, byte
count, media type, and digest remain joined through the service projection. Exact body bytes require
the separate `inspect_artifacts` capability and are fetched only when a person opens the review.
Cancellation during observation cancels the action and Turn; a truthful observer timeout, conflict,
or failure remains reviewable evidence and does not retroactively fail otherwise completed model
work. Turn completion now records its typed completed, failed, or canceled outcome instead of relying
on Session attention as an indirect clue. The visible terminal event is deferred until observation
and the durable Turn outcome settle, so cancellation or journal failure cannot follow an already
announced successful finish.

Exact cold resume recognizes only the complete, settled host-only review producer chain after the
last provider crossing. Its action, artifact, causal links, terminal outcome, and Run/Turn must
agree; generic artifacts, runtime/tool activity, missing evidence, and altered outcomes still refuse
resume. This restores effective conversation context only: Python namespace and background work
remain lost on cold resume, and repository/external-effect recovery coverage remains unknown.

The observer uses literal-argument, bounded process execution with one aggregate deadline and
before/after HEAD, status, and diff-content fences. It retains repository-relative structured file
names, staged and unstaged text diffs for tracked text files, and explicit omissions. Untracked and
ignored bodies, binary diff bodies, and submodule bodies are excluded. If any command, file list,
omission list, or artifact envelope reaches a bound, the record says so and does not present a
partial diff as complete. Tracked diff text is intentionally unfiltered file content and may itself
contain credentials or host paths, which is why it is not observe-readable by default. This is an
observation of current state, not attribution to the Turn: pre-existing, manual, background, and
other-agent edits may all be present. Invoking configured local Git is not a sandbox or a promise of
zero incidental Git metadata/helper effects, though optional index locking is disabled. The slice
does not stage, revert, commit, checkpoint, restore, or claim containment.

The conversation header exposes Review changes only when the authenticated projection contains a
matching artifact in a complete artifact index. An omitted window cannot prove which matching
review is latest, so it does not enable latest-review selection. The sheet loads on demand,
rejects a body whose canonical descriptor changes,
labels bounded/conflicting/unavailable evidence, and can place explicitly bounded revision feedback
into the existing durable composer without sending it. A review selected while the sheet is open
tracks later canonical artifact selection rather than silently presenting an older body as current.
Checkpoint/restore and write-capable review controls remain later Phase 4B work.

Final checkpoint verification: the uninterrupted macOS suite passes 1,008 cases / 14,518
assertions in 520.67 seconds. The fresh Ubuntu 24.04 x86_64 / Swift 6.3.3 snapshot builds
`aviaryd` and `AviarySelfTest` and passes all 35 selected headless groups / 4,195 assertions in
288.37 seconds, including real daemon reconnect and replacement. `just compile`, `just build`,
and `just shots` pass; the signed app includes its signed daemon helper, all nine screen routes
render, and five repository-review fixtures cover wide, narrow, stale, and near/full feedback
capacity states. These fixtures were visually inspected, separately from the production runtime,
controller, and daemon tests. The current macOS probe also handshakes the exact Linux daemon
through SSH streamlocal forwarding; this proves the private transport path, not remote principal
authentication or full Linux GUI/provider parity. Probe processes were stopped after verification.

Phase 3C closure checkpoint (2026-09-04): accepted and duplicate service commands no longer
become UI truth on the strength of a transport receipt. The client retains the exact command
intent until a fresh canonical projection proves its client-qualified `CommandRef`, acceptance
event/cursor, expected resulting Work cursor, and host sequence; indeterminate delivery likewise
clears only on exact canonical evidence. Create and Start intent stores are private, bounded,
no-follow, synchronizing, and compare-and-clear, so GUI or machine interruption cannot silently
turn an uncertain mutation into a fresh command. The journal-backed service and in-memory
conformance host now emit the canonical Run and command evidence required by that contract, while
rejected duplicate Start remains a rejection rather than a fabricated duplicate success. Attach
receipts carry the exact attachment outcome required by transport correlation. Shell execution now
distinguishes timeout and cancellation and performs bounded TERM-to-KILL cleanup without opening
an implicit interactive stdin channel.

Current convergence checkpoint (2026-09-05): after the cache-performance correction and final
independent-review hardening, the integrated macOS suite passes 932 cases / 12,627 assertions in
374.76 seconds. Its 100,000-event Timeline benchmark generates 46,766,700 bytes in 0.941 seconds
and reads plus reduces them in 5.558 seconds on the checkpoint machine. Release assembly signs the
GUI and its nested `aviaryd`. All 9 canonical 1600×1000 snapshot routes render, but the current composite
capture is not a visual certification: ScreenCaptureKit returned `SCStreamError -3811` for several
pure-SwiftUI panels while the bare Cockpit route rendered correctly, and the Mac was locked for
interactive inspection. On the fresh Ubuntu 24.04 x86_64 snapshot
`aviary-linux-probe-20260905-final2` with Swift 6.3.3, `aviaryd` and `AviarySelfTest` build and the
current selected headless suite passes 30 groups / 3,761 assertions in 223.41 seconds. It includes
the real daemon, reconnect and replacement, provider, parent-lease, projection, exact Work/Session
state, transport, and Session-creation paths. A freshly rebuilt macOS client handshakes that exact
Linux daemon through SSH stream-local forwarding as Work Host
`host-20b54e4c-9b3e-4268-8cae-59a157f2ec0e`, process instance `streamlocal-final2`, with zero
catalog omissions. Native remote discovery and device authentication remain later product surfaces.

Phase 3C implementation checkpoint (2026-09-03): the production path now composes the durable
workspace registry, journal-backed Work service, launch manifests, execution factory, and
out-of-process `aviaryd`. The macOS GUI creates, restores, observes, and controls Work only through
the service boundary; GUI window close, application quit, and transport loss detach the client
without issuing End. A fresh client can reconstruct the canonical Work and Session projections,
reconcile retained command intent, and attach to the same ongoing Work. Reducer checkpoints above
32 MiB intentionally retain identity, cursor, and pending-ack proof rather than an unbounded
snapshot; after a client crash those cases safely replay from the canonical beginning instead of
yet resuming the large catch-up incrementally. Create and Attach use a fresh host/control
observation, while steady polling has one bounded owner. The GUI exposes explicit End, disconnect,
retry, and abandon operations rather than conflating process lifetime, transport reachability, and
durable Work state.

The same headless product now builds and runs on Ubuntu x86_64. A real process proof starts Work,
drops the first client, attaches a second client, observes retained provider output, ends the Run,
and shuts the daemon down through its bounded admission/drain contract. A macOS protocol client
also reaches the Linux daemon through SSH stream-local forwarding and verifies the expected Work
Host identity. This is evidence that the local protocol boundary can cross devices; SSH currently
provides the encrypted/authenticated transport, and Aviary does not yet claim a native remote-host
discovery or device-authentication product surface.

Paired client checkpoints, exact end-to-end read acknowledgements, detached-attachment
reconciliation, and bounded Linux provider streaming were implemented at that checkpoint. The
disposable disk-backed projection/index and exact Work/Session continuation roots described above
close the former lifetime-array dependency: a proven prefix is authenticated separately and exact
semantic state advances from the suffix. Session presentation catch-up is suffix-only. Work's exact
state is suffix-only, while its bounded index/query projection still performs a byte-zero streaming
rebuild on growth. Repair may also rebuild all disposable indexes from canonical JSONL. Neither path
loads a lifetime-sized event array, but the remaining Work index scan is measured debt rather than a
claimed completed incremental-read contract.

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
byte reader preserves exact ranges, reads the current canonical schema deterministically, retains unknown future
events, and quarantines malformed or truncated suffixes without overstating the valid prefix. The
versioned Reader Census fixture exercises branching, compaction, model change, queued input, child
completion, late steering, indeterminate actions, unknown events, pre-canonical migration input,
retained bodies, and
malformed/truncated tails across linked Session and Work journals. The production local Timeline
catalog now joins the Census. The production Flock UI consumes the same source-qualified,
unknown-aware Work projection exercised by the fixture, and the Sessions list plus command palette
consume a canonical Session search projection exercised by that same fixture. Native macOS
notifications now consume the same canonical Session/Work projection; service recovery remains
explicitly unwired.

The first canonical Work-recovery projection is now a bounded, reader-owned join rather than a
claim of host liveness. It keeps last-recorded durable Work disposition, exact Work-journal
generation and cursors, Run history, actions/Handles/commands, Session attachments, and the
current transitional client-attachment projection,
source-qualified six-plane recovery claims, unknown domains, corruption, and every omission as
separate facts. Explicit in-process observations are scoped to one requested client and can report
that client's attached/detached/reattachable presentation only when they match the current Work,
Run, Session attachment, and durable client capability; they never prove that a Work Host is alive.
Two GUIs can therefore disagree about their own attachment state without changing the shared
durable Work result. Replaced Work journals, duplicate Work facts, reused/empty identities,
oversized metadata, and recovery claims for another journal generation fail closed. The local GUI
stores this projection from the same catalog scan used for notifications, but supplies no synthetic
client or host observation. A real reachable-host/reattachment dimension remains Phase 3 service
work.

Phase 3B protocol correction (2026-09-02): GUI/client attachment, capability, and read-acknowledgement
facts belong to a separate Work-Host control journal, not a Work or Session journal. Otherwise
opening completed Work would mutate its immutable record, and merely reading a page would advance
the same cursor used to order control commands. Work/Session reducers no longer project the earlier
placement; all Aviary-owned fixtures and consumers are migrated in place rather than retained as a
compatibility path before a production service claims durable reattachment.

The service protocol must expose that split too: attach/detach/capability mutations return the
Work-Host control cursor they committed, while execution commands retain an exact causal Work
cursor. Snapshot and event reads are side-effect free; a separate acknowledgement operation advances
one attachment's cursor for one exact target-journal generation in the control journal. Handshake
or host description exposes the control-journal identity/current cursor so a client can order those
mutations without treating a Work tip as control-plane state.

Phase 3A now has an adoptable runtime-host protocol over a bounded, identity-checked Unix-domain
socket. A fresh client can attach to the same live interpreter after the original client disconnects;
stable callback request identities make at-least-once replay explicit, and late or duplicate results
do not masquerade as successful delivery. Socket ownership, path length, framing, write bounds,
connection generations, teardown, and same-Session command serialization have adversarial coverage.
A transport-neutral `WorkService` executable contract now specifies exact causal cursors,
many-to-many client/session attachments, per-client authorization, bounded and addressable reads,
and service-supplied terminal commit proofs. At the Phase 3A checkpoint this was substrate only: the
production GUI still owned `AgentRunner`, no `aviaryd` owned real Work, and no GUI reconnected to a
persisted Work Host descriptor. Phase 3C below closes those three historical gaps.

The Phase 3B ownership substrate now includes a service-owned `HostedInHouseWork` actor whose
Agent/runner/runtime lifetime is independent of any observing client, plus a bounded Unix-socket
Work-service transport and a separately durable Work-Host control journal. Start admission reserves
the actor before suspension, End can overtake preparation without launching a late runtime, and
terminal state absorbs late disconnect/reconnect/update and turn completion. Client-qualified
commands, multiple observers, detach, stale retries, and terminal teardown are deterministic and
bounded. The control journal is the sole authority for client attachments, capabilities, and exact
per-journal read acknowledgements; mutation admission is serialized across disk suspension and
canonical target reads cannot be forged by a caller-supplied snapshot. A synchronized commit seal
records the exact durable prefix, so live and cold readers project previously sealed truth while
reporting an unsealed suffix rather than inventing a successful mutation. Reopen acquires one
continuous owner lock before inspecting or truncating that suffix, including the fresh-empty crash
window. At that checkpoint this was still substrate; Phase 3C now composes the registry,
journal-backed service, execution factory, and `aviaryd`, and routes the GUI through them so GUI
loss leaves production Work running.

The Phase 3B service protocol/ownership checkpoint (2026-09-03) closes the remaining substrate
contracts needed for that composition. Create is a two-stage, host-minted transaction: the control
journal reserves collision-checked Work, Session, attachment, and command identity; real paired
journals are then created and registered only after their exact canonical prefix verifies. Cold
verification rereads those files and distinguishes the registered creation pair from valid later
many-to-many Session/Work attachments; reducer corruption, unknown semantics, foreign authority,
or an unsealed prefix fail closed. Verified creation state remains actor-owned rather than escaping
as a stale reusable receipt. A Work Host registry now separates live ownership, durable history,
recovery-required state, and unavailable evidence; releasing or replacing ownership requires exact
canonical terminal proof. `HostedInHouseWork` can start from the pre-created idle Work/Session/Run
binding without silently minting another identity, and its runtime remains owned by the actor rather
than by an observer. The transport now carries complete canonical Timeline events, proves contiguous
page chains and bounded body progress, rejects undeclared retained-body sizes, fences every response
to the negotiated host instance (including empty and error responses), and rechecks the backing service
instance on every request. Agent Home persists and synchronizes one strict host-instance identity.
`InMemoryWorkService` remains a conformance harness rather than the production composition. Phase
3C subsequently bound these pieces to real journals and execution factories inside `aviaryd` and
proved that a second client can attach after the first client process exits.

A canonical catalog adapter now projects authority-qualified Session identities and attached Work
at independently verified requested/observed cursors. Only attached, exactly aligned Work with
valid structural and semantic reducer projections can lend the catalog lifecycle, model,
attention, or action facts; unavailable, stale, ahead, divergent, detached, and corrupt Work
remain visible without those facts. The production `SessionCatalog` now scans bounded native local
Session and Work journals, validates their declared owner/authority/locator rather than trusting
directory names, and publishes Work as an independent inventory. During the current cutover, a
same-ID flat transcript can join as one temporary companion row: canonical lifecycle/model/attention/
Work truth drives the UI while existing transcript and artifact actions still target that disposable
projection. This is not a compatibility contract; Aviary-owned flat records and their reader/UI
surfaces will be migrated or deleted as those actions move to canonical bodies and artifacts.
Canonical-only sessions are observe-only in the present GUI; pre-canonical-only rows retain their
current behavior only until that cutover. Corrupt, tailed, unknown, foreign,
duplicate, ambiguous, or symlink-misaligned records remain visible or diagnosed without lending
facts. Duplicate Work identities are excluded from Session assembly, invalid or tailed Sessions
publish no canonical summary, recoverable Work-prefix cursors remain explicit but non-projectable,
and unexpected directory failures are diagnosed rather than appearing as an empty catalog.
Unknown Session semantics also scrub flat-transcript-derived title, message, usage, model, provider,
and lifecycle fields from a companion display rather than letting transitional data refill an
unknown canonical projection. Continue re-reads native state at its action boundary and the native
bundle's owner lock remains the final admission guard; Trash holds that same persistent Session
owner lock across its fresh canonical read and transcript move. The Reader Census registers this
production consumer. Flock now inventories Work independently of Session, qualifies child identity
by Work, and labels any pre-canonical tree as a transitional provenance source pending removal. It
withholds child
lifecycle when an unknown Work/runtime/external-effects domain may affect it. A separate bounded,
client-neutral attention projection retains authored/effective attention, independent Session/Work
cursors, attachment identity, integrity, tails, and unknowns; its `attentionRequirement` is
explicitly `unknown`, `none`, or `required`, without implying that the observing GUI has control
capability. Duplicate summaries become one unknown conflict row, and attachment, unknown-event,
and corruption evidence is independently bounded with omission counts. Canonical Session search is
an ephemeral, conflict-free projection over exact active-branch user/assistant conversation and
bounded title/model metadata; unknown or invalid native facts fail closed, pre-canonical companion
fields are sanitized, identity matches are exact-or-prefix by field, and result bounds do not hide later corpus
rows. Search selection retains the GUI action identity and canonical EventRefs, native companion
rows cannot be refilled by pre-canonical AgentTree prompts, and conversation lifecycle is kept separate
from attached Work liveness. The first notification adapter is now wired for needs-you,
failed-recovery, and ready-for-review transitions. It observes permission without prompting at
launch, baselines rather than replays attention accumulated while delivery is disabled, uses bounded
typed cold-click routes,
and preserves the route's Session/Work/action/cursor identity in the workspace. Session selection is
re-resolved canonically; every Session/Work/attachment/action/cursor field is reconciled against the
same current catalog before the inspector labels it exact evidence. Stale clicks still select the
Session but show an explicit current-state warning, and polling clears an already-open evidence card
as soon as either journal advances or the action resolves. Failed-recovery selection is qualified by
Work journal and Session attachment rather than a bare action ID. Unknown, corrupt,
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
`Agent`. Native Work acceptance is authority; the flat transcript is a disposable downstream
projection during cutover, so a later projection failure cannot rewrite an accepted command as
rejected. Exact
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
falls back to the flat transcript. The replacement Run records the six-plane recovery matrix;
the runner restores retained pinned instructions, verifies the live tool schemas before the first
provider call, uses a fresh Python namespace, and reports Futures/Handles as lost and repository,
artifact/memory, and external-effect coverage as unknown. Structured assistant bodies are retained
before their Session events, while tool-only assistant events remain in model history without
creating an empty visible chat row.

The Apple Swift 6.3.3 compiler accepts the SDK emitted by Apple Swift 6.3.2; the compatibility probe
configures its own writable module cache and succeeds both directly and through every gate. At this
checkpoint, the full suite passes 516 cases / 5,776 assertions in 47.45 seconds and `just compile`
is clean. The Phase 3A checkpoint raises that full-suite receipt to 554 cases / 6,203 assertions in
62.84 seconds, with `just compile`, both Python host syntax checks, and `git diff --check` clean.
The versioned 100,000-event benchmark reads and reduces a 46,766,700-byte input in 5.769 seconds on
the checkpoint machine (generation 0.893 seconds). The visual gate renders all 9 canonical screens;
it also caught and
closed a SwiftPM snapshot crash by making the UserNotifications adapter available only from a real
application bundle. Final Sol review found
no remaining must-fix issue after exact cursor/attachment/read authority, local action-time
revalidation and owner locking, unknown-domain display scrubbing, duplicate non-projection,
slash-injective Work identity, provider-action causality, exhaustive retained-body decoding,
structured assistant replay, pre-Start capture/cleanup, source-assembly binding, truncated-source
replay, metadata-only inspection, parent-qualified transitional-record selection, multi-Session attention,
bounded evidence, conflict projection, Work-liveness separation, bounded search allocation, and
wrapper-only injection findings were remediated. A second notification-specific Sol review found no
P0/P1 blocker after typed turn outcomes, turn/run transition deduplication, per-Session conflict
isolation, authorization gating, bounded typed routes, and cold-click routing were remediated. A
third Work-recovery Sol review found no P0; its one-sided attachment, activity-envelope, and absent-
Work Census findings were then closed with reciprocal Session/Work joins, Run-qualified turn and
Handle transitions, explicit omission accounting, and an Aviary-owned fixture migration.
A Work-service seam review found no remaining blocker after terminal reservation, exact retry
reconciliation, per-principal authorization, Session/attachment binding, bounded body reads, and
bundle-backed terminal commits were hardened. The final RuntimeHost review found no remaining
P0/P1/P2 after cancellation cleanup, atomic destroy/recreate, bounded callback admission and
refusal, unread-peer shutdown, and process-generation fencing were exercised adversarially.
The Phase 3B ownership/control checkpoint passes 583 cases / 6,522 assertions in 75.48 seconds,
with `just compile`, both Python-host syntax parses, `git diff --check`, and all 9 visually inspected
snapshot screens clean. Its 100,000-event run encoded 46,766,700 bytes in 1.279 seconds and read plus
reduced them in 6.817 seconds on the checkpoint machine. Final Sol review found no remaining P0 or
P1 issue after the continuous-lock recovery interval, empty-journal seal recovery, pre-suspension
Start reservation, absorbing terminal state, exact target-journal acknowledgement, UTF-8 bounds,
connection fencing, and bounded shutdown paths were hardened.
The completed Phase 3B service protocol/ownership checkpoint raises the full-suite receipt to 605
cases / 7,081 assertions in 74.56 seconds. `just compile`, both Python-host syntax checks,
`git diff --check`, and all 9 freshly rendered and visually inspected snapshot screens are clean.
Its 100,000-event benchmark encoded 46,766,700 bytes in 0.901 seconds and read plus reduced them in
5.766 seconds on the checkpoint machine. Final independent Sol review found no remaining P0/P1
after host-minted creation and cold source verification, suffix-safe many-to-many attachment,
actor-owned proof state, canonical registry release, pre-created Work adoption, exact event/body
transport correlation, retained-body length validation, and per-response host-instance fencing were
closed adversarially.

Phase 0 still owes real VoiceOver/keyboard UI automation and broader driver focus/race proof. Phase 1
still owes the remaining named pre-canonical reader migrations outside the production Work-service/
control recovery path; individual skill/memory identity and included-versus-listed
provenance inside the now-durable block-level prompt sources; independent native Work bundles for
children; actual disk-full and permission fault reachability; and a measured
peak-RSS budget. The semantic component measure is deliberately not claimed to be provider-specific
HTTP wire size. The 100,000-event benchmark fixes an encoded-input and read/reduce baseline, but does
not claim incremental rendering or bounded peak memory. Phase 3 now has an out-of-process local Work
Host, GUI-independent process survival, reconnecting clients, durable paired read checkpoints and
acknowledgements, a transactional disposable projection store, bounded local source leases and
typed heads, persistent exact Work and Session continuation roots, projection-backed cold service
verification, actor-serialized live reads, first-class durable and GUI composition flows for a new
Session on existing Work, Session-qualified active-Run routing/replacement, a current Linux
headless regression receipt, and a macOS-client-to-Linux-daemon SSH transport proof. It still owes a
broader injected-kill multi-client fault matrix, a complete current visual/assistive-technology pass,
and native remote discovery/authentication UX before the entire many-to-many architecture is
complete.

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
  temporary flat-Session bridge now synchronizes command intent before dispatch and latches writer
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
- **Implemented for service-backed conversations (2026-09-06):** bounded prepends preserve a
  stable row anchor; new tail content follows only from the bottom and otherwise exposes unread /
  Jump or Return to latest controls. Local/catalog history still needs the same shared paging seam.
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

### One active Run has one conversation-owning Session

A Work may have many Session attachments, but an active Run has exactly one Session/attachment
pair that owns its conversational context and message journal. That binding is a canonical Work
fact established by `run.started`; it is not inferred from the Work's creation record, current GUI
selection, or whichever client most recently sent a command.

- Another GUI attached to that same Session may use every capability granted to its own client
  attachment. Client multiplicity does not change conversational ownership.
- A different Session may observe the active Work and use genuinely Work-scoped, non-textual
  controls such as supported cancellation or explicit End when authorized. The Work command keeps
  the originating Session attachment as provenance even though it does not change the Run's
  conversation owner.
- `send`, `steer`, and `queue` are text-bearing conversation operations. They may target the active
  Run only from its owning Session until a future multi-journal operation can durably record the
  originating Session input and its delivery without merging transcripts. Substituting the active
  Session identity for a different caller is forbidden.
- After explicit End leaves Work reusable, `start` may select any canonically attached mutable
  Session. The Work-level launch configuration is independent of the Session selected for that
  Run; the Run manifest, native journal pair, and live actor use the selected binding exactly.
- GUI controllers, drafts, pending intents, checkpoints, visibility, and selection are keyed by
  the client/Session attachment identity rather than bare Work. Closing or hiding one Session view
  cannot hide, overwrite, detach, or end another Session attached to the same Work.

The cutover is complete only when the canonical and live paths agree under an adversarial matrix:
Session A starts and accepts text from two separately attached GUIs; Session B can observe but its
text commands are rejected without writing either conversation; End returns the Work to reusable;
Session B then starts the next Run with its own journal/context; a daemon restart between each
boundary reconstructs the same owner; and two racing Starts from different Sessions admit exactly
one complete binding while the loser receives a stable rejection. Descriptors and notifications
must name the active Run's Session/attachment explicitly rather than asking clients to infer it.

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
| GUI/client attachments and read acknowledgements | Work-Host control journal | Which client attachment and per-journal cursors are durable, and is connectivity only ephemeral? |
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
- Record Session-to-Work attachment creation/detachment and its exact Work cursor in the Session
  journal. Record GUI/client attachment creation, explicit detachment, observe/control capability,
  and per-target read acknowledgement in a separate Work-Host control journal that may evolve after
  Work becomes terminal. Record every control command's causal Work cursor and host-assigned order.
  A lost connection changes ephemeral connectivity, not durable attachment or other clients'
  control capability.
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
- Show separate truthful projections:
  - **Recorded model context:** the last provider-bound crossing, including pinned instructions,
    selected history, context/compaction boundary, summary presence, attachments, omissions,
    component identities, and delivered sizes. It must not be labeled as the next request.
  - **Next-request preview:** once a future request is deterministically assembled, show what will
    cross next and invalidate the preview whenever selection/compaction/attachment state changes.
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
- Add a disposable transactional projection store on both Work Host and GUI sides. Canonical JSONL
  remains the transferable authority; the store records exact journal identity, cursor, prefix
  digest, bounded event pages, reducer heads, and pending acknowledgement intent, catches up a
  missing suffix after restart, and can be deleted/rebuilt on corruption or schema change. No normal
  read, projection, append, or acknowledgement may require a lifetime-sized journal array or a scan
  from byte zero once the stored prefix is proven.
- Give the logical protocol a small device-independent surface: list/describe Work, attach/detach,
  update this client's observe/control capability, snapshot/events-after-cursor, fetch artifact,
  start/send/steer/queue, hold, supported cancellation, and explicit end/destroy commands.
- Persist Work/session/run registry, stable Work Host identity, runtime endpoint, process start
  identity, protocol version, environment provenance, Session attachments, command actor and causal
  Work cursor, plus client attachments and per-journal read cursors in the Work-Host control journal.
  PID is diagnostic, not ownership.
- Automatically reattach on launch or reconnect; distinguish client detached, network disconnected,
  Work alive, Work Host recovering, dead-with-complete-record, indeterminate, and orphaned.
- Make canonical command identity client-qualified rather than indexing by a caller-local command ID
  alone, and bind its idempotency digest to kind, full body reference, Session attachment, and causal
  Work cursor. Reconcile an exact duplicate before stale-cursor validation; same identity with
  different contents is a durable conflict.
- Add command IDs and idempotent acknowledgement for the commands that exist at this phase: send,
  steer, queue, hold-after-boundary, supported cancellation, detach, and end-run. Journal acceptance
  before execution; keep accepted, dispatch-started, delivered/not-delivered, and indeterminate as
  distinct durable outcomes; and version the protocol so confirmation/retry commands can arrive
  later.
- Return send, steer, queue, and cancellation service calls at a durable receipt boundary rather
  than waiting for the entire agent turn. This keeps later steering and cancellation reachable on
  the same ordered client connection while execution continues under the service-owned Work actor.
- Define GUI/Work-Host/runtime version negotiation and a drain/restart policy for incompatible
  hosts. Never migrate live Work across a version boundary implicitly.
- State the transport trust level precisely. The first private Unix socket proves only same-local-
  user access; its `ClientRef` is a self-claimed routing identity, not an authenticated principal or
  sandbox boundary. Keep a transport-principal-to-client binding seam for later remote/device auth,
  and require clients to verify the expected Work Host identity during reattachment.
- Preserve wire admission order with one bounded input pump per connection, fence every callback by
  connection generation, bound queued response bytes as well as items, and make listener/endpoint
  shutdown identity-checked and globally deadline-bounded. Timeout or cancellation must not let one
  late response poison unrelated requests.
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

The approved [private agent-Handle pilot](phase5-agent-handle-pilot.md) is now being implemented
in bounded slices. Its first checkpoint proves independent child lifetime and retained results
with real Python runtimes; subsequent slices add typed, authorized child cancellation over the
Work service and privacy-safe recorded child activity/recovery projections. These do not enable
the pilot in the installed app. Coordinator-local ownership observation and child-admission
shutdown fencing now distinguish live owners from recorded obligations, including pre-append
admission and unconfirmed cleanup. This is not a public process-liveness or reconstruction claim.
Ryan's lifetime policy is now explicit: background agents default to running until finished or
stopped, with optional time, token, and spend limits. Implementing those optional limits (including
removing hidden default iteration ceilings) and physical retention remain activation gates. This
is progress toward Phase 5, not completion of its broader exits.

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
- Fuzz migrated, current, truncated, duplicated, reordered, and unknown timeline records.
- Assert live-overlay-to-durable-message convergence and live-versus-replay equivalence.
- Assert non-vacuity: every fault injection point is reached and every expected terminal state is
  observed.

### Reader Census

Maintain one adversarial fixture directory: a manifest, linked Session and Work journals, a
pre-canonical migration journal, and retained body/artifact fixtures. It contains a branch with
explicit tip, unknown event
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
- Do not replace canonical JSONL with the projection database. The now-required Phase 3C index/cache
  is disposable derived state whose cursor and prefix digest are always proven against the
  append-only transferable source record.
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
   attachment state, one-time Aviary-owned fixture/data migration followed by removal of the old
   reader, live/replay equivalence, incremental cursor.
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
