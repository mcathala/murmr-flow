#!/usr/bin/env bash
#
# Build the app icon (.icns) from resources/brand/app-icon.svg.
#
# Same shape as build-adapter.sh: its own cache, because the icon changes about never and
# rasterising ten sizes through the Swift interpreter costs ~10 s of pure waste otherwise.
#
#   ./scripts/build-icon.sh          reuse the cached icon when the SVG is unchanged
#   FORCE=1 ./scripts/build-icon.sh  rebuild regardless
#
# Output: .build/icon/AppIcon.icns

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SVG="resources/brand/app-icon.svg"
OUT=".build/icon"
ICNS="$OUT/AppIcon.icns"
ICONSET="$OUT/AppIcon.iconset"
HASH_FILE="$OUT/.sources.hash"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

[ -f "$SVG" ] || fail "Icon source not found at $SVG"

# The renderer is part of the identity of the build too.
CURRENT_HASH="$(shasum -a 256 "$SVG" scripts/render-icon.swift | shasum -a 256 | cut -d' ' -f1)"

if [ "${FORCE:-0}" != "1" ] \
   && [ -f "$HASH_FILE" ] \
   && [ -f "$ICNS" ] \
   && [ "$(cat "$HASH_FILE")" = "$CURRENT_HASH" ]; then
    echo "AppIcon.icns up to date (cached)"
    exit 0
fi

bold "Rendering app icon…"
mkdir -p "$OUT"
swift scripts/render-icon.swift "$SVG" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICNS" || fail "iconutil failed"
rm -rf "$ICONSET"

printf '%s' "$CURRENT_HASH" > "$HASH_FILE"
echo "Built $ICNS"
