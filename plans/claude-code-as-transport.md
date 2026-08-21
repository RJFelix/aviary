# Claude Code as the model transport for Prime Agent

**Status:** research only. Nothing was implemented. No files in `harness/` or `app/` were changed.
**Date:** 2026-08-21
**Versions on this machine:** `claude` 2.1.234 (native build, shim at
`/var/folders/.../cmux-cli-shims/…/claude`); Prime fork at upstream
`c75a637b00d3b52762841e72efe92289a0d55b49` (`0.7.4-beta.531.1.c75a637`); node v26.2.0; macOS 26.5.2.
**Auth in use:** `claude auth status` → `{loggedIn: true, authMethod: "claude.ai", apiProvider:
"firstParty", orgName: "Duckbill", subscriptionType: "team"}`. Note **team**, not Pro/Max — this
matters for the ToS section.

---

## 0. The one-paragraph answer

Claude Code *can* be stripped down to something very close to a bare inference call — I verified a
`-p` invocation with **zero** built-in tools, a fully replaced system prompt, no CLAUDE.md, no
settings, no MCP, and **286 tokens** of total input overhead, billed against the subscription's
five-hour rate-limit bucket rather than API credits. Prime's tool schema can be injected as an MCP
server, and the resulting `tool_use` block is fully visible and capturable. What Claude Code
**cannot** do is accept a conversation history: there is no way to hand it a prepared list of
assistant turns and tool results. It only ever appends to a session it owns. That single limitation
is what decides the whole question — it means Prime cannot keep its message log and use Claude Code
as a stateless completion endpoint. Every workable design either hands the message history to Claude
Code (which makes Claude Code the harness) or degrades tool results into prose user messages (which
makes the loop lossy and drift-prone). Combined with a ToS position that is at best ambiguous and at
worst adverse, my recommendation is **do not build this as a Prime provider**; if you want it, build
the honest version — Prime's kernel behind an MCP bridge, Claude Code driving — and treat it as a
second, separate session type in Aviary rather than a transport swap.

---

## 1. How Claude Code's non-interactive surfaces actually behave here

All measurements are real invocations on this machine, 2026-08-21.

### 1.1 The built-in agent loop *can* be stripped

`--tools ""` genuinely empties the tool set. `system/init` reported `"tools": []`. The model does not
refuse or hallucinate tool calls; it answers as a plain completion.

The flags that matter, and what each is worth in tokens (same prompt, `Reply with exactly: PONG`,
model `sonnet`):

| Invocation | input | cache-write | notional cost |
|---|---|---|---|
| `-p --tools ""` (defaults otherwise) | 2 | **79,634** | $0.478 |
| `-p --tools "" --system-prompt "You are a test."` | 2 | **105,697** | $0.634 |
| `-p --tools "" --system-prompt … --strict-mcp-config --setting-sources "" --disable-slash-commands` | **286** | 0 | $0.0009 |

The 80–106k is my own environment leaking in: the claude.ai MCP connectors (Linear, Notion,
Honeycomb, Slack…), `~/.claude/CLAUDE.md`, plugins, skills. `--setting-sources ""` plus
`--strict-mcp-config` plus `--disable-slash-commands` removes essentially all of it. **286 tokens is
the floor** — I could not determine what those 286 tokens contain (see §7), but it is close enough to
zero that overhead is not an argument against this approach.

Note `total_cost_usd` is a client-side estimate (the docs say so explicitly) and is *not* what a
subscription session bills. The real signal is the `rate_limit_event` frame, which reported
`rateLimitType: "five_hour"`, `overageStatus: "allowed"`, `isUsingOverage: false` — i.e. plan usage,
not extra usage. **This is the thing that makes the whole idea attractive and it is confirmed.**

### 1.2 `--bare` is a trap for this use case

`--bare` is the documented, recommended way to strip a scripted session — and the docs say it "will
become the default for `-p` in a future release". But:

