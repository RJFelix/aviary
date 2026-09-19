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
