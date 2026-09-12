# Aviary observability: one journey across GUI, service, and agents

Status: continuation instrumentation implemented, 2026-09-11. Backend-neutral OTLP;
no collector selected or enabled in the installed app. This is a coverage plan, not a claim
that every stage below is already instrumented.

Prior continuation baseline verified: saved-chat/initial delivery tracing, provider measurements,
Python execution/callback propagation, and independent linked child spans pass 49 focused cases /
742 assertions. Full macOS: 1,246 cases / 19,025 assertions, 537.63 seconds. Fresh Linux Swift 6.3.3:
40 grouped cases / 6,082 assertions, 243.39 seconds; clean aviaryd and SelfTest builds pass.
The actual isolated AppModel probe exports seven verified OTLP spans. Verification exposed and
fixed a real delayed-shell-Future state lifetime bug and Linux RuntimeHost EOF-close race; the
redirect test now uses a real HTTP server rather than Linux's unsupported URLProtocol redirect
fixture. These receipts precede the current small corrective pass for sticky uncertainty and
journal-qualified canonical references.

Current focused macOS receipt: 71 cases / 989 assertions, 14.25 seconds. This adds context and
compaction, repository observation/publication, read acknowledgements, bounded exporter drain,
and a stopped-provider propagation regression. The current signed AppModel collector probe passes
with 13 spans (3 saves, 2 blocked startups, 6 read acknowledgements, 2 commands). Wide/off and
narrow/enabled diagnostics fixtures were rendered and inspected from the signed app. Full macOS
verification now passes: 1,268 cases / 19,275 assertions in 516.84 seconds. Fresh Linux and
cross-device receipts are recorded below. The signed bundle and debug products build; the running
user app/service has not been replaced or restarted.

The first current broad run completed 1,268 cases with one saved-intent integration failure:
its immediate post-Start refresh raced the still-settling Hosted turn. The fixture now waits
for its exact owned actor to be idle, healthy and connected before asserting canonical delivery;
12 consecutive isolated runs pass (28 assertions each). This is test sequencing, not a relaxation
of canonical read checks or proof that transient GUI read errors are already well presented.
The full rerun passes. The separate production review confirmed automatic next-poll recovery;
the subsequent snapshot-coherence correction and its focused proof are described below.

## Contract

Traces explain timing, causality, failure, and uncertainty. Canonical Work/Session journals
remain the source of delivery, action, and recovery truth. Losing a trace or an unavailable
collector must never fail a command, replay an effect, or change a Work lifecycle.

Use the official OpenTelemetry Swift SDK and W3C traceparent across process boundaries.
Never use trace IDs for authentication, idempotency, or canonical relationships. Ignore malformed
observability context without weakening normal request validation. No baggage propagation.
Stable identities are hashed for correlation, not made secret: low-entropy values remain
dictionary-linkable. Trace data is operationally sensitive even without content bodies.
If context alone would exceed an RPC frame limit, omit it before the single write and record
`aviary.transport.context_omitted`; never resend after a write. Lost confirmation for mutations
(including otherwise quiet read acknowledgements) stays indeterminate. An explicit rejected or
indeterminate outcome must survive a later thrown error.

## Coverage and sequencing

| Stage | First slice | Follow-up acceptance requirement |
| --- | --- | --- |
| GUI saved intention | Command bridge span | Draft retention, Create intent, startup/recovery and explicit edit/discard paths, including failures before a Work exists |
| Client/server crossing | CLIENT/SERVER spans and propagated parent | Reconnect/uncertain receipt tests; no duplicate action inferred from RPC retries |
| Work | Admission and separately owned execution spans | Queue/delivery/settlement transitions with exact command identity and committed event correlation |
| Agent/model | Send, normal provider, compaction provider spans | Measured input/output/cached tokens, costs with pricing provenance, first-token latency and cancellation outcomes |
| Tools/runtime | Tool and Python execution boundaries | Runtime request/callback propagation across output-pump tasks, dispatch/settlement timing and explicit unknown effects |
| Canonical actions | Hashed committed action/event correlation | Verify complete admitted-effect-outcome joins under success, rejection, timeout, cancellation, and lost confirmation |
| Background children | Explicit admission spans and independent linked execution roots verified | Preserve origin across queue promotion; truthful queued cancellation/expiry and terminal evidence; restart joins canonical identities, never resurrected spans |
| Recovery/review | Context/compaction, repository observation/publication and actual GUI read acknowledgements | Distinct explicit Attach, presentation resume, reconstruction and retained-Start recovery; explicit history/review inspection scopes |

