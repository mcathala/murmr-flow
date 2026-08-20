# Murmr Flow

Local-first voice dictation and meeting notes for macOS.

Speech-to-text runs entirely on-device. Audio never leaves the machine.

> **Early work in progress.** Not usable yet — there is no audio capture or
> transcription in the code so far. Current state is a permissions and code-signing
> harness.

## Requirements

- macOS 14 or later, Apple Silicon
- Xcode 26 (or matching Command Line Tools)
- A code signing certificate — an `Apple Development` one is ideal:

  ```sh
  security find-identity -v -p codesigning
  ```

  If you have none, `./scripts/make-cert.sh` creates a persistent self-signed one.
  This matters more than it sounds: macOS ties permission grants to the code
  signature, so an unstable signing identity makes them reset on every rebuild.

## Build

```sh
./scripts/build.sh      # compile, assemble the .app, sign it
./scripts/install.sh    # copy to /Applications and launch
```

`build.sh` accepts `CONFIG=release`, `UNIVERSAL=1`, `VERSION=` and
`SIGNING_IDENTITY=`.

## Scripts

| Script | Does |
|---|---|
| `build.sh` | Compile, assemble the `.app`, sign it |
| `install.sh` | Copy to `/Applications` and launch |
| `verify-signing.sh` | Print signature, Team ID, CDHash, entitlements |
| `make-cert.sh` | Create a persistent self-signed certificate |
| `reset-permissions.sh` | Revoke permission grants to retest the flow |

## Layout

```
Package.swift              SwiftPM executable; no .xcodeproj by design
src/murmr-flow/            app code — app/ and core/
resources/                 Info.plist and entitlements templates
scripts/                   build, install, verify, helpers
```

Files and directories are lowercase `kebab-case`; Swift *type* names stay
`PascalCase`.

Xcode can open `Package.swift` directly for a debugger or SwiftUI previews.

## Licence

Not yet chosen.
