# Working in Aviary

A native macOS app plus its cross-platform Work Host and runtime. Read `README.md` first for
what it does; this file is how to work on it without relearning the traps.

## Layout

| Path | What it is |
|---|---|
| `app/Sources/AviaryCore/` | Pure Swift, no SwiftUI. Everything that reads or writes agent state. Testable, and where new behaviour should land by default. |
| `app/Sources/Aviary/` | SwiftUI. Views, the app model, the design system, the headless snapshot renderer. |
| `app/Sources/AviarySelfTest/` | The test suite, as an executable. |
| `app/Sources/aviaryd/` | The headless Work Host process. It owns in-house runs independently of any GUI. |
| `runtime-hosts/` | The Python runtime-host processes used by in-house Work. |
| `scripts/` | `bundle-app.sh` assembles the `.app`; `make-icon.py` draws the icon. |

## Ground rules

- **New logic goes in `AviaryCore`.** If a view needs to parse, scan, resolve, or diagnose
  something, that belongs in the core with a test. Views should read prepared data.
- **Parse defensively, always.** Session formats are versioned, extension-extensible, and include
  externally owned Claude Code records. Everything is decoded through `JSONValue` with
  forgiving accessors: an unknown field is invisible, never fatal. `Transcript.unparsedLines`
  is surfaced in the UI precisely so a format drift shows up instead of silently truncating.
- **Never put a credential on screen.** `auth.json` is read for provider names and auth
  kinds only. A resolved key appears as a masked prefix and a length, never a value.
- **Data ownership decides preservation, not age.** Aviary-owned transcripts, artifacts, caches,
  fixtures, and schemas are disposable development state: migrate, rewrite, regenerate, or remove
  them instead of adding permanent compatibility interfaces. Claude Code- and Codex-owned stores
  are valuable and read-only. If Aviary needs their content, copy it into Aviary-owned space with
  source provenance, then transform only the copy. Treat ambiguous ownership as external/read-only.
- **Back up before writing config.** `models.json` gets a timestamped copy on every write,
  and edits round-trip through the original bytes so unknown fields survive.
- **Split records on `\n` only.** Not on Unicode line separators. `U+2028`/`U+2029` are legal
  inside JSON strings and do occur in agent output; a generic line reader corrupts records.
  There is a test for this.

## Traps that cost real time

- **A GUI app's environment is launchd's, not your shell's.** Anything spawning a
  subprocess must use `ProcessEnvironment.shared.snapshot`, which holds the login shell's
  environment captured at startup. Bypass it and environment-variable credentials resolve to
  their own names and 401 — a failure that reads like a config typo. `Shell.run` uses it by
  default; keep it that way.
- **`pgrep -fl`, never `ps aux | grep`.** The latter has been observed returning nothing
  while four engine processes were running.
- **A socket or PID is not Work Host health.** `aviaryd` may accept a connection while its
  journal-backed service cannot serve canonical Work. Verify an accepted identity-fenced
  handshake and a real bounded service read; transport reachability is not execution recovery.
- **A blank snapshot is a capture-path bug before it is a view bug.** Captures go through
  ScreenCaptureKit because `cacheDisplay` only sees NSView drawing, and most SwiftUI
  content — every chart, every material — is layer-only. A screen that looks fine in the
  app and blank in a shot is almost never the screen. Confirm the Screen Recording grant
  first; a refused grant silently drops to the `cacheDisplay` fallback.
- **Anything perpetually animated must check `\.staticRendering`.** A `repeatForever`
  animation or an endless `.task` loop is fine on screen and a problem for the snapshot
  renderer. `PulseDot` and `StreamingIndicator` are the existing examples.
- **The catalog cache keys on file size and mtime**, so it detects a changed transcript and
  completely misses a changed parser. Bump `SessionCatalog.schemaVersion` when you change
  how a summary is derived, or your improvement silently does nothing for every session
  already indexed.
- **`input_tokens` from Anthropic excludes cached context.** A cached turn reads
  `input 2, cacheRead 3953`, so summing input and output undercounts a long session by a
  factor of fifty. `ClaudeCode.usage` is cache-inclusive; `AnthropicMessagesProvider` is not,
  and that is a known bug rather than a convention worth copying.
- **Anything that spawns `claude` must scrub the environment first.** `ANTHROPIC_API_KEY` and
  friends outrank subscription OAuth silently, so the run works and bills metered credit —
  a failure with no symptom. And Aviary is developed from inside Claude Code, so a child
  inherits `CLAUDE_CODE_SESSION_ID` and the parent's messaging socket unless you strip them.
  Use `ClaudeCode.scrubbedEnvironment`, and check `apiKeySource: "none"` in the init frame.
- **Never resolve `claude` off `PATH` alone.** A terminal multiplexer or IDE integration
  commonly puts a shim there under `/var/folders/…/T/`, scoped to the session that made it.
  `ClaudeCode.locate` checks real install paths first and filters temp-dir shims.
