#!/usr/bin/env bash
#
# Fill the app with believable, invented data — for screenshots and demos.
#
#   ./scripts/demo-data.sh            put the demo data in place
#   ./scripts/demo-data.sh --restore  put your own data back
#
# A screenshot of a real daily driver leaks real meetings; a screenshot of an empty app
# shows nothing worth looking at. This writes a third thing: a folder of notes and a
# dictation log that never happened, in exactly the on-disk formats the app already
# reads — so no code has to know it is being photographed, and the screenshot cannot
# drift away from what the app actually renders.
#
# Your own data is moved aside, never overwritten, and `--restore` moves it back. The
# stash path is recorded in a marker file so restoring cannot guess wrong.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NOTES="$HOME/Documents/MurmurNotes"
SUPPORT="$HOME/Library/Application Support/Murmr Flow"
HISTORY="$SUPPORT/dictations.jsonl"
MARKER="$SUPPORT/.demo-data-stash"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }

MODE=seed
for arg in "$@"; do
    case "$arg" in
        --restore) MODE=restore ;;
        -h|--help) sed -n '3,17p' "$0"; exit 0 ;;
        *) fail "Unknown option: $arg (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
if [ "$MODE" = restore ]; then
    [ -f "$MARKER" ] || fail "No demo data in place — nothing to restore."
    STASH="$(cat "$MARKER")"
    [ -d "$STASH" ] || fail "The stash at $STASH is gone; restore cannot proceed."

    bold "Restoring your own data"
    rm -rf "$NOTES"
    if [ -d "$STASH/MurmurNotes" ]; then
        mv "$STASH/MurmurNotes" "$NOTES"
        ok "notes"
    else
        ok "notes (you had none)"
    fi

    rm -f "$HISTORY"
    if [ -f "$STASH/dictations.jsonl" ]; then
        mv "$STASH/dictations.jsonl" "$HISTORY"
        ok "dictation history"
    else
        ok "dictation history (you had none)"
    fi

    rmdir "$STASH" 2>/dev/null || true
    rm -f "$MARKER"
    echo
    printf 'Restart the app to see your own notes again.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Seed
# ---------------------------------------------------------------------------
[ -f "$MARKER" ] && fail "Demo data is already in place. Run --restore first."

mkdir -p "$SUPPORT"
STASH="$SUPPORT/demo-stash-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STASH"

bold "Moving your own data aside"
if [ -d "$NOTES" ]; then
    mv "$NOTES" "$STASH/MurmurNotes"
    ok "notes → $STASH/MurmurNotes"
else
    ok "notes (you had none)"
fi
if [ -f "$HISTORY" ]; then
    mv "$HISTORY" "$STASH/dictations.jsonl"
    ok "dictation history → $STASH/dictations.jsonl"
else
    ok "dictation history (you had none)"
fi
printf '%s' "$STASH" > "$MARKER"

bold "Writing the demo data"
mkdir -p "$NOTES"
NOTES_DIR="$NOTES" HISTORY_FILE="$HISTORY" python3 "$ROOT/scripts/demo-data.py"

echo
printf 'Launch the app and it reads these as if they were yours.\n'
printf 'Put your own data back with: \033[1m./scripts/demo-data.sh --restore\033[0m\n'
