#!/usr/bin/env bash
#
# Revoke Murmr Flow's macOS permissions, so you can test the grant flow as a new
# user would see it.
#
# Useful for:
#   - re-running the Phase 0 gate from a clean state
#   - testing the first-run flow later
#
# This does not delete the app or any data — only the permission grants.

set -euo pipefail

BUNDLE_ID="app.murmr.MurmrFlow"
APP_NAME="Murmr Flow"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

bold "Resetting permissions for $BUNDLE_ID"

# Quit first — a running app holding a grant can confuse tccutil.
if pgrep -f "${APP_NAME}.app" >/dev/null 2>&1; then
    printf '  quitting running instance…\n'
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || \
        pkill -f "${APP_NAME}.app" || true
    sleep 1
fi

for service in Microphone Accessibility ListenEvent PostEvent AudioCapture; do
    if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
        printf '  \033[32m✓\033[0m %s\n' "$service"
    else
        # Not every service exists on every macOS version, and a service that was
        # never granted returns non-zero. Neither is an error worth stopping for.
        printf '  \033[90m–\033[0m %s (not set)\n' "$service"
    fi
done

echo
printf 'Relaunch to see the prompts again:\n'
printf '  open "/Applications/%s.app"\n\n' "$APP_NAME"
printf 'Note: macOS sometimes keeps a stale Accessibility entry. If the toggle is\n'
printf 'present but non-functional, remove the app from the list in System Settings\n'
printf 'with the "−" button, then re-add it.\n\n'
