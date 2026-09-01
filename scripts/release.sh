#!/usr/bin/env bash
#
# Cut a release: build, zip, tag, and publish to GitHub Releases.
#
#   ./scripts/release.sh 0.1.0
#
# The repo can stay private: releases publish fine and collaborators can download
# them; the in-app update check simply stays quiet until the repo (or a public
# releases mirror) is visible to the world. When that day comes, nothing here
# changes — this script is already producing exactly what the checker looks for.
#
# Signing: whatever build.sh finds. Ad-hoc means downloaders face Gatekeeper's
# "unidentified developer" (right-click → Open) and permissions reset on every
# update; a Developer ID certificate plus notarization is the real fix before
# strangers install this. See build.sh's header for the one-line switch.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Murmr Flow"
VERSION="${1:-}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "Usage: ./scripts/release.sh <version>   (e.g. 0.1.0)"
TAG="v$VERSION"

# A release is a commit, not a working tree: what ships must be findable later.
[ -z "$(git status --porcelain)" ] || fail "The tree is dirty — commit or stash first."
git rev-parse "$TAG" >/dev/null 2>&1 && fail "Tag $TAG already exists."

BUILD_NUMBER=$(git rev-list --count HEAD)

bold "Building $VERSION ($BUILD_NUMBER), release configuration…"
CONFIG=release VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" ./scripts/build.sh

ZIP="build/MurmrFlow-$VERSION.zip"
bold "Zipping…"
# ditto preserves the signature and extended attributes; zip(1) can mangle bundles.
ditto -c -k --keepParent "build/$APP_NAME.app" "$ZIP"

bold "Tagging $TAG and publishing…"
git tag -a "$TAG" -m "Murmr Flow $VERSION"
git push origin "$TAG"

gh release create "$TAG" "$ZIP" \
    --title "Murmr Flow $VERSION" \
    --generate-notes

bold "Released $TAG"
printf '  artifact  %s\n' "$ZIP"
printf '  download  gh release download %s\n' "$TAG"
