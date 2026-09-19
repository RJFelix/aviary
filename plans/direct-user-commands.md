# Direct user commands: implemented Work-Host slice

Status: implemented on 2026-09-18. This document describes the
implementation rather than the earlier proposal. The preceding GUI feedback checkpoint remains in
[user-flow-feedback-2026-09-18.md](user-flow-feedback-2026-09-18.md).

The implementation has passed the focused direct-command, native-resume, and real daemon
journeys below. Full-suite and signed-app verification are recorded separately; none of these
receipts is a sandbox or process-containment claim.

## User-visible behavior

A closed assistant `sh`, `bash`, `zsh`, or `shell` fence can open an explicit **Run command**
confirmation for its originating chat and workspace. Confirmation sends a typed direct-shell
request to the attached Work Host. It does not create a model turn and does not route through the
agent's Python runtime or its `sh()` helper.

The chat shows authoritative command activity returned by the Work Host:

- a running card with **Stop**;
- a terminal card with bounded stdout and stderr, exact byte counts, truncation/incomplete-capture
  labels, and a distinct outcome;
- an X on pending terminal output, meaning “do not include this output with my next message.”

Commands have no hidden default deadline. The person may set a positive duration limit of at most
seven days; otherwise the command runs until it exits, Stop is accepted, or the Run ends.
Work Host loss makes the outcome and remaining process state indeterminate; it does not prove
termination. Closing or disconnecting the GUI does not cancel the host-owned task.

This is completion-output UI, not an interactive terminal. stdin is `/dev/null`; there is no PTY,
live input, resize protocol, or terminal-state emulation.

## Implemented service contract

### Additive protocol-v5 capability

The feature is additive to `WorkServiceProtocol.currentVersion == 5`; it did **not** introduce a
new protocol version. `WorkServiceCapability.directShell` gates the mutating Run, Stop, and Dismiss
operations. Inspect requires the existing `.observe` and `.inspectArtifacts` capabilities.

An older v5 Work Host does not advertise `.directShell`, so the GUI must not offer Run against it.
Compatibility here is capability-based, not a version-mismatch guarantee. A bundled service still
has to be restarted before a newly built GUI can observe the new capability.

The typed API is:

- `DirectShellLanguage`: fixed `sh`, `bash`, or `zsh`; an authored `shell` fence normalizes to
  `sh` before submission.
- `WorkServiceDirectShellRequest`: exact Work journal, client attachment, client-qualified command
  identity inputs, Session attachment, causal Work cursor, Run, operation, and operation-specific
  source/language/duration/action fields.
- `WorkServiceDirectShellOperation`: `run`, `stop`, `dismiss`, or `inspect`.
- `WorkServiceDirectShellResponse`: authorization, disposition, resulting Work cursor, diagnostic,
  and at most eight validated `WorkServiceDirectShellEntry` values.
- `DirectShellCommandResult`: exact source and identities, terminal status, dates, and binary-safe
  bounded captures for stdout and stderr.

The normal user-message command value remains the person-authored text and retains its existing
wire bound. Command output is not concatenated into a GUI-authored request or passed through a
client-selected attachment manifest.

### Authorization and exact ownership

The service authenticates the request's client attachment, requires control plus `.directShell`
for mutations, verifies the exact Session attachment, rejects a conflicting live Session owner,
and binds Run/Stop to the canonical active Run owned by that Session. A `WorkRef` alone is never
authority.

Inspect is deliberately narrower than a general historical artifact read. It requires a canonical
cursor and the exact currently resident `HostedInHouseWork` actor for the canonical Work/Session
binding. If that actor is not live and exact, Inspect returns an explicit unavailable response; it
does not reconstruct command-tray state from an arbitrary or stale hosted object.

### Replay and effect admission

The service qualifies the caller-local command ID with `WorkServiceCommandLedgerIdentity`. Run
reconciliation binds that qualified identity to the client, causal cursor, active Run, language,
exact source bytes, and duration limit. An identical retry returns the journal-derived prior entry;
reuse with different bound fields is rejected.

Before launching a shell, `RunJournalBundle.admitDirectShell` requires the current idle Run and
Session, retains the typed request body, commits `command.accepted`, and begins a `direct_shell`
action. Only the returned `EffectPermit` crosses into process launch. A crash between command
acceptance and `action.started` is not treated as launch permission.

The current implementation does not automatically redispatch a journaled nonterminal action after
daemon loss. It also cannot recover or reattach to the original operating-system process.

## Host-owned worker and output

`HostedInHouseWork` owns one `DirectShellCommandWorker`, its task, and its Action identity. It only
admits Run while the agent is idle, prevents another direct-shell mutation from crossing
concurrently, and prevents ordinary model commands from crossing while the worker is active.
An accepted End directly asks any active worker to stop and awaits the worker task before
journal closure.

