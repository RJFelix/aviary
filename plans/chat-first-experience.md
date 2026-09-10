# Chat first: a product reset grounded in the first real session

Status: assessment and first implementation slice, 2026-09-07. This interrupts further
checkpoint/restore work in `core-experience.md`; the durable architecture remains underneath.

## Assessment

The implementation is substantially stronger than the experience it presents. Tests proved many
individual state boundaries, but the signed app's first-use journey still fails before a person
can talk to an agent. The production UI was inspected directly, not only through fixtures.

- Cockpit, Live, and Sessions ask the person to choose between overlapping conversation surfaces.
- “Session”, “run”, “Work”, “attachment”, and “Work Host” appear before they earn an explanation.
- New Session is a configuration form: workspace and engine internals precede the actual request.
- A yellow host warning has neither a clear consequence nor an adjacent repair action. A green
  Python-runtime footer simultaneously implies readiness, although it proves something else.
- Start closes the form before asynchronous startup succeeds. Local prompt state disappears
  before the existing durable Create-intent boundary is reached. This is a product data-loss bug.
- Improve Aviary is important but its floating pill occludes the primary Start action.
- Completed work and imported transcripts need accessible homes, not a second execution model.

## From launching machinery to keeping a request

Concrete framing: the GUI must bootstrap a daemon, register a workspace, create Work/Session,
attach a client, start a Run, and only then show a conversation.

Stripped framing: a person's saved intention is gated behind an executor's availability.
The underlying shape is an outbox and a worker, not a setup wizard. Mail drafts and print queues
make the useful distinction: retaining a request is independent of delivering or executing it.

## Graph of the conversation experience

Each edge names a user-visible relationship. Saving is reversible; execution may create external
effects. The interface must not silently cross from one to the other during recovery.

```text
New chat --captures--> request + project + agent choice
Request --saves before connecting--> local chat
Local chat --shows--> exact original prompt
Local chat --attempts delivery--> agent service
Agent service unavailable --blocks execution, not saving--> local chat
Blocked chat --offers explicit retry/settings--> agent service
Uncertain delivery --requires exact reconciliation--> original attempt
Accepted delivery --joins without resending--> canonical conversation
Conversation --shows--> replies + current activity + next useful control
Conversation --leads to--> changes + evidence + revision feedback
Conversation --survives leaving--> chat list
Any screen --opens contextual feedback--> Improve Aviary
Improve Aviary --tracks repair and review--> Workshop
```

The local chat is a presentation/durability object, not a fabricated canonical Session or a claim
that the agent received anything. The saved request and service receipt are separate modules.
Backend Run/Work/Session identities remain exact and discoverable in details.

## Primary journeys and the intended product

- Start: open Chats, write a request first, confirm the remembered project and agent, send.
  Advanced controls stay collapsed. A chat appears immediately after its local save succeeds.
- Startup failure: the same chat shows the original prompt, “Not sent”, the blocking reason, and
  one concrete recovery action. It survives app relaunch. No dismissing toast is the sole evidence.
- Continue: return to Chats, select by human title and meaningful attention state, reply in place.
  A finished turn does not remove a conversation from the primary list.
- Understand: a compact current-activity summary, expandable details and provenance, not an
  always-visible architecture tutorial. Unknown activity remains explicitly unknown.
- Interrupt: stop current work and leaving the conversation are distinct actions. Retry after
  uncertain delivery must use exact retained identity, never a freshly minted command.
- Review: open Changes, see limitations and evidence, ask for revision; write/restore controls
  are a later slice, not implied by the presence of diffs.
- Improve Aviary: a permanent toolbar action and keyboard shortcut capture the current context;
  its compose panel deliberately opens when requested. The idle affordance never covers content.
- Diagnose: advanced runtime, model, usage, imported-history, and multi-agent surfaces stay
  available under secondary navigation. Remote execution remains capability-qualified.

## First implementation boundary

