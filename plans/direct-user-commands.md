# Direct user commands: one Work-Host-owned vertical slice

Status: design checkpoint for the next implementation slice. The preceding GUI-only feedback
checkpoint is [user-flow-feedback-2026-09-18.md](user-flow-feedback-2026-09-18.md).

## Outcome

Replace **Ask agent to run** on a closed assistant `sh`/`bash`/`zsh`/`shell` fence with an
explicit **Run command** confirmation. The selected bytes execute once on the Work Host in the
chat's retained workspace, without a model turn and without asking the Python runtime to call
`sh()`.

The conversation shows one command card while the command is running and a bounded result when
it settles. Closing the GUI does not stop it. The result remains pending across GUI reconnects;
the person can dismiss it with X, or leave it to be prepended as a collapsed
`<aviary-command-output>` block to the next accepted user input. Dismissal removes the pending
model-context attachment, not the execution/action history.

This slice deliberately provides completion output, not live terminal emulation. It supports one
direct command at a time per Work, a finite host-wide concurrency limit, and an explicit Stop.
Commands run until they exit or are stopped unless the person explicitly chooses a duration limit
in the confirmation sheet; a development server must not be killed by a hidden default timeout.

## Why this is a separate worker

`RuntimeHost.execute` serializes Python cells per session, but the injected `sh()` starts a
background Future. Shell Futures may overlap, snapshot shell state at launch, and use
last-finisher-wins cwd/environment write-back. Calling that path from the GUI would share mutable
Python/session state with the agent and still would not provide an independently addressable
process tree.

The direct-command worker instead launches a fresh shell process from `aviaryd`. It uses the
Work's retained workspace and the daemon's captured login-shell environment, but it never enters
the RuntimeHost namespace. This prevents Python namespace/cwd/environment corruption. It is not a
filesystem sandbox: a background process previously started by the agent may still race the same
repository, and the confirmation must not claim otherwise.

## Canonical contract

### Typed values and limits

Add Core values rather than encoding a shell request into the generic `value` string:

- `DirectShellLanguage`: the existing allowlist normalized to `sh`, `bash`, or `zsh`; `shell`
  maps to `sh` at the UI/Core parsing boundary.
- `WorkServiceDirectCommandRequest`: Work/journal/client attachment, Session attachment,
  caller-local command ID, exact causal Work cursor, language, exact source bytes, and an optional
  person-selected duration limit.
- `WorkServiceDirectCommandReceipt`: caller command ID, host-derived `ActionRef`, accepted /
  duplicate / rejected disposition, canonical acceptance/action cursors, authorization, and
  optional terminal result descriptor.
- `WorkServiceDirectCommandStopRequest`: the original `ActionRef`, a distinct stop command ID,
  and its own exact causal Work cursor.
- `DirectShellCommandResult`: schema/version, action and command identities, language, exact
  command, terminal status, exit code or signal, start/end/duration, typed stdout/stderr captures,
  retained and omitted byte counts, and truncation flags. Each capture stores bounded `Data`
  segments (JSON base64), not an assumed UTF-8 `String`; presentation may decode valid UTF-8 and
  otherwise labels/attaches base64 without silently changing bytes.
- `DirectCommandContextManifest`: a bounded list of exact result artifact ID, digest, and action
  references captured with the next Send. This is typed metadata, not command/output text placed
  in `WorkServiceCommandRequest.value`.

Keep the existing 16 KiB `SuggestedShellCommand.maximumSourceBytes`. Retain at most 64 KiB per
output stream (a deterministic head/tail split), while continuously draining both pipes so output
volume cannot deadlock the child. Bound the encoded result well below the existing 8 MiB artifact
ceiling. Permit one command per Work and at most four across one daemon. A requested duration limit
is itself bounded and journaled; absent that explicit option, only process exit, Stop, End, or host
loss terminates the command.

Bound pending model context separately from artifact retention: no more than eight pending results
and 256 KiB of retained stream bytes per exact Work/Session attachment. Admission reserves the new
command's worst-case 128 KiB, so it refuses before launch when the pending budget cannot
accommodate the result. The person can send or dismiss existing results to release that budget;
historical artifacts remain.

### Authorization and negotiation

Add separate `runDirectCommand`, `stopDirectCommand`, and `manageDirectCommandContext`
capabilities. Require the exact authenticated client attachment and active Session attachment for
every mutation; a `WorkRef` is never authority. Add the new request/response operations to the
socket transport and bump the exact Work-service protocol version. The GUI offers Run only when
the attached projection grants `runDirectCommand`; an older daemon therefore cannot display a
control it cannot honor.

The current local socket authorizer may grant requested capabilities after its same-user socket
check. The capability split remains necessary for remote/principal-backed authorizers and for
least-authority attachments.

### Exactly-once effect admission