The GUI's End confirmation explicitly offers **End and remove command output** when a command
is running or output is waiting for the next message. That path inspects, stops if needed, waits
for settlement, and durably dismisses pending output before sending End. Failure leaves End
unissued. Plain GUI End refuses pending output rather than silently making its controls unusable.
Other protocol clients may still End while retaining output; those clients own that decision,
and retained output crosses the next accepted input after a replacement Run starts.

The worker:

- launches only `/bin/sh`, `/bin/bash`, or `/bin/zsh` with `-c` and the confirmed UTF-8 source as
  one argv value;
- uses the retained workspace cwd and the Work Host's captured process environment;
- creates a new POSIX process group at spawn time;
- continuously drains stdout and stderr outside Swift's cooperative executor;
- keeps deterministic head/tail captures of at most 64 KiB per stream and records total,
  omitted, truncation, and completeness facts;
- enforces a host-wide concurrency gate of four workers;
- distinguishes success, nonzero exit, signal, explicit cancellation, explicit timeout, invalid
  request, launch failure, and indeterminate worker failure.

The terminal `DirectShellCommandResult` is retained as a content-addressed
`application/vnd.aviary.direct-shell-result+json` artifact before the action outcome is committed.
The artifact retains the original binary stream bytes. The UI renders valid UTF-8 directly and
base64-labels binary captures. The model-facing `<aviary-command-output>` projection instead uses
explicit UTF-8 replacement (`String(decoding:as:)`) for retained binary bytes; it is a readable
projection, not byte-for-byte reproduction. The referenced artifact remains the binary source of
truth.

## Stop, Dismiss, and next-input consumption

### Stop

Stop is a separate, client-qualified Work command. Its acceptance is durably recorded before the
worker receives the stop request. The worker signals its process group and escalates TERM to KILL
on its bounded cleanup path; only the settled worker result produces the terminal action outcome.
An exact Stop retry reconciles through its command identity.

The stop check, process spawn, and process-group registration share one critical section.
If Stop wins before launch, no child is spawned; if launch wins, Stop sees the registered group.
A deterministic pre-launch test asserts both the canceled result and that no process launched.

There is not yet an `action.cancel_requested` event for direct shell. Consequently the canonical
action projection does not have a durable intermediate “stopping” transition; it remains running
until the worker records its terminal canceled/failed result. UI copy must not imply that a Stop
receipt proves every descendant is gone.

### Dismiss with X

X is also a separate, idempotent Work command (`dismiss_shell`). It is not a Session tombstone and
does not delete the artifact or action. The Work journal's accepted dismiss command names the exact
direct-shell Action, and the pending projection excludes that Action thereafter.

### Attach to the next accepted input

Pending output is derived by the Work Host from its canonical Work and Session journals at the
same semantic gate that accepts the next input. The host validates pending entries and their
content-addressed result bodies, prepends one escaped `<aviary-command-output>` projection to the
effective model input, and records the consumed Action IDs on that same Session `input.accepted`
event.

This means:

- rejected or uncertain pre-acceptance input does not consume output;
- GUI reconnect does not need to preserve a client-side manifest;
- command retry cannot attach the same result twice after the accepted input is observed;
- another Work attached to the Session does not implicitly consume this Work's output.

Pending context is bounded to eight results and 256 KiB of retained stream bytes for the exact
Work/Session attachment. Run admission reserves a new result's 128 KiB worst case and refuses the
command when that budget is unavailable. Historical terminal artifacts are not deleted when their
pending-context role ends.

## Current implementation seams

- `AviaryCore/DirectShellCommandWorker.swift`: process input, POSIX lifecycle, output collectors,
  concurrency, Stop, and typed terminal results.
- `AviaryCore/DirectShellCommandService.swift`: Work-service DTOs, validation, response
  correlation, and bounds.
- `AviaryCore/DirectShellCommandJournal.swift`: retained media types, pending limits, and
  model-facing context projection.
- `AviaryCore/RunJournalBundle.swift`: admission, journal-derived entries, Stop/Dismiss control,
  result consumption at `input.accepted`, and exact effective input recovery.
- `AviaryCore/HostedInHouseWork.swift`: live worker ownership and serialization with the agent.
- `AviaryCore/JournalBackedWorkService.swift`: capability, attachment, owner, cursor, and exact-live
  hosted-actor gates.
- `AviaryCore/WorkServiceTransport.swift`, `WorkServiceClientSession.swift`, and
  `WorkServiceAttachedWorkController.swift`: bounded transport and client operations.
- `Aviary/DirectShellCommandView.swift`, `SuggestedCommandSheet.swift`, `MarkdownBlocks.swift`,
  `LiveView.swift`, `ServiceBackedRunBridge.swift`, and `AppModel.swift`: confirmation, command
  tray, Run/Stop/X, capability gating, and refresh.

## Evidence and validation status

Current focused receipts (2026-09-18):

