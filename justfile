# Aviary tasks. `just --list` for the menu.

app_dir := justfile_directory() / "app"
build_dir := justfile_directory() / "build"
module_cache := app_dir / ".build" / "module-cache"

[private]
default:
    @just --list

# Build Aviary.app (release)
build:
    ./scripts/bundle-app.sh release

# Rebuild and reopen one screen on every save. `just watch cockpit`
# Uses --preview, which skips the ~7.5s of startup a UI edit does not need.
watch section="cockpit":
    ./scripts/watch.sh {{section}}

# Open one screen once, without the startup work. `just preview models`
preview section="cockpit":
    ./scripts/check-swift-toolchain.sh
    cd {{app_dir}} && env CLANG_MODULE_CACHE_PATH={{module_cache}} SWIFT_MODULECACHE_PATH={{module_cache}} swift build --product Aviary
    "{{app_dir}}/.build/debug/Aviary" --preview {{section}}

# Create the stable code-signing identity, so permission grants survive a rebuild.
# Run once. Asks for your login password; see the script's header for what it changes.
signing-cert:
    ./scripts/make-signing-cert.sh

# Build and launch
run: build
    open {{build_dir}}/Aviary.app

# Build the app binary only, no bundle (fast inner loop)
compile:
    ./scripts/check-swift-toolchain.sh
    cd {{app_dir}} && env CLANG_MODULE_CACHE_PATH={{module_cache}} SWIFT_MODULECACHE_PATH={{module_cache}} swift build --product Aviary

# Run the core test suite. Not `swift test`: a Command Line Tools toolchain ships no
# XCTest, so the suite is an executable. See app/Sources/AviarySelfTest/Harness.swift.
test:
    ./scripts/check-swift-toolchain.sh
    cd {{app_dir}} && env CLANG_MODULE_CACHE_PATH={{module_cache}} SWIFT_MODULECACHE_PATH={{module_cache}} swift run AviarySelfTest

# Reproduce the versioned 100,000-event Timeline v2 scale baseline.
timeline-benchmark:
    ./scripts/check-swift-toolchain.sh
    cd {{app_dir}} && env CLANG_MODULE_CACHE_PATH={{module_cache}} SWIFT_MODULECACHE_PATH={{module_cache}} AVIARY_SELFTEST_FILTER="Timeline v2 100k baseline" swift run AviarySelfTest

# Render every screen to build/shots/ without a display server
shots:
    ./scripts/check-swift-toolchain.sh
    cd {{app_dir}} && env CLANG_MODULE_CACHE_PATH={{module_cache}} SWIFT_MODULECACHE_PATH={{module_cache}} swift build -c release --product Aviary
    mkdir -p {{build_dir}}/shots
    "{{app_dir}}/.build/release/Aviary" --snapshot {{build_dir}}/shots --width 1600 --height 1000
    @echo "→ {{build_dir}}/shots"

# Render one screen. `just shot sessions` or `just shot cockpit --bare`
shot section *FLAGS:
    ./scripts/check-swift-toolchain.sh
    cd {{app_dir}} && env CLANG_MODULE_CACHE_PATH={{module_cache}} SWIFT_MODULECACHE_PATH={{module_cache}} swift build -c release --product Aviary
    mkdir -p {{build_dir}}/shots
    "{{app_dir}}/.build/release/Aviary" --snapshot {{build_dir}}/shots --only {{section}} --width 1600 --height 1000 {{FLAGS}}

# One driven Claude Code session in a terminal. `just drive "count the swift files"`
# Shares ClaudeCodeSession.prepare with the GUI, so this exercises the same path a window does.
drive prompt *FLAGS:
    ./scripts/check-swift-toolchain.sh
    cd {{app_dir}} && env CLANG_MODULE_CACHE_PATH={{module_cache}} SWIFT_MODULECACHE_PATH={{module_cache}} swift build --product Aviary
    "{{app_dir}}/.build/debug/Aviary" --claude-code {{quote(prompt)}} {{FLAGS}}


# Regenerate the app icon from scripts/make-icon.py
icon:
    python3 scripts/make-icon.py {{build_dir}}/Aviary.icns
    @echo "→ {{build_dir}}/Aviary.icns"

# Everything CI would check
check: test compile
    @echo "ok"

# Remove build output
clean:
    rm -rf {{build_dir}} {{app_dir}}/.build

# Drive a runtime host by hand. `just host` for the default, `just host python3-shared`.
#
# Reads JSON lines from your terminal and prints the host's replies, which is the fastest way
# to explore a runtime or to check a new host against docs/runtime-host-protocol.md. Try:
#   {"id":"1","op":"session.create","session":"s"}
#   {"id":"2","op":"exec","session":"s","code":"sh('git log --oneline -3')['stdout']"}
#   {"id":"3","op":"inspect","session":"s"}
host variant="python3":
    @echo '→ runtime-hosts/{{variant}}/host.py — one JSON object per line, ^D to finish'
    python3 runtime-hosts/{{variant}}/host.py

# Compare every bundled host against the same protocol checks
hosts:
    ./scripts/check-swift-toolchain.sh
    cd {{app_dir}} && env CLANG_MODULE_CACHE_PATH={{module_cache}} SWIFT_MODULECACHE_PATH={{module_cache}} swift run AviarySelfTest 2>&1 | grep -E "runtimeHost|cases,"
