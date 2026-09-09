#!/usr/bin/env bash
#
# Rebuild, install, relaunch — the developer's loop, in two modes.
#
#   ./scripts/dev.sh              keep my state: rebuild and reopen where I left off
#   ./scripts/dev.sh --fresh      as a new user: permissions, defaults and keys cleared,
#                                 onboarding from the first page
#   ./scripts/dev.sh --fresh --wipe-data
#                                 …and the notes and dictation history too (asks first)
#
# Always installs to /Applications rather than running from build/. TCC ties a permission
# grant to the signature *and* the on-disk path, so an app launched from a build folder in
# a git worktree is a different app to macOS every time the folder moves. One path, one
# identity.
#
# The identity is the other half. Without a certificate every build is ad-hoc signed, its
# hash changes, and macOS forgets every grant on every rebuild — which is why the plain
# mode warns until `./scripts/make-cert.sh` has been run once.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Murmr Flow"
EXEC_NAME="MurmrFlow"
BUNDLE_ID="app.murmr.MurmrFlow"
SRC="build/${APP_NAME}.app"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

FRESH=0
WIPE=0
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=1 ;;
        --wipe-data) WIPE=1 ;;
        -h|--help) sed -n '3,17p' "$0"; exit 0 ;;
        *) fail "Unknown option: $arg (try --help)" ;;
    esac
done
if [ "$WIPE" -eq 1 ] && [ "$FRESH" -eq 0 ]; then
    fail "--wipe-data only makes sense with --fresh"
fi

# ---------------------------------------------------------------------------
# Signing
# ---------------------------------------------------------------------------
if ! security find-identity -v -p codesigning 2>/dev/null \
        | grep -qE 'Developer ID Application|Apple Development|MurmrDev'; then
    warn "No code-signing certificate on this Mac, so this build is ad-hoc signed."
    warn "macOS will forget Accessibility and the microphone on every rebuild, and the"
    warn "Accessibility list will keep a dead row for each build. Fix it once:"
    warn "    ./scripts/make-cert.sh"
    echo
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
./scripts/build.sh

# ---------------------------------------------------------------------------
# Quit every running copy, whichever folder it was launched from
# ---------------------------------------------------------------------------
if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
    bold "Quitting running instance(s)…"
    pkill -x "$EXEC_NAME" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$EXEC_NAME" >/dev/null 2>&1 || break
        sleep 0.3
    done
fi

# ---------------------------------------------------------------------------
# Install to a stable path
# ---------------------------------------------------------------------------
if [ -w /Applications ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/${APP_NAME}.app"

bold "Installing to $DEST"
rm -rf "$DEST"
# ditto preserves extended attributes and the signature; cp -r can mangle bundles.
ditto "$SRC" "$DEST"
codesign --verify --strict "$DEST" || fail "Signature broke during copy"

# ---------------------------------------------------------------------------
# Fresh: the machine has never seen the app
# ---------------------------------------------------------------------------
if [ "$FRESH" -eq 1 ]; then
    bold "Resetting permissions for $BUNDLE_ID"
    # Every service the app ever asks for. A service that was never granted says no,
    # which is not an error worth stopping for. ScreenCapture is where the system-audio
    # grant lives; AudioCapture is kept for the macOS versions that filed it there.
    for service in Microphone Accessibility ListenEvent PostEvent AudioCapture ScreenCapture; do
        if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
            printf '  \033[32m✓\033[0m %s\n' "$service"
        else
            printf '  \033[90m–\033[0m %s (was not set)\n' "$service"
        fi
    done

    if [ "$WIPE" -eq 1 ]; then
        NOTES="$HOME/Documents/MurmurNotes"
        HISTORY="$HOME/Library/Application Support/Murmr Flow/dictations.jsonl"
        echo
        warn "About to delete your notes and dictation history:"
        [ -d "$NOTES" ] && warn "  $NOTES ($(ls "$NOTES"/*.md 2>/dev/null | wc -l | tr -d ' ') notes)"
        [ -f "$HISTORY" ] && warn "  $HISTORY"
        read -r -p "Type yes to continue: " answer
        [ "$answer" = "yes" ] || fail "Kept. Nothing deleted."
        rm -rf "$NOTES"
        rm -f "$HISTORY"
        printf '  \033[32m✓\033[0m notes and history removed\n'
    fi

    # Defaults and Keychain keys are the app's own to clear: it does so on this flag,
    # before any store reads them — see `FreshStart`.
    bold "Launching as a new user…"
    open "$DEST" --args --fresh
else
    bold "Launching…"
    open "$DEST"
fi

echo
printf 'Look for the M in the menu bar.\n'
