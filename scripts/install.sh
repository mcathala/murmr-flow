#!/usr/bin/env bash
#
# Install the built app to a stable location and launch it.
#
# Why a stable location matters: TCC associates a permission grant with the code
# signature, the bundle identifier, AND the on-disk path. Running the app from a
# build directory that moves (a git worktree, a renamed folder) makes macOS treat it
# as a different app and re-ask for permissions — which would make the Phase 0 test
# meaningless.
#
# /Applications is where the app lives for real, so test there.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Murmr Flow"
BUNDLE_ID="app.murmr.MurmrFlow"
SRC="build/${APP_NAME}.app"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

[ -d "$SRC" ] || fail "No build found at $SRC — run ./scripts/build.sh first"

# Prefer /Applications; fall back to ~/Applications if it isn't writable, so this
# never needs sudo.
if [ -w /Applications ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/${APP_NAME}.app"

# Quit a running instance, or the copy will replace a bundle that's in use.
if pgrep -f "${APP_NAME}.app" >/dev/null 2>&1; then
    bold "Quitting running instance…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || \
        pkill -f "${APP_NAME}.app" || true
    sleep 1
fi

bold "Installing to $DEST"
rm -rf "$DEST"
# ditto preserves extended attributes and the signature; cp -r can mangle bundles.
ditto "$SRC" "$DEST"

# Sanity: the copy must still validate, otherwise Gatekeeper/TCC will reject it.
codesign --verify --strict "$DEST" || fail "Signature broke during copy"

bold "Launching…"
open "$DEST"

echo
printf 'Look for the waveform icon in the menu bar.\n'
printf 'Verify signing:  ./scripts/verify-signing.sh\n'
