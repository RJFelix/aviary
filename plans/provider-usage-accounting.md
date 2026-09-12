# Provider usage and optional execution limits

Status: implementation in progress, 2026-09-12. No token/spend limit is claimed complete.
Background agents remain unlimited by default, until stopped or finished.

## Accounting contract

Every provider crossing retains one latest cumulative raw report. Missing, explicit zero,
malformed, and negative fields are distinct. The report names its input-accounting convention;
an aggregate spanning providers must never inherit one provider's convention.

Field completeness is not report finality. A transport EOF without protocol completion must
throw, never synthesize success or authorize buffered tools. Normal and compaction Agent consumers
also require completion evidence from custom providers. Unconfirmed cumulative reports retain
their observations but project only lower-bound usage/cost, even when every field is populated.
Final usage can in principle accompany a terminal failed operation; task success and report
finality are separate facts. Current adapters conservatively withhold finality on failed responses.

| Route | Ordinary input | Context input | Total tokens |
| --- | --- | --- | --- |
| OpenAI-style inclusive | input minus cache read minus cache write | input | input plus output |
| Anthropic exclusive | input | input plus cache read plus cache write | context input plus output |

All arithmetic is checked. Reasoning is a subset of output, not an additional chargeable token
category. A missing cache breakdown does not erase an independently known inclusive input/total.
Inconsistent cache partitions cannot establish ordinary-input cost. Supplied total tokens are
consistency evidence, not a replacement for missing component evidence.

The provider adapters follow the first-party [OpenAI cache accounting contract](https://developers.openai.com/api/docs/guides/prompt-caching)
and [Anthropic cache accounting contract](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
Anthropic [stream usage updates](https://platform.claude.com/docs/en/build-with-claude/streaming)
are cumulative for the fields they supply; updates replace rather than add those fields.

Prices are estimates from the model configuration captured at dispatch, not provider invoices.
Missing cache rates never fall back to ordinary-input rates. Invalid rates, numeric overflow,
and missing positive exposure prevent a complete estimate. Partial sums are explicitly known
lower bounds, never authority for admitting a hard spend-limited crossing.

## Implementation sequence

1. **Foundation complete:** typed raw reports, defensive provider decoders, one normalization/pricing
   kernel, the same result in tracing and normalized `Usage` presentation, persisted completeness,
   and explicit unknown/unclassified labels. Hidden Codex transport retries are removed: a retry
   is another potentially billable crossing and must be admitted/accounted at the Agent boundary.
2. **Durable settlement:** capture the latest report across normal and compaction calls; settle
   once on success, failure, or cancellation before returning. Bind settlement to canonical Action
   identity. A failed settlement latches journal health before another model dispatch. Assistant
   messages reference settlements and must not add another summable copy. Interrupted unsettled
   crossings remain unknown exposure after recovery.
3. **Limits:** optional time, token, and configured-estimate spend policies, checked before every
   normal and compaction call. No specified limit means unlimited. Postpaid token reporting can
   overshoot by one crossing unless a conservative reservation exists; do not call that a hard
   token/spend cap. Unknown accounting requires an explicit admission policy under a finite limit.
4. **Proof:** failed/cancelled/compaction accounting, replay and model-switch provenance, mixed
   provider totals, child attribution without double-counting, and a real isolated background-agent
   journey with stop/finish and optional limits.

## Settlement integration boundaries

The native Run boundary is the existing `RunJournalBundle.finishAction` commit: provider usage
belongs on that action's terminal outcome, not on the later assistant or compaction message.
Reducer acceptance updates a fixed usage aggregate. Persistent Work exact state and bounded Work
heads must carry the same aggregate with a schema bump; cache hits must not replay a lifetime
array of actions just to recover spending. Started but unsettled crossings remain explicit
unknown exposure. Cold resume needs a proven accounting seed as well as its conversation seed.

The Work-owned child pilot deliberately constructs its Agent without a parent Run journal.
It therefore needs an injected settlement interface with a separate Handle/execution-qualified
durable adapter; passing the parent's Run journal into the child would break independent
lifetime ownership. Native Run and Work-owned child adapters must consume the same normalized
report and pricing kernel. Tracing observes their evidence but does not own settlement.

Child crossing starts must also be durable: an outcome-only record cannot explain a crash after
dispatch. Prefer Handle/execution-qualified crossing events with their own unresolved count over
putting child calls into the existing generic active-action set: that set currently gates
`run.finished`, and must not make ending the originating Run wait for its independent child.
Work completion can still require all Work-owned child resources to settle. Keep parent-direct
and child-attributed aggregates separate so a combined UI never counts the same crossing twice.

Finite token/spend policies will refuse further dispatch when prior exposure cannot be bounded,
and surface an explicit attention state. Unlimited execution remains the default. A caller may
change or remove an optional limit; reconnecting or retrying must never silently waive it.
Postpaid reported-token and configured-price thresholds are not hard billing caps.

## Verification boundary

The foundation's final macOS run passes 1,317 cases / 19,852 assertions in 517.83s, including
terminal-protocol and superseded-End race regressions. Signed `just build` passes. The production
Usage view was visually checked with isolated complete/partial/imported/missing fixtures.
Linux Swift 6.3.3 builds SelfTest and aviaryd; its selected suite passes 41 cases / 6,844 assertions
in 256.20s. Snapshot `aviary-linux-usage-20260912-final2` matches 327 source entries exactly; only
Package.resolved differs for the Linux dependency graph. The current Mac-to-Linux OTLP proof
passes five spans with two exact CLIENT/SERVER parent pairs. These receipts certify the foundation,
not durable settlement or finite token/spend policies. The installed user Work Host was not restarted.
External Claude Code and Codex stores remain read-only; imported numeric observations are
not retroactively repriced or assigned a cache convention. No paid provider calls are required
for the local fixture proofs.
