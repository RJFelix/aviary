# Provider usage and optional execution limits

Status: implementation verified, 2026-09-12. Optional child policies, normal-daemon activation,
shared usage inventory, and policy presentation pass the cross-platform checks below. The old
service has been retired with explicit permission; signed-bundle journeys pass. Background agents remain
unlimited by default, until stopped or finished.

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

Foundation checkpoint: `a89a478`; native settlement checkpoint: `c3d3be9`; child accounting and
parent-direct shared Work usage checkpoint: `656c0d1`. Optional child policies and combined
parent/child Work inventory are subsequent integration work.
Provider setup has its own action kind; only context-qualified model requests can create provider
admissions. A protocol-completed response without any usage report remains successful with unknown
accounting. Neither absent measurements nor malformed observations become zero-cost evidence.

The provider payload uses its own strict schema inside the current timeline envelope. Counts use
canonical decimal strings and configured rates retain their exact Double bits across JSONValue.
Disposable Work exact maps, bounded heads, and attached-client checkpoints are versioned anew;
old derived caches must rebuild rather than interpret missing accounting as a neutral aggregate.

Admissions independently match the manifest's raw request model and, when supplied, the action's
qualified provider/model target. Model IDs containing slashes are not split into guessed routing
components. The only accounting start is `action.started`; an outcome cannot bypass it. Complete
action projections reconstruct the aggregate in canonical event order and compare it with the
stored total, including at attached-client checkpoint restoration. Partial historical indexes do
not pretend to perform that complete-table check.

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

### Child accounting checkpoint and next integration

The child adapter now records independent `agent_handle.provider_started` and
`agent_handle.provider_settled` events through a Work-owned journal route. A serial Handle ledger
pins the provider/model/rates at dispatch, retains one pending crossing, and folds each terminal
report once. This is trusted-producer-pinned configuration, not independent verification of a
provider's prices. Provider usage remains separate from the parent-direct Work aggregate.

Ending the originating Run does not end its child or prevent later settlement. A clean-close race
may retry only the typed proof that the bundle closed before any append began. Writer uncertainty
never authorizes a retry. Cleanup and billing are independent: a quiescent failed/canceled child
may terminalize and be reaped with unresolved accounting preserved; success cannot conceal a
pending crossing. A failed live writer cannot certify a later Handle terminal event merely because
the runtime has stopped. Lifecycle ordering is checked in exact, full, and bounded projections.

The writer keeps an exact live continuation across synchronized Work commits and invalidates it on
source changes or uncertain writes. This is not an O(1) lifetime-read claim: preflight still clones
and inspects canonical state, explicit reads replay, and post-End cold child reads/appends reopen
the journal. Retaining an independent cold writer indefinitely would obstruct the service's
canonical readers; shared writer/read ownership is a separate performance increment.

The normal-daemon stress journey exposed another pre-append boundary: a cold child writer can
lose the advisory lock to an ordinary canonical reader after the parent Run closes. A typed
`competingWriter` error during construction proves that this attempt has not appended anything;
bounded acquisition retry is safe there. This does not authorize retrying an append or close
failure, retaining the cold writer forever, or treating an unsettled crossing as zero usage.
This correction needs both deliberate lock-contention coverage and repeated real-daemon runs.

The GUI now presents main-agent, background-agent, and combined usage once per Work, shared across
attached chats. The trusted controller produces this inventory from canonical aggregates, without
summing a Work again for each Session. Unknowns, lower bounds, outstanding outcomes, and configured
rates remain explicit. Missing child facts withhold the combined total, not a valid main-agent
subtotal. Fixture rendering checks layout; it does not certify the installed application.

Implemented integration:

1. Persist an immutable optional child execution policy at Handle admission. Token and USD fields
   are cooperative thresholds over that child's canonical aggregate, not the parent Work's total.
   Omitted fields mean unlimited. Gate normal and compaction dispatch through the existing ledger;
   finite dimensions reject unknown exposure/overflow instead of waiving the policy. Preserve a
   typed stop reason and proven cleanup without calling a reached threshold a provider failure.
2. Carry optional `timeout`, `token_limit`, and `cost_limit_usd` through Python `spawn`, strict
   callback decoding, exact callback deduplication, and the Work child delegate. Derive an absolute
   host deadline once per accepted request. A route that cannot honor a requested policy must
   refuse it rather than silently falling back to parent-owned execution.
3. Enable the same coordinator in the normal durable daemon resolver and its Hosted configurations,
   installed before service use and retained for the process generation. Shutdown must freeze that
   exact coordinator and refuse while children remain. The durable control-journal writer already
   holds the same-home Work Host lease for its lifetime; endpoint publication is not that lease.
   A second daemon currently blocks on that lock, so startup must retain a truthful bounded failure
   path. Do not add a second competing ownership mechanism or reconstruct lost child processes from
   journal history.
4. The real normal-daemon/Python journey covers parent End, second-client observation, explicit
   stop and shutdown refusal while a child remains. Provider/resource and callback fixtures cover
   token/cost/time policies, compaction and unknown reports; these are separate proof layers, not
   a claim that every policy permutation ran through the complete GUI. Policy and usage views are
   wired to canonical projections. Standalone fallback children also default to unlimited, with
   a real Python fixture exceeding twenty provider turns and retaining an explicit ceiling option.

The retirement and signed-bundle deployment acceptance receipts are recorded below. Retained
pending chats still require explicit user action; retirement is not proof of their delivery.