> In bare mode, Claude Code never reads OAuth credentials or the system keychain. For the Anthropic
> API, set `ANTHROPIC_API_KEY` in the environment […] Bare mode does not read
> `CLAUDE_CODE_OAUTH_TOKEN`.
> — `code.claude.com/docs/en/headless`

So the flag designed for programmatic use is exactly the flag that removes subscription auth. The
manual strip-down in §1.1 is the only way to get both. And the note that bare mode may become the
`-p` default is a standing durability risk for anything built here.

### 1.3 Prime's tool schema can be injected, and the tool call is capturable

I wrote a 40-line stdio MCP server exposing exactly one tool, `ipython(code)`, and ran:

```
echo 'Compute 2+2 using your kernel, then tell me the answer.' | claude -p \
  --output-format stream-json --verbose --no-session-persistence --model sonnet \
  --tools "" --system-prompt "You are Prime Agent. Your only tool is ipython, …" \
  --strict-mcp-config --setting-sources "" --disable-slash-commands \
  --mcp-config '{"mcpServers":{"prime":{"command":"python3","args":["…/mcp_ipython.py"]}}}' \
  --allowedTools "mcp__prime__ipython"
```

Result — `system/init` showed `tools: ['mcp__prime__ipython']`, `mcp_servers: [{name: prime, status:
connected}]`, then:

```
TOOL_USE mcp__prime__ipython {"code": "print(2+2)"} id=toolu_01D4jJv4cTmEtJhmDdSFyZbL
USER(toolresult) [{"tool_use_id":"toolu_01D4…","type":"tool_result","content":[{"type":"text","text":"STDOUT: 4\n(executed by the bridge stub)"}]}]
TEXT '2 + 2 = 4'
RESULT 2 + 2 = 4 | in 1742  out 70  turns 2
```

The MCP server's log confirmed it received `tools/call {"name":"ipython","arguments":{"code":"print(2+2)"}}`
with `_meta.claudecode/toolUseId`. So: **exactly one tool, no built-ins, real tool call, real tool
result, ~1.7k tokens of overhead.** The only cosmetic issue is the `mcp__<server>__<tool>` name
prefix, which is a trivial rename on the way back to Prime.

Gotcha worth recording: `--allowedTools` is variadic, so it swallows the positional prompt. Pass the
prompt on stdin.

