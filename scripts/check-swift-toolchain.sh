#!/bin/zsh

# Purpose: fail before SwiftPM with a concise diagnosis when the active compiler and SDK were
# installed from different Apple toolchain releases.
# Usage: scripts/check-swift-toolchain.sh
# Last verified: 2026-08-31

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
module_cache="$repo_root/app/.build/module-cache"
mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFT_MODULECACHE_PATH="$module_cache"

compiler_line="$(swiftc --version 2>&1 | head -n 1)"
compiler_version="$(print -r -- "$compiler_line" | sed -nE 's/.*Apple Swift version ([^ ]+).*/\1/p')"
sdk_root="$(xcrun --show-sdk-path)"
sdk_interface="$(find "$sdk_root/usr/lib/swift/Swift.swiftmodule" -name '*.swiftinterface' -print | head -n 1)"

if [[ -z "$compiler_version" || -z "$sdk_interface" ]]; then
    print -u2 -- "Could not determine the active Swift compiler and SDK versions."
    print -u2 -- "Compiler: $compiler_line"
    print -u2 -- "SDK: $sdk_root"
    exit 2
fi

sdk_version="$(sed -nE 's|// swift-compiler-version: Apple Swift version ([^ ]+).*|\1|p' "$sdk_interface" | head -n 1)"
if [[ -z "$sdk_version" ]]; then
    print -u2 -- "Could not read the SDK compiler version from $sdk_interface."
    exit 2
fi

compiler_line_major_minor="${compiler_version%.*}"
sdk_line_major_minor="${sdk_version%.*}"

# Apple can ship a patch-level compiler update with an SDK whose stable Swift interfaces were
# emitted by the preceding patch. Command Line Tools 26.6 does exactly that (6.3.3 compiler,
# 6.3.2 SDK), and the compiler accepts those interfaces. Prove compatibility instead of rejecting
# a supported Apple bundle from version-string equality alone.
diagnostics="$(mktemp)"
trap 'rm -f "$diagnostics"' EXIT
if ! print -r -- 'import Foundation' \
    | swiftc -typecheck -sdk "$sdk_root" - 2>"$diagnostics"; then
    print -u2 -- "Aviary cannot build with the active Swift toolchain:"
    print -u2 -- "  compiler: Apple Swift $compiler_version"
    print -u2 -- "  SDK:      Apple Swift $sdk_version ($sdk_root)"
    sed 's/^/  /' "$diagnostics" >&2
    print -u2 -- "Select or install a Command Line Tools/Xcode release with a compatible SDK."
    exit 2
fi

if [[ "$compiler_line_major_minor" == "$sdk_line_major_minor" ]]; then
    print -- "Swift toolchain OK: compiler $compiler_version accepts SDK $sdk_version"
else
    print -- "Swift toolchain smoke check passed: compiler $compiler_version accepts SDK $sdk_version"
fi
