# Runner handoff: local ⇄ exe.dev VM

*Plan, 2026-09-22. Moves ongoing Work between the local runner and a runner on an exe.dev VM (and back), with the agent as a cooperating participant. Builds on the Stage 4 remote-GUI design in `process-split.md` and the ownership laws in `handles-and-ownership.md` (D13–D16, H1/H2).*

## Goal

A run in progress can be zapped from the local runner to an exe.dev VM runner at 5:30 — and pulled back home later — and continue with its conversation, Python namespace, Work-owned children, and workspace files intact.

## Success Criteria

- A handed-off run continues on the target without re-running cells or re-doing analysis: picklable namespace values arrive live, the journal continues from the same cursors, usage accounting is continuous, and child Handles stay resolvable.
- Anything that cannot transfer arrives as an explicit tombstone (name, type, repr, why) plus the agent's own continuation note — never a silently wrong value.
- Either the handoff commits on the target or it aborts with the source still authoritative. Never two writers.
- Secrets never cross the wire; the target re-resolves its own credentials.

## Context And Current Facts

- Ownership already points at this: Work is owned by a durable **Work Host**, not the GUI or originating conversation; detachment carries no termination intent; local and remote share one logical model (`plans/handles-and-ownership.md`). Stage 4 (remote GUI over an authenticated/SSH-tunneled transport) is designed but unbuilt (`plans/process-split.md`); "SSH stream-local forwarding proves the protocol can cross devices" (README).
- The control surface that must cross hosts exists in journal-backed form: `JournalBackedWorkService`, `RunJournalBundle` (cursors, retained bodies, provider usage at exactly `workCursor`), `NativeColdResumeResult`, and `WorkRef = {work_host_id, work_id}`.
- Two coded constraints bound the design: a reconstructed conversation is **not** evidence the Python namespace survived (`AviaryCore/NativeColdResume.swift`), and a retained socket/descriptor is **never** liveness proof (`HostedInHouseWorkAdoptionEvidence.isLivenessProof` is always false — re-verify with a fresh identity-checked handshake).
- Runtime hosts (`runtime-hosts/python3*/host.py`, protocol v3) give `exec` / `inspect` / `session.attach` / `session.detach`. `inspect` lists `{name, type, repr, length}` — enough to see a namespace, not to move it. There is **no snapshot/restore op**; that is the gap. Host-private names are mangled and hidden from `inspect`; on the shared host `sys.modules` and C-extension globals are process-wide, not per-session — so "the namespace" is the session dict, nothing more.
- Futures (`docs/runtime-host-protocol.md`): `spawn()` returns a Future over a durable Handle for Work-owned children; process-local fallback children live only in the originating runner. Only the first kind can move.
- The workspace registry never crosses the host boundary (`AviaryCore/LocalWorkHostLaunchResolver.swift`): an opaque `workspaceID` maps to a path separately per machine. The target needs the Work's directory materialized under its own registry, not the user's whole disk.
- Today's `aviaryd` authorizer is local-only (`aviaryd/main.swift`: "a future remote transport supplies a principal-backed authorizer instead"). Version-skew rule from `process-split.md`: version-stamped handshakes, never migrate live Work across a build boundary.
- The Linux target is already a bounded product: `app/Package.swift` (`#if os(Linux)`) compiles `aviaryd` plus curated core sources, excluding Apple-only code.
- exe.dev (inspected docs, see Sources): subscription VMs with persistent disks and pooled CPU/RAM; provisioned via `ssh exe.dev new` (`--cpu/--memory/--disk/--name/--image/--setup-script`, 10 KiB setup-script cap); each VM at `<vm>.exe.xyz` over SSH plus a private-by-default HTTPS proxy forwarding ports 3000–9999. Stock image ships `uv`, `git`, `just`, `rsync`, `sqlite3`.

## Constraints And Non-goals

- Handoff happens at a turn boundary **plus one packing turn** (see below), never mid-model-stream and never mid-`exec`. In-flight provider SSE streams terminate at the originating process; they are not spliced.
- Picklable values transfer; everything else tombstones (open files/sockets, threads/locks, modules, C globals, process-local Futures). Tombstones carry source `repr` and are unusable-by-construction (absent names), not stale copies.
- The resumed context must preserve the pre-move prefix **byte-identical**: the original system prompt is never re-emitted or altered (any alteration busts the prefix cache and repays full prefill). All move-related deltas ride in-band as conversation turns past the boundary.
- macOS GUI stays local; only the runner moves. Same-build-stamp gate on both ends. `claude -p` driven runs are excluded (their conversation belongs to Claude Code).
- Non-goals: CRIU-style process migration (impossible macOS→Linux); blind `exec`-history replay as the default (re-running cells duplicates `sh()` side effects); public exposure of the Work protocol; Linux GUI; auto-failover.

## Key Decisions

