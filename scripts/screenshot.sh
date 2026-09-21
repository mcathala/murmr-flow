#!/usr/bin/env bash
#
# Photograph the app's main window, for the README and the site.
#
#   ./scripts/screenshot.sh home      capture the window as docs/screenshots/home.png
#   ./scripts/screenshot.sh notes     …as notes.png
#   ./scripts/screenshot.sh x --pick  click the window instead of finding it
#   ./scripts/screenshot.sh x --adopt file the shot you just took with ⌘⇧4
#
# The whole run, from nothing to two publishable images:
#
#   ./scripts/demo-data.sh           invented notes and history in place of yours
#   ./scripts/dev.sh                 build, install, launch
#   # open Home, size the window, then:
#   ./scripts/screenshot.sh home
#   # switch to Notetaker, select a note, then:
#   ./scripts/screenshot.sh notes
#   ./scripts/demo-data.sh --restore your own data back
#
# Captured with `-o`, which drops the drop-shadow. A shadow baked into the PNG is the
# wrong shadow on every background but the one it was taken against, and GitHub's dark
# theme is not that background. The rounded corners stay transparent, so the image sits
# on light and dark alike.
#
# **Screen Recording.** Capturing another app's window needs that grant, and macOS gives
# it to the terminal you are in, not to Murmr Flow. Without it `screencapture` fails
# with "could not create image from display" — and an agent or a CI runner cannot grant
# it to itself. That is what `--adopt` is for: take the shot with macOS's own
# screenshotter (⌘⇧4, then Space, then click the window), which always has the right,
# and this files it under the name the README expects.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="docs/screenshots"
# `pgrep` wants the executable; the window server wants the display name. They differ,
# and asking for the wrong one looks exactly like the window being closed.
PROCESS="MurmrFlow"
OWNER="Murmr Flow"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

NAME=""
PICK=0
ADOPT=0
for arg in "$@"; do
    case "$arg" in
        --pick) PICK=1 ;;
        --adopt) ADOPT=1 ;;
        -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
        -*) fail "Unknown option: $arg (try --help)" ;;
        *) NAME="$arg" ;;
    esac
done
[ -n "$NAME" ] || fail "Name the shot: ./scripts/screenshot.sh home"

mkdir -p "$OUT_DIR"
TARGET="$OUT_DIR/${NAME}.png"

if [ "$ADOPT" -eq 1 ]; then
    # Wherever the person has pointed macOS's screenshotter; Desktop unless they moved it.
    SHOT_DIR="$(defaults read com.apple.screencapture location 2>/dev/null || true)"
    SHOT_DIR="${SHOT_DIR:-$HOME/Desktop}"
    SHOT_DIR="${SHOT_DIR/#\~/$HOME}"
    [ -d "$SHOT_DIR" ] || fail "No screenshot folder at $SHOT_DIR"

    # Newest PNG, by modification time. `ls -t` is fine here: these are one person's
    # screenshots, not a directory anyone is racing us to write.
    NEWEST="$(ls -t "$SHOT_DIR"/*.png 2>/dev/null | head -1 || true)"
    [ -n "$NEWEST" ] || fail "No PNG in $SHOT_DIR — take the shot first (⌘⇧4, Space, click)."

    AGE=$(( $(date +%s) - $(stat -f %m "$NEWEST") ))
    if [ "$AGE" -gt 300 ]; then
        bold "Careful: the newest shot is $((AGE / 60)) minutes old."
        printf '  %s\n' "$NEWEST"
        printf 'Adopt it anyway? [y/N] '
        read -r answer
        [ "$answer" = "y" ] || fail "Nothing moved."
    fi

    mv "$NEWEST" "$TARGET"
    bold "Adopted $(basename "$NEWEST")"
elif [ "$PICK" -eq 1 ]; then
    bold "Click the window to capture…"
    screencapture -o -w "$TARGET"
else
    pgrep -x "$PROCESS" >/dev/null 2>&1 || fail "$OWNER is not running. Try ./scripts/dev.sh first."
    WINDOW_ID="$(swift "$ROOT/scripts/window-id.swift" "$OWNER" 2>/dev/null)" \
        || fail "No main window — it is a menu bar app, so open the window first (click the M). Otherwise try --pick."
    bold "Capturing window $WINDOW_ID"
    # A moment for the terminal to stop being the front app, so no focus ring or
    # inactive-window tint lands in the shot.
    open -a "$OWNER" 2>/dev/null || true
    sleep 1
    screencapture -o -x -l "$WINDOW_ID" "$TARGET" \
        || fail "screencapture was refused. Grant Screen Recording to this terminal, or use --adopt."
fi

[ -f "$TARGET" ] || fail "Nothing was captured. Check Screen Recording for your terminal."

SIZE="$(sips -g pixelWidth -g pixelHeight "$TARGET" 2>/dev/null \
    | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w"×"h}')"
printf '  \033[32m✓\033[0m %s (%s)\n' "$TARGET" "$SIZE"
