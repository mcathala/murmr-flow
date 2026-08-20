#!/usr/bin/env bash
#
# Build Murmr Flow into a signed .app bundle.
#
#   ./scripts/build.sh                 debug, arm64, auto-detected identity
#   CONFIG=release ./scripts/build.sh  release build
#   UNIVERSAL=1 ./scripts/build.sh     universal binary (arm64 + x86_64)
#   SIGNING_IDENTITY="..." ./scripts/build.sh
#
# The signing identity is a VARIABLE on purpose. Switching from local development to
# a notarized release is then a one-line change rather than a refactor:
#
#   SIGNING_IDENTITY="Developer ID Application: … (TEAMID)" CONFIG=release \
#       ./scripts/build.sh
#   xcrun notarytool submit … && xcrun stapler staple "build/Murmr Flow.app"
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Murmr Flow"
EXEC_NAME="MurmrFlow"
CONFIG="${CONFIG:-debug}"
VERSION="${VERSION:-0.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/${APP_NAME}.app"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pick a signing identity
# ---------------------------------------------------------------------------
# Preference order, best first. Anything with a Team ID keeps TCC permissions
# stable across rebuilds; ad-hoc does not.
detect_identity() {
    local ids pattern match
    ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for pattern in "Developer ID Application" "Apple Development" "MurmrDev"; do
        match="$(printf '%s\n' "$ids" | grep -F "$pattern" | head -1 \
                 | sed -E 's/.*"(.*)".*/\1/')"
        if [ -n "$match" ]; then printf '%s' "$match"; return 0; fi
    done
    printf '%s' "-"   # ad-hoc
}

SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(detect_identity)}"

if [ "$SIGNING_IDENTITY" = "-" ]; then
    warn "No code signing certificate found — falling back to ad-hoc signing."
    warn "TCC will identify the app by its CDHash, which changes on EVERY build, so"
    warn "microphone and accessibility grants will reset each time you rebuild."
    warn "Fix it once:  ./scripts/make-cert.sh"
    echo
fi

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------
bold "Building ($CONFIG)…"

ARCH_FLAGS=(--arch arm64)
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/$EXEC_NAME"
[ -f "$BIN" ] || fail "Expected binary not found at $BIN"

# ---------------------------------------------------------------------------
# Assemble the .app bundle
# ---------------------------------------------------------------------------
bold "Assembling ${APP}…"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"

sed -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|$BUILD_NUMBER|g" \
    resources/info.plist > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# Vendored mediaremote-adapter
# ---------------------------------------------------------------------------
# Built by its own script, which caches on a source hash — see that script and
# resources/mediaremote-adapter/VENDORED.md.
./scripts/build-adapter.sh

ADAPTER_FW="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
mkdir -p "$APP/Contents/Frameworks"
# ditto rather than cp -R: it preserves the framework's symlinks correctly.
ditto ".build/adapter/MediaRemoteAdapter.framework" "$ADAPTER_FW"

# perl loads the dylib; the script is what we actually invoke.
cp "resources/mediaremote-adapter/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
# BSD-3 requires the licence to travel with the binary.
cp "resources/mediaremote-adapter/LICENSE" \
   "$APP/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"

# Apache-2.0 requires a copy of the licence in the distribution. SwiftPM does not bundle
# dependency licences, so it has to be done here.
FLUIDAUDIO_LICENSE=".build/checkouts/FluidAudio/LICENSE"
if [ -f "$FLUIDAUDIO_LICENSE" ]; then
    cp "$FLUIDAUDIO_LICENSE" "$APP/Contents/Resources/FluidAudio-LICENSE.txt"
else
    warn "FluidAudio LICENSE not found — the app will ship without it (Apache-2.0 requires it)"
fi

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------
bold "Signing with: $SIGNING_IDENTITY"

# --options runtime enables the Hardened Runtime. It's required for notarization
# later and harmless now, so we always build with it rather than discovering
# hardened-runtime problems at release time.
CODESIGN_FLAGS=(
    --force
    --options runtime
    --entitlements resources/murmr-flow.entitlements
    --sign "$SIGNING_IDENTITY"
)

# A secure timestamp needs network access and is only required for notarization.
if [ "$CONFIG" != "release" ]; then
    CODESIGN_FLAGS+=(--timestamp=none)
fi

# Nested code must be signed before the enclosing bundle, or the outer signature
# covers an unsigned binary and verification fails.
codesign "${CODESIGN_FLAGS[@]}" "$ADAPTER_FW" \
    || fail "Failed to sign MediaRemoteAdapter"

codesign "${CODESIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --deep "$APP" || fail "Signature verification failed"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo
bold "Built $APP"

TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^TeamIdentifier/{print $2}')"
CDHASH="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^CandidateCDHash sha256/{print $2}' | head -1)"

printf '  version   %s (%s)\n' "$VERSION" "$BUILD_NUMBER"
printf '  team      %s\n' "${TEAM:-none}"
printf '  cdhash    %s\n' "${CDHASH:-unknown}"

if [ "${TEAM:-not set}" = "not set" ] || [ -z "${TEAM:-}" ]; then
    echo
    warn "No Team ID — permissions will NOT survive a rebuild."
else
    echo
    printf '  The CDHash changes every build; the Team ID does not. That is what keeps\n'
    printf '  microphone and accessibility grants alive across rebuilds.\n'
fi

echo
printf 'Next:  ./scripts/install.sh   (copy to /Applications and launch)\n'