Each stage must name its actual outcome: an accepted command is not delivered input, a finished
HTTP call is not completed Work, and completed Python execution does not prove each external
effect succeeded. Python cell spans cannot observe every file/process/socket/network effect
inside arbitrary Python; hooks and OTel are not a sandbox or complete effect audit.

Queued inputs and detached callbacks need explicit origin context; do not parent them to whichever
turn happens to be active later. Cross-restart correlation must join canonical hashed identities
or explicit span links, not pretend an in-memory span survived process death. Keep span names
fixed and use bounded attributes; no span for each streamed token or UI polling tick.

## Export and data policy

Enable explicitly with `AVIARY_OTEL_ENABLED=1` and either
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://collector.example/v1/traces` or
`OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318` (adds `/v1/traces`).
Configuration is read from each process's environment at startup. GUI and daemon must both be
configured; starting the GUI does not silently reconfigure an already-running daemon.
HTTP is limited to loopback; remote collectors require HTTPS. No URL credentials, query strings,
environment-derived authorization headers, redirects, or vendor-specific SDK. Use a local
collector for authenticated forwarding. Export encoding is OTLP/HTTP protobuf, not gRPC.
The 2.5.1 HTTP exporter emits protobuf even when its JSON configuration flag is set; the tests
decode the actual protobuf request rather than trusting that option. Its HTTP success means a
successful HTTP response, not proof of backend retention or per-span acceptance; partial-success
response details are not interpreted by this first adapter.

Default attributes omit prompts, source code, tool arguments/results, model thinking, exception
messages, filesystem paths, environment values, credentials, and wire logs. Only explicitly
instrumented bounded fields are accepted. Full bodies remain under the existing artifact/context
inspection contract, not duplicated into telemetry. A future content opt-in needs separate review.

Use Aviary's bounded processor with the official SDK: at most 1,024 queued plus in-flight spans,
128 per batch, one export worker, and no failed-batch retry list. Collector response bytes,
concurrent requests, and request lifetime are bounded. Local saturating counters distinguish
queue loss, accepted spans, exporter success, unconfirmed exporter results, and abandonment before
export. A queue overflow or abrupt
process exit can lose spans; do not market traces as a durable audit log. Successful unparented
polling reads are suppressed in the first slice; read errors/slow-read summaries and shutdown
drain coverage are tracked separately below.

## Verification gates

1. Real SDK parentage, concurrent TaskLocal isolation, malformed remote context, bounded attributes,
   fixed error classifications, and identical execution result with telemetry disabled or failing.
2. Actual Unix client/server test verifies matching trace IDs and parent spans, not only a JSON
   codec round trip. Assert receipt versus execution lifecycle separately.
3. Actual Agent provider/tool/callback tests and canonical action joins; exporter payload decoded
   as standard OTLP. Collector refusal, redirects, huge replies and timeout remain bounded.
4. Signed GUI to daemon to provider/runtime journey against a disposable collector. Capture
   Send, Queue, Steer, Stop, lost confirmation/reconnect, child completion, and review. Compare
   canonical event IDs, UI states, and span outcomes; report every uninstrumented edge.
5. Current Linux daemon build/test and Mac-to-Linux trace propagation, followed by overhead
   measurements for disabled, enabled/healthy, and enabled/unreachable collector configurations.

Do not declare exhaustive coverage on the strength of the first component tests. After each
slice, update this matrix and distinguish source/build proof from installed-app proof.

Prior first-slice focused receipt: 19 cases / 156 assertions pass on macOS, including native successful
and indeterminate provider actions joined to the canonical journal, real socket propagation,
exact frame-boundary fallback, closed attribute vocabularies, and bounded collector behavior.
No installed-app collector journey or current Linux trace receipt is claimed.

Prior checkpoint (84a0620) full receipt: 1,216 cases / 18,438 assertions passed in 527.95 seconds. `just compile`
(Aviary + aviaryd), the SelfTest build, and staged whitespace checks pass. SwiftPM reports one
upstream unhandled Markdown resource in the SDK's unused MetricKit target; no Aviary compiler
warnings or errors. The first broad attempt stalled in a pre-existing scheduler-sensitive held-
intent test; a bounded fixture wait/cleanup replaced its yield-count assumption before this clean
full rerun. No installed app or service was replaced or restarted.

## Implemented continuation: saved chat to delivered input

