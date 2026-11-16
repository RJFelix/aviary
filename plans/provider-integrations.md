# Provider additions — 2026-09-22 checkpoint

Requested: Grok API, host-local secrets usable without putting their values in model
context, and native Muse Code integration without a Node runtime dependency.

## Grok / local secrets

- Native xAI Responses adapter: stateless conversation/tool replay, streaming text and
  reasoning summaries, usage, bounded errors, and explicit terminal validation. Incomplete
  responses preserve usage but cannot complete a turn or release buffered tool calls.
- Models → Add Grok / Secrets: secure entry, Keychain storage, provider/origin-scoped
  `@secret:name` references, config backup and unknown-field preservation.
- Work Host loads fresh provider configuration for new launch resolution. Provider Test
  uses the same provider-level route as live Work.
- Tests cover setup/config preservation, scope refusal, redaction, malformed stream
  terminals, and an already-running daemon observing a new provider without restart.
- Real saved-key completion now passes: native streaming client, HTTP 200, final `ok`.
  The live test caught and fixed `tool_choice` being sent without any tools.
- Real signed GUI → Work Host → Grok → Python → Grok loop passed: `17 * 23`, final `391`,
  two completed provider actions, one completed Python action, and canonical turn completion.
  Retrying the saved startup reused the same chat/Work; no duplicate was created. The test's
  idle agent was then ended, with canonical `run.finished` verified.
- Model listing uses scoped credential metadata, not key decryption. Actual requests still
  resolve the key on the executing host. A metadata-only test backend that refuses every
  value read keeps the model selectable while actual credential resolution fails closed.
- Remaining: encrypted reasoning replay; explicit scoped tool-secret injection. Never substitute
  plaintext storage or inject keys into prompts as a shortcut. Arbitrary local agent code
  is not sandboxed, and the UI explicitly says so.

## Muse Code

- Swift MSP NDJSON/JSON-RPC client, process owner, typed session/view/turn/approval seams.
  Uses the installed native `muse serve` binary, not the JavaScript SDK.
- Installed 1.3.0-R3401.1 handshake works. After user login, a fresh restricted host reports
  accountLogin and four catalog models, with no META_API_KEY override.
- Resolved the stalled live turn: installed 1.3.0-R3401.1's `serve --no-session-log`
  accepts a turn but does not advance it. Normal durable `serve` completes. TUI
  `--reasoning-effort` cannot be combined with `serve`; session thinking level is set through
  `session/setReasoningEffort`. The advertised session/read and view paging methods still
  return methodNotFound; initial chat does not depend on them.
- New chat offers Muse Code as a separate provider/engine with host-discovered models,
  subscription account routing, remembered selection, and visible process-lifetime guidance.
  It never falls back to Aviary's in-house provider route.
- Native run + GUI driver preserve the initial prompt before startup, stream message and
  thinking items, pair tool calls/results, distinguish retained-but-unfetched output, and
  present exact host-issued approval stages. Intake ACK and turn completion remain separate.
  GUI queue overflow fails visibly and stops the child instead of silently dropping events.
- Host-cumulative usage is persisted as an explicit aggregate snapshot, not copied onto every
  message; both cold transcript and catalog recover the last validated total. Unknown prices
  and cache/input accounting stay unknown. Exact integer counts survive the JSON envelope,
  including values above the double-precision integer boundary. Catalog cache version bumped
  for the parser change. Muse reminder-child housekeeping stays recorded outside conversation.
- Real AppModel → LiveRun → driver → native Muse proof passes: Spark first reply, remembered
  follow-up, real shell `printf` output, host-confirmed cancellation, another follow-up after
  cancellation, cold transcript/usage, and explicit End. No Node process or SDK is involved.
- Muse now has a distinct detached `aviaryd --muse-worker` lane: one exclusive local owner
  per chat, generation-fenced manifests/snapshots, durable ordered commands and receipts,
  and native `session/resume`. GUI quit detaches; explicit End stops; Resume allocates a new
  worker while preserving Muse's native session identity. It is not an in-house Python Work
  or remote Work-service implementation.
- Resume restores native conversation state, not live tools, external effects, or process
  namespace. Non-idle native state and pending native requests withhold automatic continuation.
  Older transcripts lacking native identity are not guessed into a session.
- Local drafts and handoff markers survive GUI exit. Lost command confirmation remains
  uncertain; dispatched commands are never reset to pending or automatically replayed.
  Store bounds are explicit (1,024 retained commands per chat, last slot reserved for End;
  4,096 worker records). One local composer draft per chat is not multi-client draft history.