Finite token/spend policies will refuse further dispatch when prior exposure cannot be bounded,
and surface an explicit attention state. Unlimited execution remains the default. Policy is
immutable for an admitted child; a different policy requires a new explicit child admission.
Reconnecting or retrying must never silently waive a limit.
Postpaid reported-token and configured-price thresholds are not hard billing caps.

## Verification boundary

Current integrated macOS run: 1,401 cases / 20,840 assertions pass in 558.56s. The final
portable lock regression adds 1 case / 6 assertions; journal contention/lifecycle coverage
passes 13 cases / 137 assertions after rebuilding SelfTest, aviaryd and Aviary. The standalone
Python child fixture runs 22 provider crossings by default and exactly 20 with an explicit limit.
Main/child/combined usage fixtures were rendered and inspected at wide and 520-point widths.
These are debug/fixture receipts, not an installed-user-service upgrade.

The first Linux run exposed a real portability bug: exclusive-lock construction ignored
`O_NONBLOCK`. It blocked rather than producing the typed pre-append contention result, so an
upper-layer retry budget could not apply. The Linux wrapper now maps that flag to `LOCK_NB`
and preserves errno across descriptor cleanup; no-flag callers remain blocking. A held-lock
regression has an independent watchdog so the old bug fails instead of hanging the suite.
The corrected Linux Swift 6.3.3 run passes 41 grouped cases / 7,774 assertions in 324.82s,
including real normal-daemon child execution and parent-End survival. SelfTest and aviaryd build.
Snapshot `aviary-linux-child-limits-20260912-v1` has a 354-entry source manifest SHA-256
`565d4d3faea5875c6ad811d5c0b46bae612f9e028ae0609b59c935d9e5e8a91e`.
All entries matched before building; only Package.resolved changed for the Linux dependency graph.
The final UI-copy-only rebuild and narrow render pass separately on macOS. No paid provider calls
or external transcript edits were used.

Child accounting: Linux Swift 6.3.3 snapshot `aviary-linux-child-accounting-20260912-v1`
builds SelfTest and aviaryd; 41 grouped cases / 7,243 assertions pass in 272.44s. Its 334-entry
source manifest SHA-256 is `0346008404fa5548022ef813bf9ea5753016995128c39e00916183e331117ce7`.
The macOS 1,355-case run exposed a replacement-file permission fixture, a wrong-coordinator
deadline fixture, and an uncontrolled telemetry batching expectation. Their focused corrections
pass (writer 1/4, deadline 1/8, drain 5/63), followed by a complete green run of checkpoint
`656c0d1`: 1,355 cases / 20,342 assertions in 526.72s. These corrections change tests, not
production semantics. Later production activation/optional-limit edits are not certified by
that checkpoint's binaries or receipts.
The child accounting, exact-state, and provider-dispatch focused proofs pass; no paid calls were
made. The shared-usage card is not yet visually verified or installed.

Native settlement: final macOS SelfTest passes 1,334 cases / 20,094 assertions in 518.05s,
after rebuilding Aviary, aviaryd, and SelfTest. Linux Swift 6.3.3 builds aviaryd and SelfTest;
its selected suite passes 41 grouped cases / 7,023 assertions in 256.20s. Snapshot
`aviary-linux-settlement-20260912-v1` has a 333-entry source manifest (SHA-256
`2c088d43857fad7bd2e2ae16296a01a96772e55ad8c4422a620369f12825b423`); only Package.resolved
differs for the platform dependency graph. These are deterministic-provider tests, not paid calls.

This checkpoint is deliberately not installed over the existing user service. The bundle files
on disk identify `a89a478`, but a read-only handshake found that the older in-memory daemon speaks
protocol v3; replacing files did not replace that process.
The provider journal contract is incompatible with older provider actions. Before deployment,
bump the exact Work-service protocol to v5, prove old-version rejection without replacement,
drain the old service and reconcile its pending mutation intents, then recoverably archive/rotate
the disposable Aviary-native Work Host inventory. Rebuilding derived caches cannot invent missing
provider admissions or settlements. Do not weaken catalog completeness to hide old invalid Works;
they would otherwise prevent reconstruction of healthy new Works. External Claude/Codex stores
are excluded from this operation. If old Work cannot be proven quiescent, stop for user direction.
The pre-deployment read-only inventory found six old Works, two reporting recovery-required,
plus two retained pending chats without reconciled creation receipts. Graceful SIGTERM did not
stop PID 28101. Ryan then explicitly authorized force-stop and retirement. The old service and
an orphaned development Python host were stopped; their old native journals, launch material,
presentation transcripts and retry records were moved together into the private recovery archive
`~/.aviary/development-recovery-backups/retired-v3-20260912-q1VUxR`. The old app bundle is there too.
No completion was inferred for recovery-required Work and no request was replayed.

Pending chat cards, drafts, context bodies, client/host identities, configuration, credentials and
workspace registry remain in place. A 141-entry SHA-256 manifest checks their preserved bytes.
External Claude Code/Codex stores remain untouched. Do not restore old retry records separately
from their deduplication history or run the old helper against the new inventory.

Signed release `just build` and strict deep signature validation pass. The test-only
`AVIARY_CHILD_JOURNEY_DAEMON` override points the real child journey at the installed
`Contents/Helpers/aviaryd`, proving its own bundled Python resources: 1 case / 29 assertions,
4.72s. The installed AppModel/normal-service/Python/repository-review OTLP journey passes with
94 spans and two local fixture provider calls; save/blocked-launch/relaunch/edit/retry probes
also pass. These use disposable homes and fake loopback providers, never paid calls or saved
user requests. Final normal-home handshake/list and preservation receipts belong in the archive
and the superrepo measurement ledger.

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
