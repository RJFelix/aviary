# The fork

Vendored from [PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent)
at commit `c75a637b00d3b52762841e72efe92289a0d55b49` (version `0.7.4-beta.531.1.c75a637`,
authored 2026-08-20), with upstream history dropped and no remote configured.

This is a **hard fork**. There is no compatibility obligation, no merge path back, and no
attempt to track upstream. When Aviary needs the engine to expose something, the engine
changes.

## Divergence

### `Usage.reasoning` — preserve the provider's reasoning-token count

`packages/ai/src/types.ts`, `packages/ai/src/providers/openai-responses-shared.ts`.

The responses API reports `usage.output_tokens_details.reasoning_tokens`; upstream reads
`input_tokens_details.cached_tokens` from the same object and drops the reasoning count on
the floor. That makes a hidden-reasoning route unaccountable: on a route that returns
thinking as text you can measure it yourself, but on an encrypted-reasoning route
(`include: ["reasoning.encrypted_content"]`, which is what the Codex route uses) the count
is the *only* evidence the tokens existed. A turn reporting `output: 7` may have burned
thousands of them.

Added as an optional field, because absent and zero mean different things — absent is
"this route didn't say". It is a breakdown of `output`, never an addend: providers bill
reasoning as output.

Everything else Aviary needs, the harness already offered:

- **RPC mode** (`--mode rpc`) for driving a live run — a documented embedding contract with
  LF-delimited JSON commands in and events out.
- **`list --json`** for live session state, which is the only source for *now*: whether a
  session is streaming, what it is waiting on, which worker holds it, and the RLM parentage
  of every sub-agent.
- **`doctor --json`** for the daemon handshake.
- The on-disk formats: session JSONL, `rlm-subagents.jsonl`, the spawn ledger, worker
  descriptors, `models.json`, `settings.json`.
- **`before_provider_request`**, an extension event carrying the exact provider payload
  after serialization and before the send. Aviary records payloads through it rather than
  patching the providers, so "show me everything that was sent to the model" needed no
  divergence at all — see `harness-extensions/wire-log.ts`.

Record changes here as they happen, with the reason. A fork whose divergence is undocumented
is just a stale copy.

## Known friction worth fixing in the fork eventually

- **Two builds cannot share one daemon.** A supervisor refuses connections from a client
  reporting a different version, so the fork and an installed `prime-agent` cannot coexist
  while either holds a busy session. Aviary detects and explains this (Health →
  "Version conflict") rather than working around it. The real fix is either a per-build
  socket namespace or a version-tolerant handshake.
- **MCP is HTTP-only**, so stdio MCP servers (Playwright, most local ones) do not load.
