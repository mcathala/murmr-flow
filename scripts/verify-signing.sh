#!/usr/bin/env bash
#
# Print everything relevant to the Phase 0 gate for the INSTALLED app.
#
# Run it, note the CDHash, rebuild, run it again. The CDHash must change and the
# Team ID must not. If the Team ID is empty, the app is ad-hoc signed and TCC will
# forget your permissions on every build.

set -euo pipefail

APP_NAME="Murmr Flow"
BUNDLE_ID="app.murmr.MurmrFlow"

for candidate in "/Applications/${APP_NAME}.app" \
                 "$HOME/Applications/${APP_NAME}.app" \
                 "build/${APP_NAME}.app"; do
    if [ -d "$candidate" ]; then APP="$candidate"; break; fi
done

if [ -z "${APP:-}" ]; then
    printf '\033[31mNo installed app found. Run ./scripts/build.sh && ./scripts/install.sh\033[0m\n' >&2
    exit 1
fi

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }

printf '\033[1mApp:\033[0m %s\n' "$APP"

INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
field() { printf '%s\n' "$INFO" | awk -F= -v k="$1" '$1==k{print $2; exit}'; }

TEAM="$(field TeamIdentifier)"
IDENT="$(field Identifier)"
AUTH="$(printf '%s\n' "$INFO" | awk -F'=' '/^Authority/{print $2; exit}')"
CDHASH="$(printf '%s\n' "$INFO" | awk -F= '/^CandidateCDHash sha256/{print $2; exit}')"
FLAGS="$(field CodeDirectory | tr ' ' '\n' | grep -i flags || true)"

bold "Signature"
printf '  Identifier   %s\n' "${IDENT:-unknown}"
printf '  Authority    %s\n' "${AUTH:-none (ad-hoc)}"
printf '  Team ID      %s\n' "${TEAM:-<none>}"
printf '  CDHash       %s\n' "${CDHASH:-unknown}"

bold "TCC stability"
if [ -z "${TEAM:-}" ] || [ "${TEAM}" = "not set" ]; then
    printf '  \033[31m✗ Ad-hoc / no Team ID\033[0m\n'
    printf '    macOS identifies this app by its CDHash, which changes every build.\n'
    printf '    Permissions WILL reset. Run ./scripts/make-cert.sh\n'
else
    printf '  \033[32m✓ Stable\033[0m — Team %s\n' "$TEAM"
    printf '    CDHash changes each build; the Team ID does not, so grants survive.\n'
fi

bold "Hardened Runtime"
if printf '%s\n' "$INFO" | grep -q 'flags=.*runtime'; then
    printf '  \033[32m✓ enabled\033[0m\n'
else
    printf '  \033[33m! not detected\033[0m — required before notarization\n'
fi

bold "Entitlements"
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | plutil -convert xml1 -o - - 2>/dev/null \
    | grep -E '<key>|<true|<false' | sed 's/^/  /' || printf '  none\n'

if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'app-sandbox'; then
    printf '  \033[31m✗ App Sandbox present — this breaks the Accessibility API\033[0m\n'
else
    printf '  \033[32m✓ App Sandbox absent (required — sandbox blocks Accessibility)\033[0m\n'
fi

bold "Current TCC grants"
printf '  Accessibility  '
if sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
     "select 1 from access where service='kTCCServiceAccessibility' and client='$BUNDLE_ID' and auth_value=2" \
     2>/dev/null | grep -q 1; then
    printf '\033[32mgranted\033[0m\n'
else
    # The user TCC.db is usually unreadable without Full Disk Access; that's normal.
    printf 'unknown (TCC.db not readable — check the app panel instead)\n'
fi

bold "Gate"
printf '  1. Grant both permissions in the app panel\n'
printf '  2. ./scripts/build.sh && ./scripts/install.sh\n'
printf '  3. Re-run this script: CDHash changed, Team ID identical\n'
printf '  4. Both permissions still granted  →  Phase 0 passes\n\n'