Also verified: with `--permission-mode dontAsk` and the tool *not* allowed, the `tool_use` block is
still emitted in full (arguments included) and additionally lands in `result.permission_denials`,
while the MCP server is never invoked (`CALL` count 0). So you can observe Prime's intended action
without letting Claude Code perform it — but Claude Code then continues its own loop and answers
around the denial ("I attempted to run this in the kernel, but the tool call was denied… That said,
the 12th Fibonacci number is…"). You cannot ask it to *stop* at a tool call.

### 1.4 Streaming is fine

`--output-format stream-json --verbose --include-partial-messages` emits the raw Anthropic SSE frames
(`message_start`, `content_block_start`, `content_block_delta` with `text` / `partial_json`,
`content_block_stop`, `message_delta`, `message_stop`). That is precisely the shape Prime's
`AssistantMessageEventStream` wants; mapping is mechanical. Tool-call arguments arrive as
`partial_json` deltas, so `toolcall_delta` is available too.

### 1.5 Thinking comes back empty

With `--effort high`, the assistant message contained a `thinking` block whose `thinking` field was
the **empty string** and whose `signature` was an opaque ~200-byte blob. The token count *is*
reported: `usage.output_tokens_details.thinking_tokens: 274`. So through Claude Code, Prime would get
zero visible reasoning content and only a count — structurally identical to the encrypted-reasoning
situation this fork already cares about, and it maps cleanly onto the fork's `Usage.reasoning`. I did
not determine whether any flag exposes the thinking text in `-p` mode.

### 1.6 History cannot be injected — the decisive finding

`--input-format stream-json` accepts a stream of `{"type":"user","message":{…}}` lines. I fed it a
three-line history including an `{"type":"assistant", …}` turn:

```
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Remember the secret word: ZEBRAFISH."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Got it, the secret word is ZEBRAFISH."}]}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"What was the secret word? Reply with just the word."}]}}
```

The assistant line was **silently ignored**. Claude Code treated the two user lines as two
independent turns, generated its own assistant reply to the first ("Noted: ZEBRAFISH."), emitted two
separate `result` frames, and kept its own session history in between. There is no documented or
observed way to hand Claude Code a prepared transcript.

Two workarounds exist, both bad:

- **Flatten**: serialize Prime's whole conversation into one giant user message each turn. Loses
  native assistant-turn and `tool_result` structure — the exact format the model is trained on for
  tool loops — and re-sends the transcript as fresh user text each turn.
- **Forge a session file**: `~/.claude/projects/<slugged-cwd>/<session-uuid>.jsonl` is plaintext
  newline-JSON and *is* the resume source. I confirmed the format on a session I created myself: a
  chain of records typed `queue-operation`, `attachment`, `user`, `assistant`, `last-prompt`, `mode`,
  each carrying `uuid`/`parentUuid`/`sessionId`/`cwd`/`gitBranch`/`version`, with `last-prompt`
  holding a `leafUuid`. Writing that chain by hand is undocumented, version-coupled, and would break
  on any Claude Code release. (Separately, `~/.claude/sessions/*.json` has a paired `.key` file per
  session; I did not inspect the contents.)

### 1.7 Interrupt-and-resume works, and is the closest thing to "Prime owns the loop"

The one non-obvious result worth recording. I ran a session, watched the stream, captured the first
`tool_use` block, and sent SIGINT at that moment:

```
CAPTURED {"type":"tool_use","id":"toolu_01Y9iDUrweZkNumXjog6uq5C","name":"mcp__prime__ipython",
          "input":{"code":"\na, b = 0, 1\nfor _ in range(12):\n    a, b = b, a+b\na\n"}, …}
exitcode 0
```

Then resumed that session id with the externally-computed result as the next user message:

```
echo 'Tool result for your last ipython call: "144". Continue.' | claude -p --resume <sid> …
→ TEXT 'The 12th Fibonacci number is **144**.'   err False  turns 1
```

It works. Prime could drive a loop this way: Claude Code holds the history, Prime captures each tool
call, executes it in its own kernel, and feeds the result back. What it gives up: the result arrives
as prose in a *user* message rather than a real `tool_result` block, the interrupted `tool_use` sits
unresolved in the transcript, and `tool_result` affordances (`isError`, image content — which Prime's
`ipython` tool does return, it filters attachments to image MIME types) have no home. Over a long
session this drifts steadily away from the format the model was trained on.

### 1.8 Per-turn process cost

Roughly **2.5–3.2 s of process overhead per turn** on top of inference. Measured on a resume turn
producing a two-token answer: wall 7.57 s, `duration_api_ms` 4394, `duration_ms` 5008,
`time_to_request_ms` 294. Cold starts with MCP servers attached were worse (~8.8 s wall for a 5-token
reply). A long-lived process amortizes this; one spawn per Prime turn does not.

### 1.9 Flags that turned out not to help

- `--json-schema` (structured output) works but is a worse tool channel than MCP: you lose native
  tool-use training, and it does not compose with tool calls.
- `claude mcp serve` is the wrong direction (exposes Claude Code's *tools* to an MCP client, not its
  inference).
- `--max-budget-usd`, `--fallback-model`, `--no-session-persistence`, `--session-id`, `--resume`,
  `--fork-session` all behave as documented and are useful plumbing, but none address history
  injection.
- A `SessionStart` hook still fired even with `--setting-sources ""` (one plugin was still
  initialized). If you build anything here, verify the environment is as clean as you think from
  `system/init`, not from the flags you passed.

---

## 2. What a Prime provider actually demands

Better news than expected: this fork needs **no core changes**. Prime already has two documented
extension points.

**Cheap path — `models.json` / `pi.registerProvider(name, {baseUrl, api, models})`.** Prime supports
custom providers speaking `anthropic-messages`, `openai-completions`, `openai-responses`, or
`google-generative-ai` at an arbitrary `baseUrl`, configured either in `~/.prime/agent/models.json`
or from an extension, with **zero code**. If a local HTTP shim spoke Anthropic Messages, Prime would
need only a config entry. (`packages/coding-agent/docs/models.md`, `docs/providers.md` § Custom
Providers.)

**Proper path — a custom streaming provider in an extension.** `pi.registerProvider()` accepts a full
`streamSimple` implementation. The contract (`packages/ai/src/types.ts`,
`packages/ai/src/api-registry.ts`, `packages/coding-agent/docs/custom-provider.md`):

- Signature: `(model: Model<Api>, context: Context, options?: SimpleStreamOptions) => AssistantMessageEventStream`.
- `Context` is `{ systemPrompt?, messages: Message[], tools?: Tool[] }` — a **full message list every
  call**. `Message` is `UserMessage | AssistantMessage | ToolResultMessage`. This is precisely the
  thing Claude Code will not accept (§1.6).
- Must return the stream, never throw after invocation: request/model/runtime failures are encoded
  *in* the stream as an `error` event carrying an `AssistantMessage` with `stopReason` `"error"` or
  `"aborted"`.
- Event protocol: `start` → `{text,thinking,toolcall}_{start,delta,end}` (each carrying
  `contentIndex` and the running `partial`) → `done` or `error`.
- `ToolCall` is `{type:"toolCall", id, name, arguments}`; tools are declared as
  `{name, description, parameters: TSchema}` (typebox → JSON Schema, which MCP `inputSchema` takes
  directly).
- `Usage` is `{input, output, cacheRead, cacheWrite, reasoning?, totalTokens, cost{…}}`. Claude
  Code's `result.usage` maps well: `input_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`, `output_tokens`, and `output_tokens_details.thinking_tokens` →
  **`Usage.reasoning`**, the fork's existing divergence. Cost, though, is a lie under a subscription:
  `calculateCost()` would multiply real tokens by per-million prices that were never charged.
  A subscription provider should report `cost.total = 0` and let usage be the truth — which is itself
  a small fork decision to make deliberately.

Registration is `registerApiProvider({api, stream, streamSimple})` into a `Map` keyed by `api`
string; `Api` is `KnownApi | (string & {})`, so a new api name like `"claude-code-cli"` needs no type
change. Aviary already loads a harness extension (`harness-extensions/wire-log.ts`, referenced from
`app/Sources/AviaryCore/AgentHome.swift`), so a provider extension slots into the same
`settings.json` `extensions: [...]` array. **A provider addition here costs one new file and one
settings line. The provider interface is not the hard part.**

One incidental find worth knowing, from `packages/coding-agent/docs/providers.md`:

> ### Claude Pro/Max
> Anthropic subscription auth is active for Claude Pro/Max accounts. Third-party harness usage draws
> from [extra usage](https://claude.ai/settings/usage) and is billed per token, not against Claude
> plan limits.

That is the mechanism you are trying to route around, stated by Prime itself: Prime's existing Claude
login *does* use subscription OAuth, and Anthropic still meters it as extra usage. Which means the
subscription-included path is not about *which credential* is used — it is about *which client*
Anthropic sees. Only the real `claude` binary gets the plan bucket.

---

## 3. Candidate approaches, ranked

### A. MCP bridge — Claude Code drives, Prime's kernel is the tool *(recommended if you build anything)*

Long-lived `claude -p --input-format stream-json --output-format stream-json` per session, stripped
per §1.1, with a stdio MCP server exposing exactly `ipython` (and whatever else a Prime session
declares), bridging into a real Prime kernel over a socket.

- **Mechanism**: fully verified end to end in §1.3.
- **Cost to build**: ~1 day. The MCP bridge is small; the kernel-side socket is the real work.
- **What survives**: the IPython kernel, Prime's Python skill modules, `rlm()` recursion, everything
  kernel-side — because all of it lives *inside* the kernel, not in the agent loop. This is more of
  Prime than it first appears.
- **What is given up**: Prime's agent loop, its session JSONL, continual-harness state, its provider
  layer, its usage accounting, `before_provider_request` (and therefore Aviary's wire-log), and
  Prime's `--mode rpc` embedding contract that Aviary is built on. Aviary would need a second session
  type, not a swapped transport.
- **Degrades**: gracefully. It is just Claude Code with one weird tool.
- **Honest framing**: this is not "Claude Code as transport". It is "Prime's kernel as a Claude Code
  tool". Different product. But it is the only one that is not fighting the tool.

### B. Interrupt-and-resume — Prime drives, Claude Code holds history

Per §1.7: capture the first `tool_use`, SIGINT, execute in Prime's kernel, resume with the result as
a user message.

- **Mechanism**: verified working for one round trip.
- **Cost to build**: ~2–4 days for a provider that is honest about its own limits.
- **What survives**: Prime's loop, its session files, its RLM, its skills — nominally everything.
- **What is given up**: real `tool_result` semantics (no `isError`, no image results), thinking
  content (empty anyway, §1.5), Prime's own message log as the source of truth (Claude Code's session
  becomes the real history and Prime's a shadow copy), and correctness under any Claude Code change
  to interrupt/resume behavior. Plus 2.5–3 s per turn if you spawn per turn.
- **Degrades**: badly and quietly. Two divergent histories, tool results as prose, a dangling
  `tool_use` per turn. The failure mode is a session that looks fine and reasons slightly worse.

### C. Local Anthropic-Messages shim + `pi.registerProvider("x", {baseUrl})`

An HTTP server that speaks `/v1/messages`, implemented by shelling out to `claude -p`. Prime needs
zero code — one `models.json` entry.

- **Mechanism**: the shim's *interface* is trivially compatible. Its *implementation* runs straight
  into §1.6: it receives a full `messages[]` array and has nowhere to put it. It must flatten to one
  user message, or forge session files, or maintain a hidden session-id map and hope Prime's replay
  matches what Claude Code already believes. All three are wrong in different ways.
- **Cost to build**: deceptively low to demo, high to make correct, and it never becomes correct.
- **This is what the community proxies are**, and it is why none of them handle tool loops well.

### D. LiteLLM — does not apply

Checked specifically, since it would have been the cleanest integration point given the gateway at
`localhost:4000`.

LiteLLM's Claude Code support runs the **opposite direction**: Claude Code → LiteLLM → Anthropic,
with `forward_client_headers_to_llm_api: true` passing the client's OAuth header upstream so LiteLLM
can meter a Max-subscription session it does not itself authenticate. It cannot serve
subscription-backed inference *to* another client. There is a third-party
`cabinlab/litellm-claude-code` custom provider that wraps the Claude Agent SDK behind an
OpenAI-compatible interface, but its own README describes converting "messages to Claude prompt
format" (the lossy flatten), lists streaming as *partial*, and does not mention tool calling at all —
useless for a harness whose entire loop is tool calls.

**Verdict: LiteLLM offers nothing here.** The gateway stays what it is — the metering point for
API-billed calls. Subscription-included traffic will not flow through it, which also means this whole
idea takes that traffic *off* your metering point.

### E. Community proxies — all the same trick, none load-bearing

`i-am-logger/claude-code-proxy` (8 commits), `wende/claude-max-api-proxy` ("actively maintained fork",
15 commits), `sethschnrt/claude-max-api-proxy`, `fuergaosi233/claude-code-proxy`,
`empero-org/claude-code-proxy`. All spawn `claude --print` as a subprocess and expose OpenAI- or
Anthropic-shaped HTTP. All handle multi-turn by holding a Claude Code session id and appending — i.e.
approach A wearing approach C's clothes. Tool-call support is absent or maps onto Claude Code's *own*
tool names (`wende` maps `exec`/`read`/`web_search` to Claude Code equivalents), which is the opposite
of injecting Prime's schema. Maintenance state: hobby. None of them solve the history problem because
it is not solvable from outside.

Worth noting they all make the same ToS argument, in nearly identical words — that spawning
`claude --print` is "an officially supported programmatic use pattern" and that they avoid the
prohibition because they never extract a token. That argument is doing a lot of work for them; see
below.

---

## 4. Authentication

- **Storage**: macOS Keychain, service `Claude Code-credentials` (I confirmed the entry exists; I did
  not read it). Linux/Windows use `~/.claude/.credentials.json` at mode 0600.
- **Precedence** (docs, `authentication`): cloud provider → `ANTHROPIC_AUTH_TOKEN` →
  `ANTHROPIC_API_KEY` → `apiKeyHelper` → `CLAUDE_CODE_OAUTH_TOKEN` → Anthropic profile/federation →
  `/login` subscription OAuth. **Anything in the environment silently wins over your subscription.** A
  headless Aviary daemon must guarantee `ANTHROPIC_API_KEY` is unset, or it will quietly spend API
  money while looking like it worked. `apiKeySource: "none"` in the `system/init` frame is the check.
- **Long-lived headless use**: `claude setup-token` mints a **one-year** OAuth token, set as
  `CLAUDE_CODE_OAUTH_TOKEN`. Docs: "This token authenticates with your Claude subscription and
  requires a Pro, Max, Team, or Enterprise plan. It can only make model requests, so it can't
  establish Remote Control sessions or fetch claude.ai connectors." That is exactly the right shape
  for a daemon — and note it is the *documented* mechanism for non-interactive subscription auth,
  which is relevant to §5.
- **Expiry**: a `/login` credential warns three days out; once expired every request fails with
  `Login expired · Please run /login` and cannot recover unattended. The docs call this out
  specifically for long-running sessions. A `setup-token` credential dies once a year with, as far as
  I can tell, no warning path in `-p`. Any daemon needs to surface `claude auth status` in Aviary's
  Health panel and treat auth failure as a first-class session state, not an inference error.
- **Failure surface**: `system/api_retry` frames carry an `error` category including
  `authentication_failed` and `oauth_org_not_allowed`, so auth trouble is machine-detectable mid-run.
- **Do not** extract the keychain credential and call `api.anthropic.com` with it. Server-side
  enforcement has been live since January 2026 and returns "This credential is only authorized for
  use with Claude Code and cannot be used for other API requests." It is both blocked and squarely
  prohibited.

---

## 5. Terms of service — what the documents actually say

The governing text is `code.claude.com/docs/en/legal-and-compliance`, § *Authentication and credential
use*, quoted in full:

> Claude Code authenticates with Anthropic's servers using OAuth tokens or API keys. These
> authentication methods serve different purposes:
>
> * **OAuth authentication** is intended exclusively for purchasers of Claude Free, Pro, Max, Team,
>   and Enterprise subscription plans and is designed to support ordinary use of Claude Code and
>   other native Anthropic applications.
> * **Developers** building products or services that interact with Claude's capabilities, including
>   those using the [Agent SDK], should use API key authentication through [Claude Console] or a
>   supported cloud provider. Anthropic does not permit third-party developers to offer Claude.ai
>   login or to route requests through Free, Pro, or Max plan credentials on behalf of their users.
>
> Anthropic reserves the right to take measures to enforce these restrictions and may do so without
> prior notice.

And from § *Acceptable use* on the same page:

> Claude Code usage is subject to the [Anthropic Usage Policy]. Advertised usage limits for Pro and
> Max plans assume ordinary, individual usage of Claude Code and the Agent SDK.

Which license applies is also stated there:

> * Commercial Terms — for Team, Enterprise, and Claude API users
> * Consumer Terms of Service — for Free, Pro, and Max users

**Reading this honestly, four things are true at once:**

1. **The hard prohibition is narrower than the headlines.** The only "does not permit" sentence is
   about *third-party developers* doing two specific things: offering Claude.ai login, and routing
   requests through Free/Pro/Max credentials **"on behalf of their users."** A single person driving
   their own Claude Code on their own machine for their own work is not obviously within it. Note
   also that this sentence names Free/Pro/Max and **not Team** — and your account is Team, governed by
   the Commercial Terms rather than the Consumer Terms.
2. **The soft guidance points the other way, and it names the Agent SDK.** The developer clause says
   anyone "building products or services that interact with Claude's capabilities, including those
   using the Agent SDK, **should** use API key authentication." Aviary is a product that interacts
   with Claude's capabilities. "Should" is not "must", but you would be building the thing the
   sentence is describing.
3. **The load-bearing word is undefined.** OAuth is for "**ordinary** use of Claude Code", and plan
   limits "assume **ordinary, individual** usage of Claude Code and the Agent SDK." Nothing defines
   ordinary. A personal automation invoking the shipped CLI with the shipped `-p` flag has a real
   claim to it — `claude -p` is documented as the supported programmatic surface, `claude setup-token`
   exists precisely so scripts can authenticate against a subscription, and both are Anthropic's own
   features. A harness that drives it continuously to run an unbounded agent loop has a weaker claim.
   **This is genuinely ambiguous and I am not going to resolve it for you.** The same page also says
   `setup-token` "requires a Pro, Max, Team, or Enterprise plan" — Anthropic ships a
   subscription-authenticated headless credential, which is hard to square with a blanket reading
   that headless subscription use is off-limits.
4. **What is unambiguously prohibited is the thing you were not proposing**: extracting the OAuth
   token and using it outside Claude Code. Reporting from 2026-02-19/20 (The Register, and Anthropic's
   own doc update that day) is consistent that this is the target, and enforcement has been live since
   January 2026.

One more asymmetry worth weighing: the community-proxy argument that "spawning `claude --print` is an
officially supported programmatic use pattern" is a *technical* claim dressed as a legal one. It is
true that the subprocess is the real client with its real credential. It does not follow that the
documents bless using it as a component of another agent harness. And "Anthropic reserves the right
to take measures […] without prior notice" means the practical risk is not a lawsuit, it is your
account or your org's account breaking mid-session with no warning — which for a **Team** account is a
shared blast radius, not just yours.

**My read, stated as a read and not as advice:** a personal, single-user, localhost harness driving
`claude -p` sits in a genuine grey zone that the documents do not clearly forbid and do not bless.
The greyness itself is the argument against building infrastructure on it.

---

## 6. Recommendation, and the first concrete step

**Do not build a Claude Code provider for Prime.** The blocker is not effort or plumbing — Prime's
extension points are unusually accommodating and a provider is one file. The blocker is that Claude
Code will not accept a conversation history, and every way around that either inverts the control you
are trying to keep (A) or quietly degrades the tool loop you are trying to preserve (B, C). You would
be spending real effort to build something structurally worse than Prime's existing Anthropic path,
resting on a ToS reading you cannot confirm, on a surface whose recommended mode (`--bare`) explicitly
drops subscription auth and may become the `-p` default.

**If the economics matter enough to act anyway, build approach A and call it what it is.** A second
Aviary session type: Claude Code as the agent, a live Prime kernel behind an MCP bridge as its only
tool. You keep the kernel, the skills, and `rlm()` — everything that actually makes Prime interesting
— and you stop pretending the loop is Prime's.

**First concrete step, ~2 hours, zero commitment:** take the throwaway MCP server from this
investigation and point it at a *real* Prime kernel instead of a stub, then run one stripped
`claude -p` session against it and try a task that needs three or four kernel round-trips with a skill
import. That single experiment answers the only question that actually matters — *does a
Claude-Code-driven loop with Prime's kernel feel like Prime or feel like a worse Claude Code?* — and it
answers it before any provider code exists. If it feels like Prime, approach A is real. If it feels
like a worse Claude Code, the answer to the whole question is no, and you have spent an afternoon.

Second step regardless of the above: **write down what the subscription is actually saving you.**
Pull a week of Aviary's wire-log token counts, price them at Anthropic list, and compare against the
Team seat. If the gap is small, the entire question dissolves and Prime's existing Anthropic provider
is the answer. That number should exist before any of this gets built, and it belongs in `LEDGER.md`.

Artifacts from this investigation (throwaway, safe to delete):
`/private/tmp/claude-501/-Users-ryan-duckbill/a228e3a2-2540-457d-aa24-522cdcb8f7c6/scratchpad/cc-test/`
— `mcp_ipython.py` (the one-tool MCP bridge stub) and `killcap.py` (the interrupt-on-tool_use capture).

---

## 7. What I could not determine

- **What the 286-token floor contains.** `--debug api --debug-file` did not log request payloads in
  2.1.234, and I did not intercept TLS. So I cannot say whether a residual system prompt, a tool-free
  scaffold, or metadata accounts for it.
- **Whether thinking text can be exposed in `-p`.** It came back as an empty string with a signature
  under `--effort high` with settings stripped. I did not test `/config thinking=…`, an interactive
  session, or other effort levels, so I cannot say whether this is a `-p` property, a redaction, or a
  setting I removed.
- **Whether interrupt-and-resume holds up over many turns.** I verified exactly one capture → execute
  → resume round trip. I did not test ten, or images in results, or two tool calls in one assistant
  turn, or what the dangling `tool_use` records do to the transcript over time.
- **Whether forged session JSONL actually resumes.** I confirmed the file is plaintext and read its
  record structure from a session I created. I did not attempt to write one.
- **Whether Anthropic distinguishes CLI-spawned-by-a-harness from CLI-spawned-by-a-human.** The
  `rate_limit_event` showed plan usage for my programmatic call, which says it is *not* distinguished
  today. Nothing in the docs says it will stay that way, and Prime's own note about Pro/Max harness
  usage billing as extra usage shows Anthropic does make exactly this kind of distinction elsewhere.
- **Whether Team-plan status changes the ToS answer.** The prohibition sentence names Free/Pro/Max;
  Team falls under the Commercial Terms, which I did not read in full. The Commercial Terms may
  address this and I did not check.
- **Whether `--bare` will become the `-p` default and what happens to OAuth then.** The docs announce
  the former and say nothing about the latter.
- **Actual dollar savings.** Not measured. See step two above.

### Sources

- [Claude Code — Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [Claude Code — Authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code — Run Claude Code programmatically (headless)](https://code.claude.com/docs/en/headless)
- [LiteLLM — Using Claude Code Max Subscription](https://docs.litellm.ai/docs/tutorials/claude_code_max_subscription)
- [cabinlab/litellm-claude-code](https://github.com/cabinlab/litellm-claude-code)
- [wende/claude-max-api-proxy](https://github.com/wende/claude-max-api-proxy)
- [i-am-logger/claude-code-proxy](https://github.com/i-am-logger/claude-code-proxy)
- [The Register — Anthropic clarifies ban on third-party tool access to Claude](https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access/)
- Local: `harness/packages/ai/src/types.ts`, `harness/packages/ai/src/api-registry.ts`,
  `harness/packages/coding-agent/docs/custom-provider.md`,
  `harness/packages/coding-agent/docs/providers.md`,
  `harness/packages/coding-agent/src/core/tools/ipython.ts`, `harness/FORK.md`