The host qualifies the caller-local command ID with `WorkServiceCommandLedgerIdentity`, then
derives the action ID from that qualified identity. One command ID binds all of: client, Work,
Session attachment, causal cursor, shell language, and SHA-256 of the exact command bytes.

Before launching a process, one `RunJournalBundle` semantic-gate operation must:

1. validate an active, idle Run owned by this Session attachment and a current causal cursor;
2. retain the exact typed request body in the Work body store;
3. append canonical command acceptance; and
4. append `action.intent` plus `action.started` for a new `direct_shell` `ActionKind`.

Only a fully returned durable start permit may cross into process launch. An identical retry
returns the same action/receipt. Reusing the ID with different bytes or envelope fields is
`conflicting_command`. A lost response is reconciled from the journal and never launches a second
process. After daemon loss, a nonterminal direct-shell action is recovery-required and is never
redispatched automatically.

### Process ownership and Stop

Add a `DirectShellCommandWorker` actor owned by the Work Host and retained by the live
`HostedInHouseWork` entry. It launches a fixed executable (`/bin/sh`, `/bin/bash`, or `/bin/zsh`)
with `-c` and passes the command as one unchanged argv value. It sets the retained workspace as
cwd, uses the Work Host's `ProcessEnvironment` snapshot, supplies null stdin, creates a dedicated
process group with `posix_spawn` process-group attributes (not a racy post-launch `setpgid`),
drains both output pipes, and reaps the child.

Stop durably admits a separate command and records the action's `cancel_requested` transition
before signalling the process group. Send TERM, wait two seconds, then KILL the group if needed;
only reaping establishes the terminal `canceled` outcome. An exact Stop retry reconciles the
existing stop receipt. End must stop and await an active direct worker before it closes the Run
journals. New Send/Steer/Queue/direct-run requests are rejected while this direct action is active.

Do not use `Shell.run` unchanged: it captures unbounded output and only owns the root `Process`,
so its cancellation cannot honestly promise to stop descendants.

### Result retention and next-prompt attachment

On settlement, retain one artifact with media type
`application/vnd.aviary.direct-shell-result+json`, a deterministic ID derived from the action,
and exact action-start provenance. Publish the artifact before the terminal action outcome. The
artifact exists for success, nonzero exit, timeout, and user cancellation; infrastructure loss
without a trustworthy result ends as `indeterminate_effect` and must not fabricate output.

Pending prompt context is a projection, not deletion of the artifact:

- A terminal direct-command result artifact published by this exact Work under its active Session
  attachment is pending for that attachment unless a later Session event dismisses it or an
  accepted input on the same attachment names it as consumed. Another Work attached to the same
  Session neither inherits nor consumes it implicitly.
- X sends an idempotent, capability-checked dismiss request and appends a bounded Session
  tombstone naming the artifact. The Work action/artifact remains inspectable.
- The next Send carries a `DirectCommandContextManifest` of the exact pending descriptors shown by
  the GUI. The ordinary `value` remains only the person-authored prompt and stays within its
  existing 8 KiB wire limit. At admission, the Work Host requires the bounded manifest to match
  canonical pending state, then loads each content-addressed result body separately and validates
  its digest, schema, provenance, and aggregate byte budget.
- After that validation, the Work Host prepends one escaped `<aviary-command-output>` block per
  result to the model input and writes the typed artifact/action references on the same
  `input.accepted` event. That single canonical event is both delivery input and consumption
  evidence. Valid UTF-8 stream bytes are included as text; a non-UTF-8 capture is represented with
  an explicit base64 encoding attribute rather than lossy text.
- A failed pre-admission send consumes nothing. An accepted-but-uncertain send is reconciled by
  its original command ID; retry cannot attach the result twice or run the shell again.

This shape reuses `PromptText.split` and `InjectedContextBlock`: the transcript can show the
machine-added block collapsed while keeping the visible user text clean. The separate pending
command card loads only this small, typed result body and can disappear after dismissal or
canonical input consumption.

## Smallest code seams

- `AviaryCore/SuggestedShellCommand.swift`: retain exact source and expose the normalized typed
  shell language; remove draft-text construction once direct execution lands.
- `AviaryCore/WorkService.swift`: capabilities, typed requests/receipts/results, client methods,
  and protocol-version bump.
- `AviaryCore/WorkServiceTransport.swift` and `WorkServiceClientSession.swift`: bounded wire
  operations and authenticated client identity checks.
- `AviaryCore/RunJournalBundle.swift`, `TimelineEvent.swift`, and reducer transitions: atomic
  direct-action admission, cancel-request transition, result artifact provenance, dismissal, and
  `input.accepted` consumption identities.
- New `AviaryCore/DirectShellCommandWorker.swift`: process-group lifecycle, bounded collectors,
  optional requested deadline, Stop, and typed result construction.
