# Murmr Flow

Local-first dictation and meeting notes for macOS.

The speech model runs entirely on-device. Audio never leaves the machine; only
cleaned-up text is sent to an AI provider, and only if you configure one.

**Two jobs.** *Dictation* — hold a hotkey, speak, and the text is inserted wherever
your cursor is. *Notetaker* — record a meeting and get a Markdown note with speaker
labels.

> **Work in progress.** Both jobs work end to end. Still a personal daily-driver
> rather than something to hand to anyone who can't run a build script.

## What stays on the machine

- **Speech-to-text** runs on-device with NVIDIA's Parakeet models, through
  [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine. The
  model (~600 MB) is downloaded on first use and cached; audio is never uploaded.
- **Dictation audio** lives in memory only and is gone once the text is typed. The
  dictation log — raw and cleaned text, when, and which app it went to — is at
  `~/Library/Application Support/Murmr Flow/dictations.jsonl`.
- **Meeting audio** is written to a temporary folder while recording and deleted as
  soon as the note is saved. The note is the only copy.
- **Notes** are plain Markdown files with YAML front matter in `~/Documents/MurmurNotes`.
  Edit or delete them in any editor; the app re-reads the folder.
- **API keys** are stored in the macOS Keychain.
- **What leaves the machine** is the transcript text, sent to the clean-up provider you
  configure, and nothing if you configure none.

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

## AI clean-up

Clean-up turns the raw transcript into punctuated, filler-free text. It is optional,
and it is the one step that sends anything off the machine. Any server that speaks the
OpenAI chat API works; Settings › AI clean-up offers:

| Provider | Needs a key |
|---|---|
| Groq | yes |
| Cerebras | yes |
| Ollama Cloud | yes |
| OpenRouter | yes |
| Google Gemini | yes |
| Custom — any OpenAI-compatible URL | no, unless the server asks for one |

Custom is how a local model runs: point it at Ollama (`http://localhost:11434/v1`) or
LM Studio (`http://localhost:1234/v1`) and nothing leaves the machine at all. If the
provider is slow, down or rejects the request, the raw transcript is typed instead —
a dictation is never lost to a failed clean-up.

## Tests

```sh
swift test
```

With Command Line Tools but no Xcode, `swift-testing` is off the default search
paths and that fails with `no such module 'Testing'`. Point at the CLT copy:

```sh
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --arch arm64 -Xswiftc -F"$FW" -Xlinker -F"$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB"
```

The snapshot suites write PNGs when `MURMR_SNAPSHOT_DIR` is set, which is the
quickest way to look at a view without launching the app.

## Scripts

| Script | Does |
|---|---|
| `dev.sh` | The developer loop: rebuild, install, relaunch (`--fresh` for a new-user run) |
| `build.sh` | Compile, assemble the `.app`, sign it |
| `install.sh` | Copy to `/Applications` and launch |
| `build-adapter.sh` | Build the vendored mediaremote-adapter framework (own cache) |
| `build-icon.sh` | Rasterise the app icon from the brand SVG (own cache) |
| `release.sh` | Build, zip, tag, publish to GitHub Releases |
| `verify-signing.sh` | Print signature, Team ID, CDHash, entitlements |
| `make-cert.sh` | Create a persistent self-signed certificate |
| `reset-permissions.sh` | Revoke permission grants to retest the flow |

## Layout

```
Package.swift              SwiftPM executable; no .xcodeproj by design
src/murmr-flow/            app code — app/, core/, dictation/, meetings/
resources/                 Info.plist and entitlements templates
scripts/                   build, install, verify, helpers
tests/                     swift-testing suites
```

Files and directories are lowercase `kebab-case`; Swift *type* names stay
`PascalCase`.

Xcode can open `Package.swift` directly for a debugger or SwiftUI previews.

## Licence

Not yet chosen.
