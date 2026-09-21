# September 18: chat workspace feedback

## This GUI checkpoint

- Reclaim the redundant Chats window-toolbar row. Keep the chat list and conversation headers
  in their own panes; move global search/refresh to the sidebar without overlaying the composer.
- Add reversible, local Hide chat / Restore chat. Hiding affects list presentation only: it
  never stops or detaches Work, deletes a transcript, or discards a saved request.
- Put Steer and Queue in the editor's bottom action bar instead of separate delivery cards.
  The user's saved default determines the primary action and Return behavior. A click on either
  button selects that exact command; capability and delivery guards still apply.
- During an accepted-message/canonical-refresh transition, show confirmation progress instead
  of an alarming disabled-send explanation. Genuine delivery uncertainty and failures remain
  explicit and never trigger automatic retries.
- Call the turn's repository artifact **Recorded project state**, not **Saved changes**.
  It records the working tree, including unchanged states and edits from earlier work. The
  descriptor does not contain the artifact body's status, and the UI should not fetch all
  sensitive diffs merely to choose link text.

## Next vertical slice: direct commands

Ryan's requested behavior supersedes the previous Ask agent to run draft-only interaction:
execute the exact selected shell command on the Work Host, show its output in the conversation,
allow dismissal, and include retained command/output with the next user prompt. Do not merely
rename the old model-mediated action or launch an untracked shell from the GUI.

Implementation needs a real worker execution capability, replay-safe dispatch and status,
bounded/addressable output, explicit cancellation, and a durable pending-attachment lifecycle.
Only accepted user-input delivery consumes an attachment; uncertain delivery must reconcile
the original attempt rather than rerun the shell or attach it a second time. Dismissal removes
the pending model-context attachment, not the recorded execution history. See
[direct-user-commands.md](direct-user-commands.md) for the concrete service integration seams and
verification matrix.

The existing service and Python worker remain running during this UI-only checkpoint. The
direct-command capability must not appear on older services that cannot honor it.

## Verification

Debug Aviary and AviarySelfTest builds pass. Focused checks: chat visibility 10 cases / 23
assertions, chat interaction 10 / 104, service-command notice 11 / 60, service-backed drafts
12 / 193, suggested shell commands 7 / 35 (50 cases / 415 assertions total). Native editor
keyboard/IME/disabled-admission and saved-request journey probes pass. Accepted receipt
presentation covers both idle Send and busy Steer/Queue without changing command admission.

`just build` and strict deep signing pass. Signed native editor/journey probes also pass.
Live UI verification exercised Hide -> hidden list -> Restore on a saved request, restored
all five original rows, sidebar collapse/restore, and existing-chat project-state links.
No user request was sent or discarded; the existing daemon and Python runtime were not stopped.

The native-window pass caught two issues absent from offscreen fixtures: hiding windowToolbar
also hid standard window buttons, while a transparent toolbar intercepted pointer events in
the reclaimed header. Keep native chrome, use its space only for noninteractive headings, put
list options beside New chat, and preserve the safe area for compact navigation. The relocated
menu was verified with a physical pointer click, not only an accessibility action.

The 380-pixel busy-composer fixture was visually inspected. Fixture rendering is not a live
provider-turn/transport proof. This checkpoint does not claim a full-suite or Linux run.

## Follow-on implementation

The subsequent Work-Host-owned direct-command slice, Flock interaction refinements, and activity
copy pass are documented in [direct-user-commands.md](direct-user-commands.md), including their
new verification receipts. The preceding UI-only checkpoint remains a historical receipt;
its service-lifetime and test boundaries do not describe the later deployment.

## Startup presentation follow-through — 2026-09-21

The saved request and attached conversation no longer need separate normal-path rail cards.
The pending card collapses only when exactly one visible live attachment has the complete same
client/Work/Session/attachment identity. A selected recovery card, local-save error, uncertain
command, or ambiguous match keeps it visible. This changes no durable retirement or command
admission rules; the saved request remains until exact canonical delivery and local cleanup pass.
When multiple saved requests share an association, none is automatically retired. Each keeps its
own recovery card; otherwise retiring a delivered member could hide a different unsent survivor.

The saved-prompt fallback above chat disappears when that exact Start input is already in the
currently rendered transcript window. Equal text, another user message, a receipt, or a delivered
message outside the visible history window is insufficient. Check/retry controls remain separate
from the prompt fallback, so removing a duplicate cannot remove recovery actions.

A retained card after proven delivery says **Request delivered**, offers **Open conversation**
first, and distinguishes local cleanup from delivery uncertainty. **Refresh saved status** refreshes
the exact existing attachment before cleanup, with initial-Start resumption disabled. It does not
issue another Start merely to refresh presentation.

The live cleanup check also caught a stale **Ending** composer after the journal and header
already showed the Run had finished. Releasing the local output-cleanup barrier now immediately
resynchronizes presentation from the service bridge. An actually ending or uncertain host remains
authoritative; this does not manufacture an End success or retry the command.

Verification for this follow-through: 55 focused cases / 371 assertions pass across startup
presentation, pending-chat recovery, hiding, composer policy, notices, and GUI controls. Debug
compile, signed release build, strict deep signing, and signed editor/saved-chat journey probes
pass. The signed healthy OTLP journey records 159 spans and exactly two loopback provider calls;
disabled and unreachable collector journeys each also complete with exactly two calls. The
retained-card recovery check uses the real AppModel action, retires its disposable marker, and
proves the Work still has exactly one Start command. The probe also checks the End overlay
immediately after command completion and after canonical settlement.
Its collision fixture first settles the ordinary startup card, then retains a delivered request
beside a different unproven one. A real AppModel refresh must keep both reachable; only explicit
local dismissal resolves the collision before the delivered card's ordinary recovery check.

On the unlocked Mac, physical clicks exercised two disposable Start/reply/End chats: one visible
rail entry and one prompt as the saved fallback becomes a canonical input. The post-fix End
check returned to an ordinary composer, with `run.finished` at Work sequence 20. Both chats were
ended and hidden, the five original rows remain, and the two original saved-request files are
byte-identical. No full-suite, Linux, or remote-backend rerun is claimed for this narrower slice;
the preceding full-suite receipt remains in direct-user-commands.md. Work paused at this checkpoint
at Ryan's request; the existing service was left running and no original Work was restarted.