Unify the normal landing/Live routes as Chats; keep History explicitly for recorded/imported
conversations. Put New chat above the list and prompt above configuration. Add a durable local
pre-launch chat and exact handoff into the existing Create/Start intent protocol. Show errors in
that chat and offer explicit retry. Move Improve Aviary into reserved toolbar space. Fix the
actual signed-app startup failure without erasing a user's Work merely to obtain a green launch.

Do not turn this into a label-only rebrand, a replacement timeline, a new scheduler, or a sandbox.
Do not claim the whole usability program is complete after this first slice.

## Acceptance checklist

- Signed app, existing user home: real accepted handshake and bounded read after fresh startup.
- Controlled failure: submit a recognizable prompt with the service unavailable; chat and exact
  prompt remain visible, navigate away/back, relaunch, retry explicitly after repair.
- Lost response: one saved chat and one canonical Create/Start; no duplicate execution.
- Local persistence failure: keep the form/text and explain that saving failed; do not claim saved.
- Model/workspace/prompt-limit failure: keep the chat and show what needs correction.
- Keyboard New chat and Improve Aviary work from any route; no Start/composer overlap at narrow
  and wide sizes. Verify the actual signed app, not just populated design fixtures.
- Existing delivery, draft, multi-client, runtime-lifetime, and history tests remain green.

## Implemented boundaries and remaining work

The first slice now has one Chats workspace, a prompt-first launcher, private pending-chat
storage before native startup, exact Create/Start handoff, and chat-local recovery. Only exact
client-qualified canonical **delivery** with matching prompt retires the local card; another user
message or an accepted receipt does not. Associated but unresolved cards offer explicit unsent-copy
and presentation-only dismissal, with warnings that the original may still take effect. Definitely
unsent cards can be edited or discarded. Copies do not start automatically.

Actual normal-home startup exposed two related omissions in the temporary-home test coverage:
the GUI put its private client identity directly under a conventional `0755` AgentHome, and three
GUI intent stores also required that entire home to be `0700`. Identity now has a dedicated private
child; intent stores accept a current-user-owned, non-group/world-writable home while preserving
`0700` descendants and `0600` records. Existing home permissions are not changed. Separately,
pre-handshake missing/refused sockets now allow bounded helper launch/re-discovery instead of
leaving stale discovery permanently unrecoverable.

The probe and focused tests deliberately make no provider call. They prove saved requests,
relaunch, editing, exact delivery discrimination, safe copying/dismissal, storage failures, and
ordinary-home permissions—not provider availability or the whole coding/review journey.

Next usability slices remain: a simpler in-chat activity hierarchy and explicit next-action
states; interruption/queued-follow-up ergonomics; changes/evidence-to-revision flow; and a complete
real coding session through those surfaces. Native pre-launch durability does not claim identical
Claude Code process-survival behavior. History/import reading remains a secondary view, and the
advanced many-client/Work connections remain available rather than silently removed.

## Verification receipt — 2026-09-07

- Final macOS full SelfTest: **1,026 cases / 14,620 assertions**, all passed in 543.94s.
  One earlier buffered invocation stalled without a reported failure and was stopped; the cause
  is unproven. The complete receipt is the subsequent observable TTY run, not the partial log.
- Signed release app and nested helper build/sign successfully. The actual AppModel
  `--chat-journey-probe` passes against its own temporary data, including failed-save preservation,
  exact relaunch/edit/retry, and explicit unsent-copy/presentation-only dismissal.
- Real signed GUI on the existing conventional home reaches **Agent service connected** without
  changing home permissions, deleting old Work, or rebuilding test-only home state. A controlled
  failed initial prompt remains visible after quit/relaunch; New chat and Improve Aviary shortcuts,
  Diagnostics, and narrow/wide layout were exercised directly. The clearly labeled verification
  chat remains unsent; no provider call was made.
- All eight visible screen routes render. The final Chats render was regenerated and inspected
  after removing the empty landing page's no-op Cancel button. In-chat context/working-state
  inspection remains available from the chat header rather than an always-open sidebar.
- These are **macOS startup, durability, UI, and existing regression** receipts. No fresh Linux
  run or complete live model coding/review session is claimed by this slice.

