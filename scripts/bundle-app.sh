#!/usr/bin/env bash
# Build Aviary.app from the SwiftPM executable.
#
# There is no Xcode on this machine — only Command Line Tools — so there is no xcodebuild
# and no .xcodeproj. SwiftPM produces a bare Mach-O; a macOS app is that binary plus a
# directory layout and an Info.plist, both of which we can write ourselves. The result is a
# real double-clickable app: it gets a Dock icon, a menu bar, and a bundle identifier that
# UserDefaults and notifications key off.
#
# Usage: scripts/bundle-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/build/Aviary.app"
BIN_NAME="Aviary"
BUNDLE_ID="works.duckbill.aviary"
VERSION="0.1.0"

echo "==> Building ($CONFIG)"
cd "$ROOT/app"
swift build -c "$CONFIG" --product "$BIN_NAME"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
[ -x "$BIN_PATH" ] || { echo "no binary at $BIN_PATH"; exit 1; }

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Aviary</string>
    <key>CFBundleDisplayName</key><string>Aviary</string>
    <key>CFBundleExecutable</key><string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>Aviary</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>Local build</string>
    <!-- The app spawns the harness and reads the agent directory; it is deliberately
         not sandboxed. Sandboxing it would make the entire point impossible. -->
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# An icon, drawn rather than shipped as a binary asset: a filled circle in the accent
# teal with a bird glyph, rendered from the system symbol font at every required size.
if command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/scripts/make-icon.py" "$APP_DIR/Contents/Resources/Aviary.icns" 2>/dev/null \
        || echo "    (icon generation skipped)"
fi

# Signing decides whether your permission grants survive a rebuild, which is not obvious and
# cost a confusing afternoon before it was understood.
#
# Ad-hoc signing produces no certificate, so macOS derives the app's designated requirement
# from the code itself — a literal `cdhash H"..."`. TCC stores that requirement with every
# grant, so a rebuild invalidates Screen Recording and the app asks again, forever. With a
# certificate the requirement is `identifier "..." and certificate leaf = H"..."`, which is
# the same for every build.
#
# `scripts/make-signing-cert.sh` creates the identity. Absent, this still works — it just
# reverts to the re-prompting behaviour, which is a nuisance and not a failure.
SIGN_ID="Aviary Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "==> Signing as '$SIGN_ID'"
    codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP_DIR" >/dev/null 2>&1 \
        || echo "    (signing failed; run scripts/make-signing-cert.sh, or ignore this)"
else
    echo "==> Signing (ad-hoc — permission prompts will return after every build)"
    echo "    Run scripts/make-signing-cert.sh once to stop that."
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR" >/dev/null 2>&1 \
        || echo "    (codesign failed; the app will still run locally)"
fi

# Printed because it is the one line that says whether the fix took. A `cdhash` requirement
# means grants die on the next build; a `certificate leaf` requirement means they survive.
REQ="$(codesign -d -r- "$APP_DIR" 2>&1 | grep "designated =>" || true)"
[ -n "$REQ" ] && echo "    ${REQ#\# }"

SIZE="$(du -sh "$APP_DIR" | cut -f1)"
echo "==> Done: $APP_DIR ($SIZE)"
echo "    open $APP_DIR"
