# The fork

Vendored from [PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent)
at commit `c75a637b00d3b52762841e72efe92289a0d55b49` (version `0.7.4-beta.531.1.c75a637`,
authored 2026-08-20), with upstream history dropped and no remote configured.

This is a **hard fork**. There is no compatibility obligation, no merge path back, and no
attempt to track upstream. When Aviary needs the engine to expose something, the engine
changes.

## Divergence

Nothing yet. Every capability Aviary needs so far, the harness already offered:

- **RPC mode** (`--mode rpc`) for driving a live run — a documented embedding contract with
  LF-delimited JSON commands in and events out.
- **`list --json`** for live session state, which is the only source for *now*: whether a
  session is streaming, what it is waiting on, which worker holds it, and the RLM parentage
  of every sub-agent.
- **`doctor --json`** for the daemon handshake.
- The on-disk formats: session JSONL, `rlm-subagents.jsonl`, the spawn ledger, worker
  descriptors, `models.json`, `settings.json`.

Record changes here as they happen, with the reason. A fork whose divergence is undocumented
is just a stale copy.

## Known friction worth fixing in the fork eventually

- **Two builds cannot share one daemon.** A supervisor refuses connections from a client
  reporting a different version, so the fork and an installed `prime-agent` cannot coexist
  while either holds a busy session. Aviary detects and explains this (Health →
  "Version conflict") rather than working around it. The real fix is either a per-build
  socket namespace or a version-tolerant handshake.
- **MCP is HTTP-only**, so stdio MCP servers (Playwright, most local ones) do not load.