## Real-use startup follow-up — 2026-09-08

Ryan's first real chat exposed gaps that the preceding preflight-only receipt did not cover:

- An unrelated configured `vendor/model` ID invalidated the entire in-house model catalog,
  including a selected Codex model. Provider-local model identifiers must permit slashes.
- A successfully created idle Work correctly has no live Run observation. The attached-chat
  reader nevertheless required that observation and withheld the canonical conversation.
- Exact Create replay returns a duplicate receipt. Chat reconstruction must accept that receipt
  while retaining exact identities and distinguishing original receipt authorization from current
  attachment capabilities.
- A successful catalog refresh erased the earlier Create error. Connectivity and outstanding
  startup failure now have separate state; recovery explicitly reconciles retained Create intents.
- A normal multi-source system prompt can exceed the small metadata-record bound even though
  every source and body is valid. Prepared Start reservations embed that assembly and need the
  bounded launch-record limit, not the scalar/pointer metadata limit.

The acceptance bar for this follow-up is the actual signed GUI recovering the original saved
conversation and receiving a provider response, plus a durable socket Create/read/duplicate
regression using production-shaped configuration. Handshake, Python availability, pure resolver
tests, and fixture screenshots are separate supporting evidence, not substitutes for that flow.

### Follow-up receipt

- The signed GUI recovered Ryan's original Work/Session, delivered the original 96-byte request,
  and displayed the Codex model's completed documentation summary. Canonical Work evidence has
  exactly one `run.started`, one `command.accepted`, one `command.delivered`, and one completed
  turn. Other saved requests and the unsent verification card were not dispatched.
- The interrupted, unprepared Start reservation was backed up and repaired explicitly in place.
  Its prompt, Work, Session, and reserved Run identities were unchanged. The recovered flattened
  context matched the previously retained 12,931-byte body digest; repair provenance is explicit.
  No automatic crash-recovery rule was weakened to infer missing context. The old idle helper had
  no Run/child process and was replaced; no running agent was interrupted.
- Full macOS SelfTest before the last UI-policy alignment: **1,030 cases / 14,688 assertions**,
  all passed in **503.04s**. The final explicit-retry policy delta then passed its integrated
  controller/UI-policy test (**1 / 15**) and the policy suite (**4 / 59**). The signed app/helper
  and signed AppModel journey probe pass; the final live GUI response was visually inspected.
- New focused proofs: qualified-model durable socket Create/read/exact duplicate **1 / 46**;
  realistic prepared reservation bound/reopen/negative size limit **1 / 8**. Earlier supporting
  controller and transport suites passed **38 / 328** and **29 / 358** respectively.