- direct-command worker/journal/DTO/controller: **21 cases / 112 assertions**;
- native cold resume: **11 cases / 143 assertions**, including settled command results and
  rejection of forged result metadata;
- real daemon subprocess: **1 case / 81 assertions**, including requester disconnect, another
  client observing retained output, exact retry without a second process, Stop, End, replacement
  Start, and exact once-only output inclusion in the recorded provider request;
- debug app, Work Host, and self-test products build successfully;
- debug AppModel/OTLP journey: **145 spans / exactly two local fixture-provider calls**, including
  direct execution, plain-End refusal with pending output, and explicit cleanup before End;
- full macOS regression suite: **1,467 cases / 21,258 assertions**, all passed in **553.35s**;
- confirmation and narrow command-output fixtures visually inspected, plus the real-data Flock
  snapshot. These prove layout only, not live pointer interaction.

The signed release also passed the native editor and saved-request journey probes. The real
AppModel → bundled daemon → local fixture provider → OTLP check recorded **133 spans and exactly
two provider calls** (5.222s journey / 6.357s through cleanup). Repeating the same journey with
telemetry disabled and with a refusing collector succeeded with exactly two provider calls each
(6.724s and 9.231s through cleanup). Exported data excluded the command/output and credential
sentinels. Those checks exercise completion output, pending-output refusal on plain End, and
explicit Dismiss-before-End; Stop and disconnect/retry are covered separately by the real daemon
process test above. There is no real remote-collector claim.

Final live pointer interaction for this command/activity slice remains unverified because the
Mac was locked. The rendered fixtures and native probes are not substitutes for that check.

The standalone worker also typechecked and ran in the Swift 6.0 Jammy container (glibc 2.35).
This is not a full Linux package receipt: the available container's Swift 6.0 toolchain is below
the dependency's Swift tools 6.1 requirement. The current Linux worker binding requires glibc
2.29 or later; musl and the complete new Linux application slice are not verified here.

Do not infer from that aggregate that every row below has passed independently. Before release,
record separate receipts for:

| Boundary | Required evidence |
|---|---|
| Parsing and provenance | Only closed assistant shell fences act; exact Unicode/newlines and originating `LiveRun` survive; quoted/user/tool/output/streaming fences stay inert. |
| Authorization | Missing `.directShell`, missing inspect capabilities, detached/wrong client, wrong Session attachment, foreign Work, and conflicting live owner fail before effect. |
| Retry and cursor races | Lost response plus identical retry yields one action/process; changed bindings conflict; concurrent clients get explicit ordering/staleness. |
| Worker outcomes | Exact cwd/environment/source, null stdin, success/nonzero/signal/Stop/explicit timeout/launch failure, and four-worker host gate. |
| Output | Multi-megabyte stdout and stderr drain without deadlock; head/tail bytes, totals, omissions, incompleteness, artifact digest, UI binary display, and model UTF-8 replacement remain truthful. |
| Input consumption | Host-derived pending output survives GUI reconnect; X removes only pending context; accepted input consumes once; rejected/uncertain input consumes nothing. |
| Disconnect and daemon loss | GUI disconnect leaves the host worker running; daemon loss does not replay or pretend to recover the operating-system process. |
| Integration | Native editor probe, wide/narrow fixtures, full tests, app/daemon build, strict signing, disposable daemon journey, and identity-fenced live handshake. |

## Known limitations and roadmap

1. **Not a sandbox or complete process-tree security boundary.** The shell runs with the Work Host
   user's privileges in the shared workspace. POSIX process-group signalling covers ordinary
   children that remain in the group, but a command can deliberately daemonize, change groups,
   retain resources, or race unrelated processes. Stronger containment would require an explicit
   platform policy such as a sandbox/container/cgroup or equivalent supervisor, with its own
   product and authorization design.
2. **No canonical stopping action state.** Add a durable direct-shell `action.cancel_requested`
   transition, reduce it into `.cancelRequested`, and make the card distinguish accepted Stop from
   terminal cancellation without inventing completion.
3. **Inspect requires the exact live hosted Run.** Add a bounded cold/historical projection if
   command output must be inspectable through this endpoint after host restart. Artifact inspection
   remains a separate capability and should not silently masquerade as live command control.
4. **The direct-shell projection is resident-journal bounded, not lifetime-scalable.** It reads
   Work and Session projections with a 100,000-record resident cap and fails closed when either is
   not fully resident. Replace the full-residency scan with an indexed/checkpointed direct-command
   projection before claiming support for arbitrarily long-lived journals.
5. **Model-facing binary output is lossy by declaration.** The artifact is exact, while the
   injected text uses UTF-8 replacement. A future typed model attachment could expose explicit
   base64 segments if models need exact binary input; do not change the current projection without
   preserving prompt bounds and untrusted-data labeling.
6. **No terminal emulation or filesystem attribution.** There is no PTY, interactive stdin,
   repository lock, change attribution, or claim that filesystem edits came from this command or
   this turn.
