# Visual understanding pass

2026-09-12 · first implementation slice complete; live-window acceptance pending unlock

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

The Mac locked before final live-window inspection. Do not describe the running GUI as updated:
after unlock, inspect for unsaved text, gracefully reopen the GUI only, and check the real chat
list, configuration controls, compact navigation, and Improve Aviary toolbar. Keep the daemon
running. The screenshot matrix and executable probes do not replace that acceptance check.

Most elapsed verification time was optimized Swift compilation. Disjoint UI ownership followed
by an explicit source freeze avoided shared-file build races; production-component fixtures
found the remaining contrast and narrow-layout defects without mutating live chats.
