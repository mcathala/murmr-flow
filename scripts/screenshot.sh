#!/usr/bin/env bash
#
# Photograph the app's main window, for the README and the site.
#
#   ./scripts/screenshot.sh home     capture the window as docs/screenshots/home.png
#   ./scripts/screenshot.sh notes    …as notes.png
#   ./scripts/screenshot.sh x --pick click the window instead of finding it
#
# The whole run, from nothing to two publishable images:
#
#   ./scripts/demo-data.sh           invented notes and history in place of yours
#   ./scripts/dev.sh                 build, install, launch
#   # open Home, size the window, then:
#   ./scripts/screenshot.sh home
#   # switch to Notes, select a note, then:
#   ./scripts/screenshot.sh notes
#   ./scripts/demo-data.sh --restore your own data back
#
# Captured with `-o`, which drops the drop-shadow. A shadow baked into the PNG is the
# wrong shadow on every background but the one it was taken against, and GitHub's dark
# theme is not that background. The rounded corners stay transparent, so the image sits
# on light and dark alike.
#
# The first run asks for Screen Recording for whichever terminal you are in — that is
# macOS's rule for capturing another app's window, and it is granted to the terminal,
# not to Murmr Flow.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="docs/screenshots"
OWNER="MurmrFlow"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

NAME=""
PICK=0
for arg in "$@"; do
    case "$arg" in
        --pick) PICK=1 ;;
        -h|--help) sed -n '3,27p' "$0"; exit 0 ;;
        -*) fail "Unknown option: $arg (try --help)" ;;
        *) NAME="$arg" ;;
    esac
done
[ -n "$NAME" ] || fail "Name the shot: ./scripts/screenshot.sh home"

mkdir -p "$OUT_DIR"
TARGET="$OUT_DIR/${NAME}.png"

if [ "$PICK" -eq 1 ]; then
    bold "Click the window to capture…"
    screencapture -o -w "$TARGET"
else
    pgrep -x "$OWNER" >/dev/null 2>&1 || fail "$OWNER is not running. Try ./scripts/dev.sh first."
    WINDOW_ID="$(swift "$ROOT/scripts/window-id.swift" "$OWNER" 2>/dev/null)" \
        || fail "Could not find the main window. Is it open? Otherwise try --pick."
    bold "Capturing window $WINDOW_ID"
    # A moment for the terminal to stop being the front app, so no focus ring or
    # inactive-window tint lands in the shot.
    open -a "Murmr Flow" 2>/dev/null || true
    sleep 1
    screencapture -o -x -l "$WINDOW_ID" "$TARGET"
fi

[ -f "$TARGET" ] || fail "Nothing was captured. Check Screen Recording for your terminal."

SIZE="$(sips -g pixelWidth -g pixelHeight "$TARGET" 2>/dev/null \
    | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w"×"h}')"
printf '  \033[32m✓\033[0m %s (%s)\n' "$TARGET" "$SIZE"
