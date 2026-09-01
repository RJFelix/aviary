#!/usr/bin/env bash
# Rebuild and reopen one screen whenever a source file changes.
#
# WHY THIS AND NOT CODE INJECTION
#
# Real injection (InjectionIII, and the `Inject`/`HotReloading` packages that wrap it) requires
# full Xcode at /Applications/Xcode.app plus an Xcode build setting. This project has Command
# Line Tools only and no .xcodeproj — that is deliberate, and everything else here is built
# around it. So this replaces the process instead of patching it, and buys back the time
# elsewhere: `--preview` skips the ~7.5s of startup work a UI edit does not need, leaving the
# incremental build as almost the whole cost.
#
# Usage: scripts/watch.sh [section]     e.g. scripts/watch.sh cockpit
set -uo pipefail

SECTION="${1:-cockpit}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/app/.build/debug/Aviary"
PID=""
MODULE_CACHE="$ROOT/app/.build/module-cache"

"$ROOT/scripts/check-swift-toolchain.sh" || exit $?
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"

# Polling rather than fswatch or entr: neither is installed here, and adding a Homebrew
# dependency to a loop whose whole point is convenience is a poor trade. `find -newer` against a
# stamp file is a couple of milliseconds over this tree.
STAMP="$(mktemp)"
trap 'rm -f "$STAMP"; [ -n "$PID" ] && kill "$PID" 2>/dev/null; exit 0' EXIT INT TERM

changed() {
    # Swift sources only. The shots directory and build outputs live under the tree too, and
    # watching those would make every rebuild trigger the next one.
    [ -n "$(find "$ROOT/app/Sources" -name '*.swift' -newer "$STAMP" -print -quit 2>/dev/null)" ]
}

rebuild_and_open() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    PID=""
    printf '\033[2m—— building ——\033[0m\n'
    local started=$SECONDS
    local log
    log="$(mktemp)"
    # Once, capturing everything. Building twice — once for diagnostics, once for the exit
    # code — is how a two-second loop becomes a four-second one.
    if ! ( cd "$ROOT/app" && swift build --product Aviary ) >"$log" 2>&1; then
        printf '\033[31m—— build failed, keeping the last window ——\033[0m\n'
        grep -E "error:" "$log" | grep -v "^ *|" | sort -u | head -6
        rm -f "$log"
        return 1
    fi
    rm -f "$log"
    printf '\033[2m—— built in %ss, opening %s ——\033[0m\n' "$((SECONDS - started))" "$SECTION"
    "$BIN" --preview "$SECTION" >/dev/null 2>&1 &
    PID=$!
}

echo "watching $ROOT/app/Sources for changes · previewing '$SECTION' · ctrl-c to stop"
rebuild_and_open
while true; do
    if changed; then
        touch "$STAMP"
        # Debounced: an editor writing several files in quick succession should cause one
        # rebuild, not one per file.
        sleep 0.4
        while changed; do touch "$STAMP"; sleep 0.4; done
        rebuild_and_open
    fi
    sleep 0.5
done
