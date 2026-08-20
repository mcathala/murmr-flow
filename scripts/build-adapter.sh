#!/usr/bin/env bash
#
# Build the vendored mediaremote-adapter into a loadable framework.
#
# Separate from build.sh because it is a different job with a different cache: the app is
# rebuilt constantly, the adapter almost never changes. Compiling its 15 Objective-C files
# takes ~5 s, which is pure waste on every incremental build.
#
# Upstream builds with cmake. We use clang so that building Murmr Flow needs no extra
# tooling — see resources/mediaremote-adapter/VENDORED.md.
#
#   ./scripts/build-adapter.sh          reuse the cached build when sources are unchanged
#   FORCE=1 ./scripts/build-adapter.sh  rebuild regardless
#
# Output: .build/adapter/MediaRemoteAdapter.framework

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="resources/mediaremote-adapter"
OUT=".build/adapter"
FRAMEWORK="$OUT/MediaRemoteAdapter.framework"
HASH_FILE="$OUT/.sources.hash"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

[ -d "$SRC" ] || fail "Vendored adapter not found at $SRC"

SOURCES=(
    "$SRC"/src/adapter/*.m
    "$SRC"/src/private/*.m
    "$SRC"/src/utility/*.m
)

# Version and headers are part of the identity of the build, not just the .m files.
CURRENT_HASH="$(
    { shasum -a 256 "${SOURCES[@]}" "$SRC"/include/*.h "$SRC"/src/*/*.h 2>/dev/null
      cat "$SRC/VERSION" 2>/dev/null
    } | shasum -a 256 | cut -d' ' -f1
)"

if [ "${FORCE:-0}" != "1" ] \
   && [ -f "$HASH_FILE" ] \
   && [ -f "$FRAMEWORK/Versions/A/MediaRemoteAdapter" ] \
   && [ "$(cat "$HASH_FILE")" = "$CURRENT_HASH" ]; then
    echo "MediaRemoteAdapter $(cat "$SRC/VERSION") up to date (cached)"
    exit 0
fi

bold "Building MediaRemoteAdapter $(cat "$SRC/VERSION")…"

rm -rf "$FRAMEWORK"
# The canonical versioned framework layout: `codesign --deep` treats any .framework as a
# bundle and rejects one without it, even though perl only needs Name.framework/Name.
mkdir -p "$FRAMEWORK/Versions/A/Resources"

clang -dynamiclib -fobjc-arc -O2 \
    -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -I "$SRC/include" -I "$SRC/src" \
    "${SOURCES[@]}" \
    -o "$FRAMEWORK/Versions/A/MediaRemoteAdapter" \
    || fail "MediaRemoteAdapter build failed"

cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
	<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
	<key>CFBundleName</key><string>MediaRemoteAdapter</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>$(cat "$SRC/VERSION" | tr -d 'v')</string>
	<key>CFBundleVersion</key><string>$(cat "$SRC/VERSION" | tr -d 'v')</string>
</dict>
</plist>
PLIST

ln -sf A "$FRAMEWORK/Versions/Current"
ln -sf Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
ln -sf Versions/Current/Resources "$FRAMEWORK/Resources"

printf '%s' "$CURRENT_HASH" > "$HASH_FILE"
echo "Built $FRAMEWORK"