- Trace `AppModel.createPendingChat`'s local write separately from `retryPendingChat`'s later
  startup attempt. Correlate with hashed persisted chat/Create/Start IDs; do not invent Work or
  Run identities before their receipts. A loaded saved request is not proof that its initial save
  succeeded, so test both boundaries.
- Emit retained-intent and validated-receipt events in `startPendingChat`. A successful Create
  means idle Work exists; successful Start admission is not delivered input.
- Trace each `reconcilePendingCreateIntents` attempt as a new root after relaunch, joined by the
  same command hash. Do not persist a traceparent or pretend an old in-memory span survived.
- Add command ID/kind to the bridge span. At `NativeSessionCommandJournal.markDelivered`, emit
  exact committed event correlation only after append succeeds. Keep the runtime delivery callback
  separate from this durable acknowledgement; a failed append remains indeterminate.
- Exercise saved request → Create → Start → Hosted turn → canonical delivery over a real socket,
  plus lost-response/relaunch, stale rejection, and delivery-journal failure. The pending chat must
  retire only at its existing strict canonical-delivery predicate, never because a span succeeded.

This batch changes instrumentation, not the command protocol, store schema, or delivery policy.

### Continuation details and measurement boundaries

- Local save and later startup have separate scopes. Reconciliation is a new root correlated
  through hashed durable command IDs. Runtime delivery callbacks precede—and are separate from—
  canonical delivery/nondelivery writes. Only a successful append emits the committed EventRef
  hash and sequence; errors never synthesize a commit or trigger resubmission.
- GUI/client command IDs and Native's client-qualified ledger command IDs are distinct domains.
  `aviary.command.id` and `aviary.command.ledger.id` explicitly join them at the Hosted boundary.
- Provider spans retain the dispatch model/provider across actor suspension and model switches,
  including their canonical action target, usage-accounting convention, and rate snapshot.
  A returned provider stream followed by an unrecordable action outcome is indeterminate.
- Measurements record the latest adapter usage report, not the sum of cumulative updates.
  Missing usage is `unreported`; malformed negative counts are `invalid`. Reasoning is a subset
  of output, not added again. Individual field presence is not retained by `Usage`: a zero
  adapter field is not proof that the provider explicitly reported zero. These are diagnostic
  observations, not a new billing meter or enforcement authority.
- `ProviderUsageAccounting` identifies cache-inclusive, cache-exclusive, or unknown input.
  Estimates require a known relationship and complete valid rates for the used buckets; unknown
  adapters, inconsistent cache counts, missing rates, and nonfinite arithmetic produce no dollar
  amount. Configured rates, effective cache fallbacks, and a rate-set digest accompany estimates.
  `model_spec` means configured pricing—not independently verified published prices or invoices.
  The existing transcript/UI `ModelSpec.priced` and compaction input-count arithmetic still need
  a separate accounting audit; this telemetry calculation does not certify those consumers.
- First output latency measures the first nonempty text/thinking chunk or completed tool call,
  not an exact first-token timestamp. Request-body/usage events do not count as output. No event
  is exported for each token. Usage observed before a failure remains visible without claiming a
  completed provider request.