- **Ad-hoc signing makes every rebuild a different app to macOS.** With no certificate there
  is nothing stable to identify the app by, so its designated requirement becomes a literal
  `cdhash H"..."` of that build — and TCC stores that requirement with every permission you
  grant. Rebuild and Screen Recording is asked for again, while System Settings still shows the
  app switched on, because the row is keyed by bundle id and the grant behind it is bound to a
  build that no longer exists. `scripts/make-signing-cert.sh` fixes it once; check with
  `codesign -d -r- build/Aviary.app` — a `certificate root` requirement survives rebuilds, a
  `cdhash` one does not.
- **A signing identity can be valid and still unusable.** Authorising codesign to use the key
  is a separate thing. Without it `codesign` does not error, it blocks on a GUI dialog — and an
  unattended build hangs, leaving a `.cstemp` in the bundle that makes later signing fail with
  "invalid or unsupported format for signature", which looks like bundle corruption and is not.
  Answer one dialog with **Always Allow** ("Allow" fixes nothing), and never send `codesign`
  output to /dev/null. A correctly authorised key signs in ~250ms, so anything slower than a
  second is a dialog you cannot see.
- **`claude` ignores SIGTERM.** `Process.terminate()` will not end it; escalate to SIGKILL and
  verify, or you leave an orphan reparented to launchd still holding its MCP courier. Same for
  any child that might outlive a run — check with `ps -o ppid=`, and treat PPID 1 as a leak.
- **Never switch over a provider's `api` in two places.** `AgentCLI` and `InHouseDriver` did,
  only one had the Codex case, and the GUI silently 404'd against
  `chatgpt.com/backend-api/chat/completions` for months. Route through
  `ChatProviderRouting.makeProvider`. The rule generalises: the path exercised less is the one
  that breaks.
- **A comment-only Swift change produces a byte-identical binary.** llbuild recompiles the
  file, sees the same object, and skips the relink — so the executable keeps its mtime. Any
  test of "did a rebuild happen?" must change emitted code, not a comment. This cost two
  rounds of wrong diagnosis while building the workshop reload.
- **The data directory is `~/.aviary`**, flat — sessions, session-artifacts, rlm-ledger,
  settings.json, models.json, auth.json. It was `~/.prime/agent` until 2026-08-25. The move was
  a **copy**: `~/.prime` is still there and untouched, and the harness's own directories
  (`kernel-venv` at 297MB, `daemon-workers`, `session-leases`, `bin`, `logs`) were deliberately
  not carried across because nothing reads them. A test asserts they stay absent.
- **There is no inherited harness.** Aviary ran on a vendored Prime Agent fork until 2026-08-24.
  The fork, `RPCClient`, old `Daemon`, supervisor surfaces, and `harness/` checkout are gone;
  references to those are stale. The current `aviaryd` is Aviary's own Work Host and is not that
  retired daemon: it owns journal-backed Work so GUI loss does not imply termination.
- **There are three Aviary binaries, and only one of them is the app.** `swift build` makes
  `app/.build/debug/Aviary`, `just shot` renders from `app/.build/release/Aviary`, and the
  thing double-clicked is `build/Aviary.app`, produced by `just build`. Verifying a UI change
  with the first two proves nothing about the third. This cost three rounds of fixes to one
  menu, all judged against a bundle four hours older than the code that fixed it — and because
  a missing rebuild is indistinguishable from a failed fix, the evidence pointed at the
  diagnosis instead of the build. **Run `just build` before asking anyone to look at a UI
  change.** The sidebar footer now shows an amber "N behind" chip when the checkout has moved
  past the running bundle; if you see it in a screenshot, that is the first thing to fix.
- **The app declares its own `Section`.** `AppModel.swift` defines `enum Section` for
  navigation, which shadows SwiftUI's `Section` inside the `Aviary` target. An unqualified
  `Section { … }` in a `List` resolves to the enum and produces four rounds of unrelated
  type-inference errors ("missing argument for parameter 'rawValue'", "Section conform to
  CodingKeyRepresentable") that name everything except the actual cause. Write
  `SwiftUI.Section`.
- **Swift 5 language mode is deliberate** (`swiftSettings: [.swiftLanguageMode(.v5)]`).
  Strict concurrency checking on AppKit-adjacent code buys errors, not safety, at this stage.

## Verifying a change

```sh
just test     # core suite
just compile  # both targets build
just shots    # every screen renders, against your real agent directory
```

Both non-harness engines have a terminal entry point, and using them is how you verify a
change without clicking: `Aviary --agent "<prompt>"` for the in-house engine, and
`Aviary --claude-code "<prompt>"` for a driven one. The driven path shares
`ClaudeCodeSession.prepare` with the GUI, so the CLI genuinely exercises what a window does.
`AVIARY_CLAUDE_RAW=<file>` dumps every stream-json frame, which is the only way to settle a
question about that stream's shape — inference about it has been wrong twice.

Look at the PNGs. `just shots` prints what it indexed — session count, sub-agent count,
reachable models, daemon health — so a change that quietly breaks data loading shows up in
that line before you open an image.

## Reflection

This repo sits under the Duckbill superrepo (`~/duckbill`), whose rules apply: log dev-env
friction to `~/duckbill/FRICTION.md`, receipts to `~/duckbill/LEDGER.md`, durable findings
about tools to `~/duckbill/knowledge/`.