- `AviaryCore/HostedInHouseWork.swift`: retain the worker, serialize it against agent commands,
  journal every action, and include it in End quiescence.
- `AviaryCore/JournalBackedWorkService.swift`: capability/attachment/cursor validation, exact
  retry reconciliation, registry lookup, and result/dismiss endpoints.
- `AviaryCore/WorkActionPresentation.swift` plus the attached-Work projection/controller: expose
  bounded direct-command state and pending result descriptors without parsing them in SwiftUI.
- `Aviary/ServiceBackedRunBridge.swift` and `AppModel.swift`: submit/stop/dismiss operations using
  the existing per-Work command barrier and refresh scheduling.
- `Aviary/SuggestedCommandSheet.swift`, `MarkdownBlocks.swift`, `LiveView.swift`, and
  `TranscriptView.swift`: Run confirmation, running/result card, Stop, X dismissal, and capability
  gating. Capture the originating `LiveRun` exactly as the current sheet does.
- `aviaryd/main.swift`: compose the host-owned worker/coordinator and include its finite limits.

### Telemetry

Wrap admission and execution in `aviary.work.direct_shell` spans. Record only hashed
Work/Session/client/action/command identities, the shell enum, input/output byte counts,
truncation, duration, and terminal category. Emit canonical-reference attributes after the
acceptance, action-start, result-artifact, cancel-request, and action-outcome commits. Never put
the workspace path, command, stdout, stderr, environment, or raw error in OTel.

## Verification matrix

| Boundary | Required proof |
|---|---|
| Parsing/UI provenance | Only closed assistant shell fences are actionable; exact Unicode/newlines and originating `LiveRun` survive; quoted/user/tool/output/streaming fences remain inert. |
| Authorization | Missing run/stop/context capability, detached client, wrong Session attachment, foreign Work, and self-claimed client all fail before an effect. |
| Retry identity | Same request after lost response returns one action/process; same command ID with changed source, language, cursor, client, or attachment conflicts. |
| Cursor races | Two attached clients at one cursor produce one accepted order and an explicit stale/conflict result; no silent latest-cursor retry. |
| Process semantics | Exact bytes reach the selected fixed shell in the retained cwd/environment; stdin is closed; exit, signal, an explicitly requested timeout, and launch failure are distinct; without a requested limit, a long-running server continues until Stop/End/exit. |
| Output bounds | Multi-megabyte stdout and stderr are fully drained, deterministically truncated, byte counts remain truthful, and the retained artifact stays within its declared limit. |
| Stop | Stop records request before TERM, escalates to process-group KILL, reaps descendants, is idempotent, and reaches terminal cancellation before End closes journals. |
| GUI disconnect | Start, close the client, reconnect with the same or another authorized client, observe one continuing action and one terminal result; no GUI-owned Process survives in the app. |
| Daemon loss | A started but unterminated journal action returns recovery-required/indeterminate and is never automatically relaunched. |
| Python isolation | A live or retained Python namespace is unchanged by direct execution; direct commands never call `RuntimeHost.execute` or mutate persistent `sh()` cwd/environment. |
| Pending context | Result reappears after GUI restart; X durably hides only the pending attachment; action/history remains; count and aggregate-byte admission bounds prevent unbounded next-prompt context. |
| Send consumption | The wire value remains the original prompt; a bounded exact-reference manifest selects separately retained bodies. Rejected or stale-manifest Send consumes nothing; accepted Send prepends exactly once and records typed artifact/action refs on `input.accepted`; lost response plus retry neither duplicates context nor reruns shell. |
| Presentation | Running, stopping, succeeded, nonzero, timed out, canceled, and indeterminate states are distinct; no copy claims filesystem isolation or that changes belong to the command/turn. |
| OTel/privacy | Spans correlate canonical commits and bounded counts; command/output/path/environment bytes never leave journals/artifact storage. |
| Compatibility | New GUI hides Run against a host without the capability; exact protocol mismatch is explicit until the bundled daemon is restarted. |

Run focused Core/self-tests for every row, the native chat-editor probe, a real disposable
`aviaryd` disconnect/reconnect/Stop journey, and visual fixtures at narrow and wide chat widths.
Then run `just test`, `just build`, strict deep signing verification, and an identity-fenced live
service handshake. Keep fixture, signed-app, and real-service evidence separate.

## Explicit boundaries

- This is direct shell execution with the same host/user privileges as the agent, not a sandbox,
  approval framework, terminal emulator, or attribution engine.
- The slice survives GUI disconnect, not Work Host process loss. Durable evidence prevents replay;
  it cannot reconstruct an in-flight OS process after daemon death.
- It does not merge command output into an assistant message. A model sees it only when the person
  sends the next prompt with the pending attachment still present.
- It does not claim exclusive access to the repository. Avoiding the Python runtime prevents
  interpreter-state corruption; unrelated/background processes may still mutate shared files.
