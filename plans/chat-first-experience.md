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
