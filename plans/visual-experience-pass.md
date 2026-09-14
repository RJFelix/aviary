# Visual understanding pass

2026-09-14 · first slice inspected live; historical startup-message correction in verification

Ryan's direction: intuitive and simple, not austere; learn through visual structure, with text
reinforcing meaning. This pass changes presentation, not Work ownership or delivery semantics.

## Observed starting point

The installed Chats screen gives four setup panels equal weight. The task editor, project,
execution engine, and model compete with one another; the primary action is detached at the
bottom of the window. Small, low-emphasis explanatory text does most of the teaching. Saved
requests needing attention resemble ordinary chat metadata. The two-column chat workspace does
not adapt to a narrow detail area.

## Visual grammar

- The request is the primary object. A bounded composition canvas groups the task and its action.
  Project and model stay visible; their configuration unfolds deliberately.
- Location communicates delivery: a saved request on this Mac is distinct from an agent receipt.
  Unknown delivery uses a question mark and explicit text, never a completed connection or a
  percentage. Conversation creation alone is not proof the initial request was received.
- Shape and placement carry state alongside color: saved tray, interrupted pause, uncertain
  question, warning, working activity, and completed outcome. Text labels remain accessible.
- Actions have recognizable kinds and clear outcomes. Evidence is available on demand; a missing
  explanation must not become an invented intention or a permanent warning wall.
- The conversation gets the space. Narrow windows exchange the chat list for a back-to-list
  control, instead of compressing both surfaces.

## First implementation boundary

1. Production launcher composition hierarchy and discoverable configuration.
2. Saved-chat location/status presentation and chat-list attention cues.
3. Activity strip and action rows: kind, state, subject, outcome, then evidence.
4. Production-component fixtures at wide and narrow widths; signed build and saved-request
   journey regression. Fixtures are visual evidence, not proof of service execution.

## Following passes

Review the busy composer, accumulated status banners, transcript rhythm, change-review flow,
background-agent relationships, and Workshop against the same grammar. Keep these as bounded
passes with screenshots and interaction checks; do not introduce another execution model or
replace meaningful detail with decorative diagrams.

## Acceptance checks

- The task and primary action form one visual group; project/model changes are discoverable.
- Saved versus received is understandable without reading a paragraph, and never overstated.
- Status is not color-only; essential labels remain legible and keyboard-accessible.
- Wide/narrow layouts show full recovery controls and do not overlap the composer.
- Unknown, stale, omitted, and historical evidence remain explicitly distinct from current work.
- No request is sent, retried, edited, or discarded merely by opening a screen.

## First-slice results

Implemented the composition canvas, project/agent summary with expandable setup, adjacent Start
action, visually distinct saved/delivery states, selected/attention chat cards, compact list/detail
navigation, action-kind glyphs and outcome badges, current-first activity, and explicit stale
presentation. Improve Aviary now keeps its toolbar text label. Semantic colors have separate
light/dark inks. Essential evidence and recovery controls remain available.

Review also exposed a nonvisual launcher problem: interacting engine/provider callbacks could
fight one another or lose a model choice. The launcher now uses one pure selection state with
explicit transitions, route-compatible models, remembered choices, and catalogue reconciliation.
The executable chat-journey probe covers these transitions as well as the saved/uncertain state
presentation. No service/protocol changes were needed.

Verification performed:

- Debug Aviary build and executable chat-journey/consumer-read probes pass, including exact save,
  blocked startup, relaunch, edit/retry, failed save, and no read-state mutation.
- Production-component renders inspected at 1200, 640, 520, and 380 points, in light and dark:
  launcher, blocked request, created-but-unconfirmed request, action overview, and narrow activity
  strip. Final local images are under `build/ui-pass-final/`. They are deterministic fixtures,
  not live-service screenshots or proof of keyboard/screen-reader behavior.
- Release bundle and strict deep signature verification pass. A signed disposable normal-service
  final journey passes Create/Start/Python/review/End with 94 exported spans and two fixture provider
  calls. No paid model or user's saved request is used in that journey.
- All 141 protected file hashes from the prior service-cutover receipt still match. The existing
  GUI and agent service remain running; no saved prompt was replayed.

The Mac locked before the initial live-window check. On September 14 the new GUI was already
running; the actual chat list, expandable configuration, model picker, connection details and
Improve Aviary entry point were checked without sending, editing or discarding a request. Both
saved cards remained visible and all 141 protected hashes matched. Compact navigation and active
conversation layout still have fixture rather than interactive live acceptance in this pass.

That live check found a stale diagnostic: a saved failed-start card described the service as
currently unavailable despite a connected service. The correction describes the previous startup
attempt, including model/folder/authorization failures. It does not infer execution readiness
from connectivity or automatically retry. The executable probe checks historical wording under
connected/disconnected diagnostics and preserves the original saved identity.

## Active-chat status hierarchy scope

The production RunPane can stack project/read failures, command receipt notices, stop receipt,
projection bounds, input-delivery bounds, current action and child/background summaries above
the transcript. Give these one coherent visual hierarchy: what needs the user's attention,
current activity, then secondary evidence. Do not collapse unknown delivery into success, hide
actionable recovery, or let informational notices consume the conversation's working area.

