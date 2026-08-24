# Working in Aviary

A native macOS app plus a hard fork of the Prime Agent harness. Read `README.md` first for
what it does; this file is how to work on it without relearning the traps.

## Layout

| Path | What it is |
|---|---|
| `app/Sources/AviaryCore/` | Pure Swift, no SwiftUI. Everything that reads or writes harness state. Testable, and where new behaviour should land by default. |
| `app/Sources/Aviary/` | SwiftUI. Views, the app model, the design system, the headless snapshot renderer. |
| `app/Sources/AviarySelfTest/` | The test suite, as an executable. |
| `harness/` | The forked engine. See `harness/FORK.md`. |
| `scripts/` | `bundle-app.sh` assembles the `.app`; `make-icon.py` draws the icon. |

## Ground rules

- **New logic goes in `AviaryCore`.** If a view needs to parse, scan, resolve, or diagnose
  something, that belongs in the core with a test. Views should read prepared data.
- **Parse defensively, always.** The session format is versioned, extension-extensible, and
  changes between harness releases. Everything is decoded through `JSONValue` with
  forgiving accessors: an unknown field is invisible, never fatal. `Transcript.unparsedLines`
  is surfaced in the UI precisely so a format drift shows up instead of silently truncating.
- **Never put a credential on screen.** `auth.json` is read for provider names and auth
  kinds only. A resolved key appears as a masked prefix and a length, never a value.
- **Never unlink a transcript.** Deletion goes to the Trash. It is the only record of work
  an agent did.
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
- **A wedged daemon still answers `doctor`.** It completes the handshake and reports
  `status: current` while refusing every real command. `DaemonInspector` cross-checks with a
  `list` call, which goes through the ownership assertion. `doctor --fix` deliberately skips
  this case; only `shutdown --force` clears it.
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
  `codesign -d -r- build/Aviary.app` — a `certificate leaf` requirement survives rebuilds, a
  `cdhash` one does not.
- **A comment-only Swift change produces a byte-identical binary.** llbuild recompiles the
  file, sees the same object, and skips the relink — so the executable keeps its mtime. Any
  test of "did a rebuild happen?" must change emitted code, not a comment. This cost two
  rounds of wrong diagnosis while building the workshop reload.
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
