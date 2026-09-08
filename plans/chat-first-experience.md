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