Then continue transcript and change-review readability. Preserve the existing editor identity, draft save/handoff guards,
explicit send, selected history window, canonical evidence and stop/end distinction. Verification
must exercise the actual RunPane with overlapping failures and incomplete evidence, not only the
normal happy-path fixture. No execution-model changes are needed for this presentation work.

Most elapsed verification time was optimized Swift compilation. Disjoint UI ownership followed
by an explicit source freeze avoided shared-file build races; production-component fixtures
found the remaining contrast and narrow-layout defects without mutating live chats.

## Busy composer and activity freshness — September 14

The busy composer now shows Follow-up message and Guide current work as visible, icon-led
choices with timing cues. They adapt from adjacent cards to stacked cards in narrow panes;
one available route is a static card and no route is explicitly Draft only. Choices use the
existing capability policy and submission path. Guidance remains a one-message override;
changing a choice never sends or rewrites the draft.

Sending restrictions now have a single policy with ordered, specific explanations adjacent to
the editor: unresolved handoff, unconfirmed receipt, ending/stopping/starting, failed or denied
input, and unavailable routes. An empty draft is informational rather than a warning. The
duplicate receipt-confirmation banner above the transcript is removed; detailed draft recovery
controls remain intact. Service-backed noncurrent status reads Last recorded and has no live
pulse or typing tail. Visual freshness is separate from incremental transcript following.

Verification:

- Chat interaction policy: 6 cases / 62 assertions; draft persistence and handoff: 12 / 193;
  service control receipts: 6 / 26. Debug and release builds pass, as does strict deep signing.
- Signed saved-chat/consumer-read probe passes. The signed disposable normal-service OTLP journey
  passes Create/Start/Python/review/End/drain with 99 spans and two fixture provider calls
  (6.873 seconds through cleanup). Queue/Steer/Stop and remote execution are not covered by that
  journey; this slice does not change their command implementation.
- Actual RunPane fixtures cover two, one and zero routes, receipt confirmation and unresolved
  handoff, in light/dark at 1200/640/380 points. A separate stale-activity fixture uses the
  production status policy, activity strip and transcript at 520 points. Images were inspected
  under build/ui-composer-final. These do not certify a live user's busy session, keyboard or
  screen-reader interactions; the handoff fixture does not have a real service attachment.

The following pass addresses the overlapping-notice hierarchy, transcript rhythm and change-review flow.
No daemon restart, command retry or saved-request submission is part of deploying this GUI slice.

## Status, transcript and review readability — September 14

Implemented one compact chat-status panel instead of stacked command/error/omission banners.
Uncertain commands and actionable failures lead; current acknowledgements lead prior Stop
receipts and secondary display bounds. Details retains every independent source's full text.
An exact project diagnosis replaces its generic recovery error, and project checks/confirmation
and delivery review remain directly accessible. This is presentation only: no notices are
dismissed, no receipt is reconciled and no command is retried by opening the panel.

Transcript rows now use restrained role surfaces and spacing, keeping each user message distinct
and only tightening assistant continuations when model/provider match (agent messages require
matching sender). IDs, history anchoring, live-follow behavior, raw inspection, usage, delivery
evidence and error markers remain. The current activity tail and earlier-history controls have
clearer visual affordances.

Review puts the actual diffs ahead of secondary file/HEAD metadata. A visible partial-observation
label and the original detailed exclusions remain; staged/unstaged and file/hunk Comment buttons
have distinct visual cues. Bounded parsed hunk lines show additions/removals with color and their
original prefixes, preserving exact copy content, unknown markers and Unicode separators.
Expanded hunks scroll rather than hiding lines. Raw fallbacks remain raw, and feedback still
prepares a draft only; no new file mutation or Send action was introduced.

Verification: debug Aviary, AviarySelfTest and aviaryd builds pass; interaction 8 cases/84
assertions, command notice 10/49, control result 6/26, draft persistence 12/193, diff projection
5/50 and repository observation 12/121 pass. The executable saved-chat/consumer-read probe passes,
including actual AppModel notice mapping, project specialization and nonmutation. Read-only Sol
review found no remaining lifecycle/identity blockers. Fixtures under build/ui-readability cover
overlapping notices, full details, light/dark transcript and review, expanded hunks, stale review
and a full composer. The stale-review fixture has a 560-point minimum; its acceptance render is
640 points, not the deliberately undersized 380-point clipping diagnostic.

The release bundle and strict deep signature check pass. Its saved-chat/consumer-read probe passes;
the signed disposable normal-service journey passes Create/Start/Python/review/End/drain with
102 exported spans, two fixture provider calls and 6.366 seconds through cleanup. This is not
live-user Queue/Steer/Stop, remote-backend, or accessibility interaction coverage.

The next useful checkpoint is a real user's short coding session: notice whether the current
activity and message destination are obvious, load earlier history, review a file/hunk and place
feedback in the composer. Isolated fixtures/probes cannot certify that this feels natural during
real work, nor replace keyboard and screen-reader acceptance. Further broad UI redesign should
be informed by that feedback rather than adding more surfaces without observed need.