This closes the reported chat-start blocker, not the complete coding/review journey or fresh
Linux verification. Follow-up UX work should clear acknowledgement banners once canonical
catch-up completes, replace remaining machinery-heavy copy, and reconcile superseded architecture
docs (the model's summary exposed their conflicting claims). Add a default full startup canary
using the production prompt builder, not only a one-source test prompt. Host-policy changes across
Create replay still need an explicit original-authorization retention contract; this check used
unchanged grants. Generic launch failures remain retained unless non-admission is proven.

## Conversation ergonomics — 2026-09-08

The next slice keeps execution/control contracts intact and changes the primary interaction:

- Title, state, project/model, and controls have separate space at narrow widths. Machine IDs
  and unknown timing are no longer permanent chat-list/header decoration; exact evidence is
  still available in details. Ended/failed fallback cards no longer call themselves ready.
- Current activity is a compact recorded intent/type/state, not three columns of missing
  explanations. No recorded current step is explicitly reported as such. Activity opens current
  and recent completed actions from the chat, with evidence disclosure and projection omissions.
- A full-width composer defaults busy messages to separate follow-ups where supported. “Guide
  current work” is an explicit, one-message override; failed submissions preserve the choice and
  draft. Timing is explained beside the control. Markdown preview is opt-in.
- “Stop after step” retains the exact supported safe-boundary cancellation scope. Ending the
  agent session is a confirmed secondary action; leaving a chat never implies termination.
- Changes/review explains the saved working-tree observation in ordinary language. Attribution
  and checkpoint limits remain inspectable; the sensitive-file-content warning stays visible
  before loading. Review still prepares a draft, never sends feedback automatically.
- Acknowledgements carry exact command identity and retire only after matching canonical
  acceptance evidence catches up. This is not proof of runtime delivery or task completion.
  Local warnings and draft-storage errors cannot be retired by that policy. Historical read
  diagnostics remain inspectable but stop blocking the composer after a verified fresh read.
- A failed new-chat reconciliation no longer skips reconstruction of unrelated existing
  attachments on GUI startup/reconnect. New creation still waits for reconciliation; existing
  chats still require their own complete, identity-fenced catalog and canonical reads. Blocked
  recovery is observation-only through both restoration and later polling: it cannot implicitly
  retry a retained Start. Explicit Check delivery remains available. The signed journey probe
  has a guarded case and a recovery-enabled control that admits exactly one Start.

Verification must include the signed production chat, not just the 520px/1200px populated
fixtures. The planned isolated cart exercise starts from a failing quantity-total test, receives
a real agent edit, inspects the saved diff, prepares a revision in the composer, and verifies
the resulting files independently. It must not reuse or send any of Ryan's other saved prompts.

After this slice, the remaining product work is chiefly richer progress summaries across child
agents/background work, a more integrated changes-and-evidence workspace, and stronger ongoing
real-use/remote regression coverage. Broader command ownership, security containment, and a new
timeline architecture are not prerequisites for these conversation improvements.

### Conversation slice verification and newly exposed startup boundary

- Full macOS SelfTest before the final Create-key correction: **1,040 cases / 14,732
  assertions**, all passed in **537.81s**. Notice retirement and recovered-read admission have
  **8 / 25** focused assertions; busy-message presentation has **2 / 15**.
- Populated production-view fixtures were inspected at 520px and 1200px; the narrow composer
  and header no longer truncate their primary controls. These are pane fixtures, not a claim
  that the whole application window supports 520px. The actual signed GUI also restored the
  existing conversation with an enabled composer and without the obsolete acknowledgement.
- The real coding exercise stopped before admission of its new chat: the launch manifest store
  required a genesis control cursor, so a second Create on an already-used host failed with an
  internal error. The exact test request remains saved; no agent edited the cart project. This
  is a missing production-sequence regression, not evidence that the coding/review journey passed.
- The corrected store accepts well-formed cursors in the exact host control journal; the control
  journal still performs current-cursor CAS. A real durable resolver/Unix-socket regression now
  creates two distinct chats and replays both identities without another creation or control
  append: **1 case / 65 assertions**, passed. It does not call a live provider.
- Final focused Create-key validation is **1 / 13**; the full local launch-resolver group is
  **7 / 101**. The signed AppModel save/failure/relaunch/retry probe passes. Successful action
  history now keeps internal targets and retry warnings in its expanded evidence rather than
  presenting every completed step as a warning; failed/indeterminate warnings remain visible.
- The signed GUI was quit and reopened with the test Create still unresolved: the original
  chat reattached, showed Ready with its composer available, and preserved the separate startup
  warning. The original helper and its Python PID were unchanged. The populated activity sheet
  was visually inspected; its repeated action rows have stable accessibility identifiers.
- Deployment must not kill the existing user's live Python namespace. Replacing the signed
  helper on disk does not upgrade its running process. Explicit End and a graceful service
  restart require user intent; after End changes the control cursor, the saved test Create may
  need a proven-stale rejection followed by an explicit fresh attempt. Do not silently mint a
  replacement request or infer delivery from a green connection badge.

### Authorized restart and real coding/review journey — 2026-09-08

The deployment boundary above is now exercised, not merely planned. With Ryan's explicit
approval, End recorded `run.finished` for the original chat and its Python process exited;
the helper then stopped gracefully and the current signed helper launched. The conversation
remained saved. The original live Python namespace was intentionally ended, not recovered.

Restart exposed one more admission distinction: a same-journal stale Create was reported as a
generic internal error. Commit `556b6ad` adds an exact typed pre-append stale-cursor error at
the control journal and translates only that proven rejection to the service's stale response.
Unknown append/transport failures remain indeterminate; duplicate lookup retains precedence.
The GUI could then explicitly retry the isolated cart request with a fresh identity, without
resending any of Ryan's unrelated saved requests. The extended real durable socket test passes
**1 case / 76 assertions**; Work Host creation tests pass **8 / 144**. Debug SelfTest and signed
release app/helper builds and strict signature verification pass. No new full-suite or Linux
receipt is implied by those focused checks.

Actual signed GUI, live provider (`openai-codex/gpt-5.6-luna`, high), isolated Git project:

- Original quantity-total regression failed before admission. The first real turn changed
  only `cart.py`; independent `python3 -B -m unittest -v` passed both existing tests.
- Review changes required explicit file-content loading and showed the exact one-file diff,
  with working-tree attribution and sensitive-content limits visible.
- Revision feedback was placed in the composer without sending: the transcript still had
  only the original turn, the draft was visible, and Send remained an explicit action.
- One explicit Send requested negative-quantity rejection and a regression test. The agent
  preserved both existing tests, changed the expected two files, and independent execution
  passed **3 tests**. The second saved review showed those exact changes.
- Canonical Work evidence has one accepted/delivered pair per request and two distinct
  started/finished turns; no manual retry or duplicate revision was needed.
- Closing and reopening only the GUI preserved the same helper and Python PIDs and restored
  both turns with an empty composer. This proves local live-host reattachment, not cold
  Python-state reconstruction. The test runtime was subsequently explicitly Ended, with
  canonical `run.finished` and Python exit; its saved chat and scratch files remain inspectable.

One real-use defect remains from this journey: immediately after revision Send, the GUI briefly
showed an indeterminate-command warning and an unavailable Session row, then caught up to the
exact delivered command and completed answer without replay. Data preservation/reconciliation
worked, but this transient alarming presentation is not acceptable evidence of a polished
delivery experience. Trace receipt generation and concurrent canonical reads before changing
error severity or suppressing genuine uncertainty. The stale-Create card's “request needs an
adjustment” wording also overstates the required action when the request text is already valid.

### Delivery lifetime and exact receipt reconciliation — 2026-09-09

The transient warning above came from exposing a crash-safe retained intent as a settled
failure while its original service call was still awaiting a response. The controller now
projects an explicitly process-local `commandInFlight` fact. It is never persisted and never
proves delivery: a reconstructed controller still treats its retained intent as uncertain.
The chat and inspector show neutral confirmation progress during that live call, while actual
transport failures, storage failures, and restored uncertainty retain their warning paths.
Mutations, retries, and stale-intent abandonment are disabled until the original call settles.

Independent review found a second ordering bug: polling could observe acceptance before the
original response, clear the intent, then let the late response recreate a disk-only intent
which blocked the next input. Reconciliation now waits for that original call to settle.
Gated tests cover acceptance-before-response, accepted-but-response-lost, pre-effect failure,
restart, and a subsequent distinct input. Removing just this guard reproduced both early
intent clearing and the next-input `pendingCommandExists` failure; restoring it passed.

Proven stale Create rejection also has its own persisted presentation classification. It asks
for an explicit fresh startup attempt, says the text is unchanged, and does not demand editing
the prompt. Unknown transport effects remain retained and are not classified as stale.

Receipts so far: in-flight focused group **3 cases / 50 assertions**; pending-chat group
**14 / 58**; signed release build, strict signature verification, and signed AppModel journey
probe pass. The probe exercises both live neutral presentation and restored uncertainty,
including draft-handoff notices. Full macOS SelfTest passes **1,044 cases / 14,836 assertions**
in **896.69 seconds**, including the new controller, GUI policy, and pending-chat tests.
Later sidebar/App-only changes require their own app build/probe; this is not a Linux receipt.

Real signed GUI/provider verification used a new isolated project at
`/private/tmp/aviary-delivery-check.43nc5g`. The unavailable previous temporary folder was
reported accurately; editing the saved project's path preserved the request and did not
submit until explicit Start. The initial request ran three unit tests; one follow-up asked
which test covers negative quantities. Both completed without retry or the false red delivery
warning. Canonical Work `work-f37b96ad-d4e9-4447-999d-5b4b437c547a` has two accepted inputs,
two started/finished turns, and explicit test-runtime End at `run.finished` sequence 43.
Independent execution also passed all three tests. No unrelated saved requests were sent.

The reproduced sidebar title flicker is also corrected: during an incomplete catalog join, an
unambiguous exact attached canonical projection may supply the retained chat title. The unknown
conversation state remains disclosed, and agent state is explicitly qualified. Duplicate,
missing-summary, noncanonical, placeholder, and ambiguous multi-Work cases do not get a fallback.
The final signed AppModel probe exercises the actual presentation gate for positive and negative
cases; final release bundle and strict signature verification pass. This is deterministic
presentation coverage, not an additional provider round-trip after the sidebar change.

Separately, cold reconstruction of an older workspace is blocked by a stored filesystem device
identity mismatch; expose that specific condition without silently rebinding the user's
workspace or claiming lost Python state survived.

Next bounded repair: workspace identity across restart. The original Aviary directory retains
inode `278097385`, but its recorded device number `16777232` differs from the post-reboot
`16777231`. New registrations use the latter. `registerLocalDirectory` refuses the same path
with changed identity, so the current instruction to register again cannot actually repair it.
For new registrations, use an available restart-stable volume identity plus directory identity;
never equate unrelated directories by inode alone. Add explicit folder reconfirmation for an
existing opaque workspace ID, with current-generation checks and clear effect on future launches.
Ordinary register/resolve must still reject silent replacement. Show project unavailability
separately from transport connectivity and conversation integrity. Do not silently update Ryan's
existing registry while diagnosing; the live Python namespace was intentionally ended and is
not part of this repair. No remote or Linux recovery claim follows from a macOS volume fix.

### Project confirmation after a macOS restart (2026-09-09)

The bounded repair is implemented. New macOS registrations retain the persistent volume UUID
when available, together with directory inode/type. A changed raw device number alone no longer
invalidates that identity; changed inode/volume or missing previously recorded volume evidence
still fails closed. Filesystems without a volume UUID retain the device-based fallback. Existing
device-only records with a mismatch require explicit confirmation, not silent promotion.

Both an attached idle chat and an unsent blocked request now offer **Confirm project folder**.
Choosing the original folder is read-only. Confirming it revalidates the registry revision,
original opaque project ID/path, and chosen directory identity before updating that same project.
The saved prompt and command IDs are retained. A successful folder write is reported separately
from a failed service refresh or draft-status save. Neither confirmation nor its observation-only
refresh sends input, reconciles unrelated Creates, or starts/restarts an agent.

The service can discard its obsolete in-memory bootstrap recovery observation after a fresh,
clean idle Work/Session pair and reconstructable launch material are proven. A second cursor and
registry-fact check fences changes during the probe. Active Runs, unfinished handles, pending
Start reservations, unknown/corrupt sources, and unrelated recovery facts remain unavailable.
An explicit subsequent Start is still required; there is no claim of recovered Python state.

The signed production confirmation sheet has been rendered and visually inspected via
`project-reconfirmation-fixture`; the signed AppModel journey verifies exact prompt/command-ID
preservation and no implicit service or agent start in an isolated home. This fixture is not a
claim that the user's currently running older helper has loaded the new code. User folder
registrations have not been changed as part of verification.

Final macOS regression: **1,054 cases / 14,915 assertions**, all passed in **508.63 seconds**.
Focused checks include 14/93 workspace registry, 8/120 local resolver, 9/247 Work Host registry,
1/19 bootstrap repair and explicit Start, 1/3 changed-source refusal, 1/5 socket reason delivery,
14/58 pending-chat preservation, and 1/7 pending-Start recovery refusal. The bootstrap fixture
retains real input/prompt bodies, admits Start through JBS, and explicitly drains Hosted afterward;
it uses a test provider/store, not a paid-provider or user-chat round-trip. No current Linux or
remote-workflow receipt is claimed for this patch.

The packaging verification also caught a pre-existing relative-cwd bug: `bundle-app.sh` looked
up its Git commit relative to `app/` after changing directories, stamping `unknown`. It now uses
its captured absolute repository root. Final packaging must stamp the checkpoint actually built.

### Activity comprehension — 2026-09-10

The next bounded slice groups the existing chat-local action view into unsettled actions,
recorded problems, and completed outcomes. A failed historical action is not itself evidence that
the agent is blocked or that the human should retry. Retained actions on a disconnected or
incomplete projection must look last-recorded, not live. Counts describe the bounded view.

Child activity is a separate Work-wide summary of the latest recorded child lifecycle states,
using the already-gated working-state projection. It does not infer names, current Run ownership,
progress, result correctness, or runtime liveness. Child admission and settlement are produced by
AgentRunner; generic Python Futures are not covered. Handle lifecycle has no production callers
yet, so it is not advertised as a background-task inventory.

An audit ruled out an attractive but false action tree: production `parentActivity` links currently
connect an action's own intent/start/outcome observations, not separate parent/child operations.
Those links remain inspectable evidence; this slice does not turn them into a nesting hierarchy
or introduce the separately gated Phase 5 ownership/scheduler design.

The classification/bounds/source-quality suite passes 2 cases / 52 assertions; the full macOS
suite passes 1,056 cases / 14,968 assertions. The actual AppModel journey probe covers a
disconnect-only freshness change without erasing recorded child states. Wide, narrow, and stale
production-content fixtures were visually inspected, as was the signed app's real activity sheet.

The paid-provider GUI probe exposed an existing runtime defect: a real child reached durable
`done`, but the parent stayed blocked in `spawn(...).result()`. Callback replies accepted only
objects although `children()` returns an array. The isolated test was explicitly ended; after
terminating only its stuck runtime, its Python outcome was recorded as indeterminate and its
Run finished. Both Python hosts now preserve every JSON result shape, including falsey values;
an explicit sentinel distinguishes a pending callback from a valid null reply. Missing result
fields remain malformed. Real-host regressions cover result shapes, malformed/replayed replies,
and a spawn Future polling from running to done.

After rebuilding the signed bundle and restarting the local service, a fresh GUI chat spawned a
real child, displayed its running/finished lifecycle, and received the correct three-line result
in the parent within 13 seconds. Its Run was then explicitly ended and its runtime exited. The
isolated input file and the five pre-existing request/Work files checked before the test remained
byte-identical. The first hung test remains a recorded indeterminate outcome, not rewritten as a
success. No current Linux/remote receipt is claimed for this callback repair.

Two follow-on interaction defects surfaced in that real flow. The rail now preserves the title
of an exact attached chat when catalog attention is temporarily unknown; its canonical state stays
unknown and command routing still requires the original exact attachment. The journey probe
reproduces the actual exact-join/unknown-state cursor-lag shape, not only presentation flags.

End now retains a stable command identity across confirmation failure. An uncertain notice is
distinct from rejection and clears only when matching canonical acceptance/delivery is available;
foreign command evidence, incomplete reads, and unrelated draft/storage warnings cannot clear it.
The notice-policy suite passes 9 cases / 40 assertions, and the actual AppModel journey probe
passes the lost-confirmation/source-incomplete case after canonical End has caught up. No command
is automatically retried. Final broad and signed-GUI verification of these follow-ons is pending.

The next authorized slice is saved review history: expose older turn-linked repository observations
alongside the newest review, with exact descriptor/body selection. These remain whole-working-tree
observations, not attributed per-turn deltas or restorable checkpoints. Write-capable checkpoint
work and the separate Phase 5 Handle design remain outside this chat-first slice.
