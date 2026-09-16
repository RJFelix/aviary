# Real-use feedback: chat-first refinement

Ryan's September 15 walkthrough is the acceptance input. Prefer direct editing, quiet normal
operation, and visible actions to explanatory prose. Existing journals and delivery checks stay
authoritative; a calmer screen must not imply receipt or successful execution.

## Current implementation slice

- Compact “What next?” launcher; request + send toolbar form one component. Remove the inline
  New chat/Cancel header, explanatory captions, and separate project-settings expando.
- Project/provider/model/thinking directly editable; folder chooser can create directories.
  Engine temporarily under Advanced pending the provider-route choice.
- Native plain-text message editor: Return sends, Shift-Return newline, marked-text/IME guard,
  shared caret/placeholder geometry. Remove separate Markdown preview.
- Quiet normal sending across the GUI's pre-controller barrier and the controller request.
  Accepted receipt catch-up is not an error. Immediately focus the exact created chat; retain
  pending prompt and recovery metadata until exact canonical delivery is proven.
- Move Improve Aviary to sidebar footer; remove routine catalog spinner/count from toolbar.
  Chat title uses the window header. Settings metadata reads as static text, not fake controls.
- Named Agent activity and Details buttons, Stop with existing precise help, inspector Done.
  Action details first show purpose/target/outcome; journal references are secondary disclosure.
- Visible verbatim authored-message copy. Forward to an attached chat's empty draft, ordered
  same project then recency, with explicit selection and no automatic send or draft overwrite.
- Flock full-row interaction, vertical metrics, labelled running-only filter.

## Follow-through / explicit remaining boundaries

- Configurable full-request log directory: resolve once per Run on the owning host, carry the
  actual locator to inspection, preserve old log discovery, and don't advertise a GUI-local
  preference as changing a remote host. Existing checkbox records provider requests, not a
  guarantee that all runtime effects or provider-private thinking are captured.
- Markdown editing in-place and selection across rendered blocks: native rich-text integration
  needs a separate renderer/editor pass. Copy message is the exact cross-block fallback now.
- Execute suggested shell commands: explicit action with visible command, project, destination,
  and output/cancellation lifecycle. Never infer permission to execute text merely by rendering
  a model response. Do not bolt an untracked shell onto the GUI-owned chat.
- Provider progress: show supplied summaries when available; some providers deliver no visible
  reasoning summary. Do not invent progress or expose hidden chain of thought. Current action
  and elapsed state remain the honest fallback.
- Activity: lightweight task-oriented overview first; retain the full diagnostic view separately.
- History: broader recorded/imported transcript browser, not another competing live-chat home.
  Consider a detailed layout of Chats later; preserve valuable external transcripts read-only.
- Library: retain and deepen the unified inventory of skills, integrations, and project context.
- External-agent forwarding requires real discovery/addressing. Initial forwarding lists only
  attached Aviary chats and prepares a draft; it does not claim Claude Code/Codex interoperability.

## Verification

Freeze shared edits before SwiftPM. Test active-attempt vs actual uncertainty, exact pending
association focus, no duplicate send, native key events/IME, copy fidelity, and safe forwarding.
Inspect production-component fixtures at narrow/wide sizes. Build and strictly verify the signed
bundle before handoff. GUI reload is separate from service restart; do not interrupt Ryan's
active Work to demonstrate a presentation fix. Record actual receipts after completion below.

### Debug verification receipt

- Aviary and AviarySelfTest products build; 35 focused cases / 482 assertions pass (chat
  interaction, message transfer, action presentation, saved requests, GUI control policy).
- Native editor probe passes viewport/inset, Return/Shift/Command/keypad/repeat, disabled-send,
  IME, exact draft transfer, and existing/whitespace draft preservation checks.
- Chat journey/consumer probe passes, including saved request, exact association focus,
  active-attempt vs lost handoff, accepted catch-up, and non-mutating read boundaries.
- Inspected launcher at 640 dark / 380 light and active conversation at 1100 dark / 520 light.
  These are production-component fixtures, not proof of the installed window's hit targets.
- The existing GUI and daemon remained running. Of the old 141-file preservation baseline,
  140 still match; workspaces.json differs after real-use project setup. No baseline files were
  restored or rewritten. Both protected pending requests still match exactly.
- Signed bundle and live reload are separate final checks; a service restart is not required.