- Approval state has deterministic fixture coverage; live allow/deny UI proof is separate
  from the harmless tool run (which Muse permitted without asking).

## Verification boundaries

Background/resume checkpoint (2026-09-22): focused Muse fixtures/store/client **35 cases /
213 assertions**, provider regression **124 / 1,177**, debug app/helper/self-test builds,
`just build`, strict-deep signing, and chat-journey probe pass. The final signed app passed:

- End → new worker generation → same native Muse session → remembered follow-up;
- GUI detach/reattach retaining an unsent draft;
- independent launcher process exit during an active turn, a separate checker receiving the
  result and sending a follow-up, then explicit End releasing the worker owner;
- actual GUI relaunch showing the new background-lifetime guidance.

Separate debug SIGTERM and SIGKILL probes left neither isolated worker nor native Muse child
alive. The normal local Work service still passed identity-fenced handshake/list (8 Works,
zero omissions) after the user's Python cleanup; it was not restarted. This is not proof that
previously killed Python interpreters survived. Full suite, Linux Muse, live approval decisions,
and remote Muse attachment remain unverified. Existing transcripts without saved native IDs
cannot be automatically resumed.

Prior app-owned Muse checkpoint: focused provider regression 123 cases / 1,170 assertions; Muse
fixtures 24 / 136; usage regression 59 / 605. The ordinary fixture run skips its opt-in live
cases; a separate authenticated native Muse test passed 1 / 6. The final signed bundle's
`--muse-controls-probe` passes first reply, remembered follow-up, real shell output,
confirmed cancellation, post-cancel follow-up, cold transcript/usage, and explicit End.
`--chat-journey-probe`, `just build`, and strict-deep codesign verification also pass.
Actual GUI clicks selected Spark 1.3 and received `MUSE_UI_FINAL`, with housekeeping absent
from the conversation; End retained the transcript. The final UI-copy-only rebuild passed
signature verification, the chat journey probe, and another real Muse reply/follow-up/cold
transcript/End probe. End guidance now names Muse instead of claiming an Aviary Python runtime.
That earlier checkpoint did not include background ownership or cold resume.

Prior Grok checkpoint: secret store plus helper authorization 6 / 42; model resolver 12 / 49;
local launch resolver 8 / 131. These remain prior receipts, not a renewed Keychain authorization
check for the rebuilt Muse bundle. The existing approved service was not restarted during
the Muse slice, and the real Grok key was not accessed or changed.

At the Grok checkpoint, the signed bundle and native Grok setup sheet were built and inspected. The user saved
the real key there, not in chat; a signed GUI-identity probe completed a real Grok response.
Keychain probe waits were user authorization waits (confirmed by the user), not established
provider failures. The production helper's noninteractive read was initially refused before
Run start. After explicit helper authorization and the user's Always Allow choice, a fresh
signed helper passed the noninteractive check. Restarting the idle old service then enabled
the complete live tool loop above. No credential was printed or put in a prompt.

That checkpoint's final rebuild exposed an important remaining development limitation: fresh helper access
failed again after its code changed. At the check timestamp, `securityd` logged an ACL
partition mismatch between the new client cdhash and the two previously approved cdhashes,
despite the unchanged certificate-root designated requirement. Apple's
[partition selection implementation](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)
uses a cdhash fallback for signed code outside its recognized Apple/team identities.
That rebuilt helper required explicit authorization again. Do not claim durable approval
across rebuilds, remove partition checks, or broaden item access as a workaround. Next credential
work should evaluate proper Apple development signing or an independently built, minimal
credential component with a deliberately stable lifecycle. The signed GUI at that checkpoint did list Grok
from metadata (37 available models); metadata is not proof of executing-host authorization.
New Chat offers `xai` → `grok-4.7` in the final bundle. Replaced the idle old service after
its ordinary shutdown refused the two pre-existing unresolved recovery records; those records
were not End-mutated. Ryan authorized the final build with Always Allow; its fresh
noninteractive helper check now exits 0. The running signed service (PID 58805) also passes
an identity-fenced handshake and lists eight Works with zero omissions. No further rebuild
or paid completion was performed after this approval. Cross-rebuild durability remains open.
The disposable sentinel from the interrupted probe (UUID
7C39E9A4-92AC-47BB-9836-7A4F9086F0EE) was removed successfully through its exact
Keychain self-check namespace. The real Grok credential was untouched; no broad cleanup.