1. **Handoff, not live migration — with a cooperative packing turn.** Timing is relaxed to *finish the current turn, then grant one more turn*. The extra turn is the agent's: prompted with a packing brief (outcome table preview, tombstone list, workspace dirtiness), it writes a **continuation note** (what was in flight, the next step, what to rebuild) and optionally a **rehydrate script** saved into the workspace overlay so it travels with the files. A cooperating agent simplifies the machinery (no need to infer intent from raw state) and the UX (the resumed run explains itself). The fence carries a deadline and an explicit release, and a crashed coordinator recovers via a `held`-state probe — never a lease that needs manual force (cf. the poisoned-lease scar tissue). Rejected: freezing instantly at an arbitrary point and reconstructing intent mechanically.
2. **Namespace snapshot/restore as data, via a new host op pair.** `session.snapshot` pickles per variable (`cloudpickle`, fallback `dill`, then stdlib `pickle`) returning bytes-or-tombstone per name; `session.restore` unpickles into a fresh session dict and installs tombstones, reporting per-name outcomes. Preflight also asserts the target offers the same runtime variant — a `python3-shared` (numpy/polars) session cannot restore where that variant is unavailable. Rejected: process migration (cross-OS non-starter); history replay as default (side-effect duplication — kept only as an explicitly-requested fallback for pure-compute sessions).
3. **Per-variable outcome table, and the agent narrates the gaps — laid out to protect the prefix cache.** Each name resolves to `restored | tombstoned | skipped (host-private)`. The resumed context is laid out as:
   - original system prompt (untouched) + rest of original context (untouched),
   - the cooperative move-out turn,
   - — - move boundary — -,
   - move-in instructions as ordinary conversation (outcome table, continuation note, any system-prompt *deltas stated as message content*, never as prompt edits),
   - rehydration script outputs, if any,
   - continue work.
   
   Everything before the boundary keeps its cached prefix; everything the move adds is a cheap uncached tail. This is helped by the single-`python`-tool design: one small tool schema keeps the system prompt short and stable, which shrinks both the parity surface and the cost at risk if the cache ever does bust.
4. **Move exactly one workspace: git first, rsync overlay second — plus the portable parts of home.** Push the branch (or bundle it), clone/checkout the same commit on the target, then rsync only the dirty + untracked overlay for the Work's `workspaceID`. A local worktree transfers as a branch checkout at the same commit under the target registry's path — the agent sees the same files; only the path differs, which is the registry's business. Coming home re-syncs the overlay back as ordinary uncommitted changes. The bundle additionally carries the project/global memory scopes (namespaced by origin — the resumed agent must not silently know less) and content hashes of the cold-resume parity inputs (skills library, memory, models config); a mismatch aborts in preflight, before fencing, because re-resolving or syncing those inputs is always preferred to re-emitting the system prompt. v1 refuses handoff when the workspace is enormous or pathologically dirty, with the `git status` summary in the refusal — no exclusion rules or multi-worktree moves up front.
5. **Futures split by ownership.** Work-owned children transfer by Handle ID and reattach on the target; process-local children and outstanding `callback` RPCs tombstone, and a blocked parent cell resumes with an explicit readable error per the protocol's refusal-is-a-payload rule.
6. **SSH tunnel is the control transport, not the HTTPS proxy.** `ssh <vm>.exe.xyz` with stream-local forwarding carries the transport-neutral Work protocol byte-for-byte, matching the already-proven forwarding experiment and Stage 4's SSH-tunnel option. The proxy stays for optional artifact/UI convenience. The Work port is never made public.
7. **Round-trip is the same op twice.** Pulling the run home is a second handoff, not a special case. Target resolves — never receives — secrets, via its own launch snapshot; exe.dev Root maps to control capabilities, Web-only to read-only.

## Recommended Approach

Add the missing primitive (namespace snapshot/restore), wrap the transfer in a fenced turn-boundary + packing-turn protocol where the agent authors its own continuation, move one workspace via git + overlay (plus memory scopes and parity hashes), lay out the resumed context to preserve the cached prefix, and admit on the target as a linked continuation. The 5:30 story and the come-back-home story are the same code path run twice. Prove the whole path local↔local before any cloud involvement, so the VM only ever adds provisioning + SSH.

## Work Plan

