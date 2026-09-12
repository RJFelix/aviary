# Aviary observability: one journey across GUI, service, and agents

Status: first implementation slice implemented and macOS-verified, 2026-09-11. Backend-neutral OTLP;
no collector selected or enabled in the installed app. This is a coverage plan, not a claim
that every stage below is already instrumented.

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
| Background children | Agent execution inherits current task context where present | Explicit durable parent/child links across queues, detached tasks, restart and terminal Handle outcomes |
| Recovery/review | Not yet traced | Attach/resume/reconstruct distinction, context assembly/compaction, artifact/repository review and GUI acknowledgement |

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

Use a bounded SDK queue and bounded batch size; failed exports do not accumulate an unbounded
retry list. Bound collector response bytes, concurrent requests, and request lifetime. Report
export failures locally without recursively exporting their errors. A queue overflow or abrupt
process exit can lose spans; do not market traces as a durable audit log. Successful unparented
polling reads are suppressed in the first slice; read errors/slow-read summaries and shutdown
drain coverage remain explicit follow-up work.

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

Current focused receipt: 19 cases / 156 assertions pass on macOS, including native successful
and indeterminate provider actions joined to the canonical journal, real socket propagation,
exact frame-boundary fallback, closed attribute vocabularies, and bounded collector behavior.
No installed-app collector journey or current Linux trace receipt is claimed.

Full receipt: 1,216 cases / 18,438 assertions passed in 527.95 seconds. `just compile`
(Aviary + aviaryd), the SelfTest build, and staged whitespace checks pass. SwiftPM reports one
upstream unhandled Markdown resource in the SDK's unused MetricKit target; no Aviary compiler
warnings or errors. The first broad attempt stalled in a pre-existing scheduler-sensitive held-
intent test; a bounded fixture wait/cleanup replaced its yield-count assumption before this clean
full rerun. No installed app or service was replaced or restarted.

## Next bounded implementation batch: saved chat to delivered input

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

References: [OpenTelemetry trace API](https://opentelemetry.io/docs/specs/otel/trace/api/),
[OTLP specification](https://opentelemetry.io/docs/specs/otlp/),
[Swift SDK releases](https://github.com/open-telemetry/opentelemetry-swift/releases).