The cache-inclusive convention follows the official [OpenAI prompt-caching accounting](https://developers.openai.com/api/docs/guides/prompt-caching)
and the actual adapters. Provider requests and provider usage payloads are unchanged by the
new declaration; unrecognized adapters default to unknown rather than guessed accounting.

`uv run scripts/verify-chat-telemetry.py <Aviary executable>` runs the actual isolated AppModel
journey against a disposable loopback OTLP/HTTP protobuf collector. It verifies successful and
failed saves, independent blocked-startup roots, and metadata-only export. It uses the actual
production shutdown drain rather than a probe-only export-delay sleep. Current signed
`build/Aviary.app` executable receipt: PASS, 13 received spans (3 saves, 2 blocked startups,
6 read acknowledgements, 2 commands). This is the isolated AppModel path, not a live-provider journey or evidence
that the user's running app/daemon was reconfigured. That separate gate remains above.

Runtime continuation relays optional traceparent per execution and callback, including retained
Future callables and reconnect replay. A callback exchange has its own explicit server parent;
missing context never inherits the socket pump. Context is omitted before writing if it alone
exceeds a frame bound. Callback frame serialization must not call arbitrary Python `__str__`
an additional time just because tracing is enabled. Public helper signatures and user-replaced
shared-host bindings remain unchanged. These are effect-preservation requirements, not just
trace-shape tests. See the [runtime protocol](../docs/runtime-host-protocol.md#diagnostic-tracing).

Work-child execution uses a fresh root with a bounded OTel link to its admitting span, not the
context of whichever operation later pumps the queue. Its provider/runtime children inherit that
execution scope. Admission context exists only in coordinator memory; no trace ID or open span is
persisted into a Work journal. Restart correlation uses canonical identity hashes. Work hashes
include the owning host with unambiguous length-delimited encoding, consistently across GUI,
Hosted delivery, and children. Handle hashes are qualified by that Work identity. Queue wait is
monotonic elapsed time after the queue commitment is known, not a reconstructed wall-clock time.

Schema 2 adds `aviary.event.journal.id` and `aviary.action.started.journal.id`: hashes of the
complete, length-delimited JournalRef (journal ID, authority, owner kind and owner identity).
Canonical joins require the journal hash plus event-ID hash; sequences are journal-local too.
Schema-1 bare event hashes alone were not exact cross-journal identities. Primary and action-start
references carry their own journal qualification. A mismatched cursor/reference or oversized
diagnostic identity emits no canonical-reference tuple, never a truncated substitute. These fields
remain diagnostics, not authorization or a substitute for reading canonical evidence.

Current integration batch (focused verification passed): context preparation/compaction, repository
observation and canonical artifact publication, and actual read-acknowledgement attempts (not every
polling refresh and not a claim that a person read or approved changes). Read-ack tracing preserves
the existing exact idempotent replay policy after descriptor reconciliation. Repository publication
requires a returned Work-journal commit; a retained body alone or failed/uncertain append emits no
publication receipt.

The production exporter now has an absolute-deadline drain rather than chaining per-batch SDK flush
timeouts. Concurrent callers share a deadline that can only shorten and an immutable result. A
quiesced result means locally accepted spans reached an exporter result, which may be unconfirmed;
it never proves backend retention. A deadline result records queued abandonment and in-flight
uncertainty before transport cancellation. Late exporter completion can update live local counters,
not rewrite that receipt. Transport closure and SDK-provider shutdown each occur once. Recording
fixtures have a separate tracer and cannot accidentally shut down the production provider instead.

The GUI drains only after its draft/resource quit preparation succeeds; rejected quit leaves tracing
live. Daemon refusal/timeout likewise keeps tracing live, while actual exits drain after transport
cleanup. Both headless engine success paths and async failures drain before exit; those CLI paths
are source-reviewed, not yet separately collector-subprocess verified. Non-instrumented early usage,
MCP-bridge setup and rendering/inspection modes are not claimed as traced engine journeys. The
isolated AppModel collector probe now uses the real drain instead of a fixed export-delay sleep.
Diagnostics exposes app-process counters only, explicitly not daemon or canonical delivery health.
The stopped production provider cannot originate new trace context: the SDK otherwise supplies a
valid unsampled no-op context after shutdown, which can suppress later callback traces. Existing
remote sampling decisions remain intact, and independent recording providers remain usable.

Linux baseline snapshot: `/home/azureuser/aviary-linux-final-20260912-0305`, manifest SHA-256
`b6d0319107c86d237768974071ef7d433106f2ac61433624ddc7fd29f2b843af` (345 files,
2026-09-12T03:05:52Z). Only the Mac-only shell regression fixture changed during that copy/build;
production and Linux-selected sources were frozen. That snapshot's ordinary Mac-to-SSH connection
proof is not a trace-propagation proof. The current opt-in Mac probe now configures OTel, and
`scripts/verify-linux-telemetry.py` validates exact Mac-client/Linux-server parentage at a disposable
protobuf collector through SSH streamlocal/reverse-TCP forwarding. The completed five-span receipt
and its narrower handshake/list boundary are recorded below.

## Next bounded batches

1. Revalidate the continuation against the full macOS suite and a fresh Linux snapshot. The preceding
   checkpoint's macOS/Linux/cross-device proofs are complete, not proofs of later source changes.
   Keep snapshot, binary, signed-app and running-service identities distinct. No user service or
   permanent collector configuration has been changed by these checks.
2. Verify explicit history/repository consumer scopes and distinct Attach/resume/reconstruction/
   retained-Start stages in the AppModel journey. Quiet read diagnostics, read-ack mutation tracing,
   and deferred delivery causality have focused receipts below.
3. Extend the signed isolated journey through a real disposable daemon and deterministic local
   provider/runtime, including Queue/Steer/Stop and uncertain receipt reconciliation. Component
   receipts do not substitute for this combined flow. Measure disabled/healthy/unreachable overhead.
4. In a separate behavioral checkpoint, share provider-aware cache accounting with transcript
   pricing, compaction pressure and token totals. Current `ModelSpec.priced`, `lastInputTokens`, and
   Anthropic total-token calculations have different cache assumptions; the OTel observations do not
   certify or fix them. Include compaction calls and partial/failed provider reports in the subsequent
   cumulative budget audit before adding optional child token/spend limits.

Current Linux verification uses the frozen 350-file snapshot
`/home/azureuser/aviary-linux-final-20260912-035914`, manifest SHA-256
`2771542413a33b602866b226d0e350a863f73a82f6bce0890a1b9d580269f27a`.
Swift 6.3.3 release aviaryd builds; debug SelfTest plus colocated debug aviaryd passes
40 grouped cases / 6,302 assertions in 248.31 seconds. The focused telemetry group passes
881 assertions. A release SelfTest build is not claimed: the current test target uses
`@testable import`, requiring the debug testing build. The Mac-only saved-chat fixture wait
and neutral unprobed Diagnostics presentation do not change this Linux-selected source set.
The current Mac probe and this snapshot's canonical debug daemon exported five spans through
SSH forwarding to a disposable standard OTLP collector: two CLIENT/SERVER pairs with exact
parentage, plus the probe root. This proves handshake/list propagation, not a remote provider
turn. The script's first automatic cleanup check conservatively refused; exact PID/executable/
AgentHome verification followed by scoped shutdown/removal confirmed no fixture daemon remained.
The cause was Ubuntu dash's `kill` builtin rejecting `--`, so no signal was sent. The script now
uses explicit `/bin/kill` after the same exact ownership checks. A second cross-device run passes
the same five-span checks and automatic cleanup; no verification roots or fixture daemon remain.
The final script-only synchronization changes the snapshot manifest to
`212f120b44deb407a6d2454ed3b4b4318c0882d9c3fa1139b96db80ab37e1ba2`;
the selected Swift source and already-built binaries are unchanged from the build manifest above.

### Follow-up correctness and quiet-read diagnostics

JBS snapshot responses now retain one canonical source and authorized control projection for both
the page and its descriptor. Independent live-host observations remain conservative when the Run
has advanced. A deterministic fixture advances and closes a Run after both controller pages have
been selected, verifies the retained pair, then catches up using nonzero cursors: 1 case / 23
assertions passes. This avoids a known transient warning without weakening reader validation or
claiming atomicity across two independently requested pages.

Fast successful unparented polling remains silent. Failed reads and reads taking at least one second
emit one completed CLIENT diagnostic, with duration measured monotonically and no retroactively
propagated parent. Explicitly parented operations retain ordinary CLIENT/SERVER spans. Request
encoding and pre-handshake rejection are now inside that boundary; socket opening and connection
setup are still covered by their enclosing user operation rather than a separate connection span.
Read acknowledgement is always treated as a mutation. Real socket fixtures cover slow success,
timeout, prewrite bounds, exact parentage, and no duplicate server span for an unparented read.

The pinned Swift SDK loses the explicit context when its parent-based sampler declines a span.
Aviary therefore carries a valid unsampled parent as context only, without constructing a child
span. Nested async/sync scopes and real outgoing client/server calls preserve the exact `00`
traceparent and export nothing; an explicitly independent root remains independently sampled.

Queue/Steer delivery now captures each admission's context in its deferred callback, parents
delivery to that origin, and links the executing turn. Missing origin explicitly creates a new
root. Context is in memory only; canonical command identity remains authoritative. The real gated
Hosted fixture joins delivery to exact closed-journal event IDs, journal identities, and journal
sequences (not the separate host command sequence): 2 cases / 82 assertions pass. The missing-origin
case tests the pure parent/link policy, not a full missing-origin callback lifecycle.

Current follow-up focused telemetry receipt: 77 cases / 1,059 assertions, 15.16 seconds. This is
separate from the Hosted and snapshot tests above. Full follow-up macOS passes 1,277 cases / 19,445
assertions in 532.65 seconds. After that run, the Hosted fixture became self-contained and the JBS
fixture switched from a Mac-only test store to the durable launch-manifest adapter so both can run
on Linux; focused reruns pass 2 / 82 and 1 / 23 respectively. New GUI-consumer and fresh Linux
receipts for the final integrated tree remain pending; the preceding checkpoint's signed/Linux
receipts are not substituted.

The explicit consumer probe now uses a 769-message canonical fixture with a proven earlier-page
boundary. The actual bridge preserves the visible history on a failed read and preserves bounded,
successful, and disconnected/stale repository-review results. A disposable protobuf collector
observes 20 spans across the complete AppModel probe, including three repository loads and one
failed earlier-history load; ordinary refresh/jump operations add no consumer spans. AppModel now
accepts its home at initialization, and headless routes exit before constructing the normal GUI
model, avoiding an initial read of user configuration in isolated probes.

Fresh Linux verification exposed a real shutdown lock cycle: Foundation's `FileHandle.close()`
waited for its readability callback while holding the callback's `stateLock`. The close claim now
fences admitted/future reads before Foundation teardown, with no callback lock held across close.
Four repeated Linux telemetry runs pass 1,029 assertions each after this fix. Current full macOS
passes 1,277 cases / 19,447 assertions in 521.01 seconds. The fresh Linux snapshot
`/home/azureuser/aviary-linux-followup-20260912-0615` has 276 source/fixture files, manifest SHA-256
`4a716739e4a504f6a3a2ad041b61ecb8ad03739b059ce26d4b1a57a5b0a0d028` (excluding `.build`).
Its debug SelfTest passes 41 grouped cases / 6,473 assertions in 252.48 seconds; current debug
aviaryd builds and the Mac-to-SSH-to-Linux collector proof passes five spans with two exact
CLIENT/SERVER parent pairs. This uses the previously built Mac probe binary and the current Linux
daemon; it is handshake/list evidence, not a remote provider turn. All fixture processes, tunnels,
and verification roots were checked absent.

The current signed `just build` passes with Aviary's stable designated signing identity. Its
actual AppModel-to-normal-daemon journey exports 98 spans to a disposable protobuf collector:
exactly two deterministic local provider calls, one Python edit, canonical delivered Start,
explicit repository review load, End, and app/daemon export drain. Start admission joins the
caller command/Work/Session/Run in one span; the canonical command is separately checked against
the client-qualified ledger identity. The successful tool's outcome event joins action and Work
journal; the review-load span joins the selected artifact/Work/Session. Prompt, tool, credential,
file-name and private-root sentinels are absent from telemetry. The signed blocked-start/relaunch
and consumer probe separately passes 20 spans. Normal running user services were not replaced.

Fixture corrections were not product recovery changes: the typed startup wait must not accept a
nested optional `some(nil)`, Python uses `Path(cwd())` for its Session directory rather than the
shared process directory, and cleanup normalizes `/tmp` versus `/private/tmp` before comparing
AgentHome identity. Cleanup now fails closed on an unavailable process inventory; three earlier
test-owned daemons missed by the initial string comparison were independently identified by
executable/PID/home and stopped. Current signed runs prove automatic cleanup with no remaining
fixture daemon. Shell startup is isolated with a private empty `ZDOTDIR`; no user credentials or
transcripts are needed for the fixture. Queue/Steer/Stop and uncertain-delivery journey cases
remain follow-ups; this successful normal path does not certify them.

Three sequential signed runs per exporter mode all completed the same canonical two-call workload
and automatic cleanup. The elapsed app journey includes its final export drain; full time also
includes fixture setup, daemon drain, and server cleanup. Medians (seconds):

| Export configuration | App journey | Through full cleanup |
| --- | ---: | ---: |
| Disabled | 3.755 | 5.202 |
| Healthy loopback collector | 3.690 | 5.366 |
| Reserved refusing loopback endpoint | 5.825 | 8.211 |

Healthy runs passed all canonical/trace joins (97–98 total spans); disabled runs emitted no spans
to their live collector. Unreachable runs used a bound, non-listening socket to prevent endpoint
reuse and proved workload completion/cleanup, not collector delivery or zero span creation. The
roughly two-second app-exit difference is consistent with the configured bounded export drain.
This tiny end-to-end sample is not a per-action overhead benchmark or evidence that tracing makes
the application faster; startup/process timing noise exceeds the healthy/disabled difference.

References: [OpenTelemetry trace API](https://opentelemetry.io/docs/specs/otel/trace/api/),
[OTLP specification](https://opentelemetry.io/docs/specs/otlp/),
[Swift SDK releases](https://github.com/open-telemetry/opentelemetry-swift/releases).