1. **Namespace snapshot/restore ops.** `session.snapshot` / `session.restore` on both bundled hosts, chunked under the 4 MiB frame bound; host-private names excluded; tombstones as `{name, type, repr, reason}`. Swift wiring in `RuntimeHost.swift`. Preflight estimator (per-name picklability + bytes, plus target runtime-variant availability) that reports *before* fencing the source.
2. **Packing-turn protocol.** Fence semantics: finish current turn, suppress new external turns, inject the packing brief (outcome preview, tombstones, workspace dirtiness, child-Handle table). If the session is close to full, compact on the source *before* fencing — the packing turn needs room, and the moved context is smaller for it; "agent reports it cannot pack" is a clean abort, not a failure. Continuation-note schema (in-flight state, next step, rebuild list) journaled as a transfer artifact; rehydrate-script convention (saved in the workspace overlay, run once on resume, then archived). Fence carries a deadline with explicit release; daemon probes and recovers stale `held` state on boot.
3. **Linux runner artifact + VM recipe.** Verify the `os(Linux)` `aviaryd` product plus both Python hosts on the exeuntu image; single version-stamped install via `ssh exe.dev new --name aviary-runner --cpu/--memory/--disk --setup-script` (10 KiB cap; remainder from a pinned URL). Receipt: build-stamp equality both ends.
4. **Handoff command as journaled ownership transfer.** Source enters fenced `held` state with a handoff token; ships journal tip + snapshot manifest + continuation note + memory scopes + workspace overlay + child table. Target verifies digests + stamp + parity hashes, re-resolves launch material and secrets locally, admits as linked continuation with the outcome table and continuation note as first context past the move boundary, runs the rehydrate script once. Abort leaves the source authoritative and unfences.
5. **GUI across hosts.** Local GUI lists local + VM Work with unambiguous `WorkRef`; transfer states (`prepared → held → packing → snapshotted → resuming → running`) visible with cursors; concurrent commands during the window get deterministic ordering with stale/conflict outcomes. Preflight panel shows workspace size/dirtiness, snapshot estimate, and parity-hash comparison before the user confirms.
6. **Round-trip proof.** Ladder: (0) two local `aviaryd` instances on two Unix sockets — the full fence/pack/snapshot/admit path with no cloud; (1) local→VM; (2) VM→local. Done when local→VM→local preserves a real namespace twice with no re-run cells and the provider bill shows the resumed turns hitting prefix cache.

## Validation Plan

- `just test` plus new coverage: snapshot/restore round-trip on both hosts (dataframes/arrays where available, closures via `cloudpickle`); unpicklables (open file, socket, lock, module, thread) tombstone with repr; host-private names never leak; chunked frames reassemble; packing-turn injects the brief and journals the note; rehydrate script runs once and archives; stale `held` fences expire and recover.
- Context-layout receipt: assert the resumed request's system prompt bytes are identical to the pre-move bytes and that the provider reports a cache hit on the prefix (not just "it worked" — the bill must show it).
- Live receipt: start locally, build real namespace state, hand off mid-session, continue on the VM (assert variable equality, not just conversation continuity); pull home and assert again.
- Adversarial checks: mid-stream handoff waits for the boundary; near-full context compacts before packing; skew stamp refused; legacy source-less run refused as non-resumable; parity-hash mismatch refused before fencing; tunnel death mid-transfer leaves the source authoritative with no duplicate effects on retry; oversized/dirty workspace refused with the status summary; `share show` confirms the Work port never went public.
- Highest-risk validation: **tombstone honesty** — the resumed agent must encounter tombstones as absent names plus its own continuation note, never as plausible-but-stale values; and the abort-under-dead-tunnel path must prove no-two-writers when the fence acknowledgement is what got lost.

## Risks / Rollback

- Sessions heavy on C-extension globals (shared host), huge frames, or unpicklable graphs may be impractical to move — preflight says so before fencing, not after.
- macOS↔Linux asymmetry (paths, Keychain-only creds, Apple-only tooling in agent code) can break the resumed run; preflight probes workspace hash + provider/secret presence on the target first.
- Skew during active Aviary development will refuse handoffs often — intended; ship the runner artifact from the same commit rather than relaxing the gate.
- Rollback is re-admission: abort or `fetch-back` resumes the journal tip wherever authoritative; the other copy becomes a read-only record, never a second writer.

## Open Questions

- VM-side supervision and sleep: what restarts `aviaryd` after a VM reboot (systemd unit?), do idle exe.dev VMs sleep in ways that kill the runner, and what does an idle-but-alive runner cost on the pooled plan?
- SSH trust from a GUI process: key provisioning, known_hosts/TOFU policy, and the launchd-environment path for non-interactive `ssh <vm>.exe.xyz`.
- MCP re-resolution on the target: respawn from the target's `settings.json`, tombstone what doesn't exist there, report it in the outcome table.
- Deferrals: VM reaping policy for idle runners; snapshot payload over rsync vs inside the tunneled protocol stream for very large namespaces.

## Sources

- [What is exe.dev?](https://exe.dev/docs/what-is-exe.md) — subscription VMs with persistent disks; shared CPU/RAM pool.
- [exe.dev `new` command](https://exe.dev/docs/cli-new) — `ssh exe.dev new`, `--cpu/--memory/--disk/--name/--image/--setup-script` options.
- [exe.dev HTTP proxies](https://exe.dev/docs/proxy.md) — private-by-default TLS-terminating proxy; ports 3000–9999 forwarded; `share port`.
- [exe.dev sharing](https://exe.dev/docs/sharing.md) — Web vs Root access; `share add/set-public/set-private/show`.
