<p align="center">
  <img src="resources/brand/app-icon.svg" alt="" width="96" />
</p>

<h1 align="center">Murmr Flow</h1>

<p align="center">
  <b>Local-first dictation and notes for macOS.</b><br />
  Hold a key, speak, and the words land where your cursor is. Or record what you are listening to and get a written note.<br />
  Either way the audio never leaves the Mac.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/mcathala/murmr-flow?style=flat" alt="MIT licence" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-lightgrey?style=flat" alt="macOS 14 or later, Apple Silicon" />
  <a href="https://github.com/mcathala/murmr-flow/releases/latest"><img src="https://img.shields.io/github/v/release/mcathala/murmr-flow?style=flat" alt="Latest release" /></a>
</p>

---

**Two jobs.**

- **Dictation** — hold a hotkey, speak, and the text is inserted wherever your cursor
  is. Any app, no integration, nothing to paste.
- **Notetaker** — record your microphone and whatever is playing through the Mac, and
  get a Markdown note with speaker labels and a written summary above the transcript.
  A meeting, a call, a lecture, a podcast — or just you, thinking out loud.

The speech model runs entirely on-device. Audio never leaves the machine; only
cleaned-up text is sent to an AI provider, and only if you configure one.

![Home — the two halves of the pipeline, your audio devices, and what you dictated today](docs/screenshots/home.png)

## Install

### macOS

One line, pasted into the Terminal:

```sh
curl -fsSL "$(curl -fsSL https://api.github.com/repos/mcathala/murmr-flow/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)" \
  -o /tmp/MurmrFlow.zip \
  && unzip -oq /tmp/MurmrFlow.zip -d /Applications \
  && open "/Applications/Murmr Flow.app"
```

That finds the latest release, unpacks it into `/Applications`, and opens it. It also
skips the warning below, because the quarantine flag that triggers Gatekeeper is set by
browsers, not by `curl`.

Prefer to click: [**download the latest release**](https://github.com/mcathala/murmr-flow/releases/latest),
unzip, drag `Murmr Flow.app` to `/Applications`. The builds are not notarized, so the
first launch gets *"cannot be opened because the developer cannot be verified"*.
Right-click the app → **Open** → **Open**. Once, and never again for that copy. If that
trade is not one you want to make, [build it yourself](#building-from-source) — the
result is the same app, signed by you.

Either route installs the same ad-hoc signed build. macOS ties permission grants to a
signature, so until these are signed with a Developer ID and notarized, each new
release asks for Accessibility and the microphone again.

### Windows

Not yet. The interface is a rewrite either way; the open question is the speech stack,
because the on-device model runs on Apple's Neural Engine and there is no drop-in
equivalent. Watch the repo if you want to know when that changes.

### Permissions

macOS asks for three things, and it is worth knowing why before you grant any of them:

| Permission | What it is actually for |
|---|---|
| **Microphone** | Hearing you. There is no version of this that works without it. |
| **Accessibility** | Two things: noticing the hotkey while another app is focused, and typing the finished text into that app. |
| **Screen Recording** | Hearing what the Mac itself is playing — the other side of a call, the video you are watching. macOS files the system-audio grant under Screen Recording; nothing looks at your screen, and no video is ever captured. |

Nothing is asked for until the moment it is needed, and dictation works with the
microphone alone — Screen Recording is only for the notetaker.

### First run

The speech model (~600 MB) downloads once and is cached. After that the app works
with the network off.

## Dictation

Hold the hotkey, say the sentence, release. The text appears at the cursor in whatever
app is in front — a text field, an editor, a chat box, a terminal.

What gets typed is the transcript after clean-up, which turns the raw speech into
punctuated, filler-free prose. Clean-up is optional, and it is the only step that
sends anything off the machine. If the provider is slow, down, or rejects the request,
the raw transcript is typed instead: a dictation is never lost to a failed clean-up.

Both versions are kept — the raw transcript and what was actually inserted — so you can
see whether the model improved your words or mangled them, and re-run clean-up against
a different prompt without saying the whole thing again.

## Notes from anything you hear

The notetaker records two things: your microphone, and whatever is playing through the
Mac. Between them that covers most of what is worth keeping —

- **Meetings and calls**, where the speaker labels do real work.
- **Lectures, courses and tutorials** — one person talking, you chipping in
  occasionally.
- **Podcasts and videos**, where nothing comes from your microphone at all and the
  note is simply what you listened to.
- **Thinking out loud**, with nothing playing: a structured note back instead of a
  transcript of yourself rambling.

You get a Markdown file: a written note at the top, your own typed notes kept whole and
separate beneath it, and the full speaker-labelled transcript below that.

![Notes — the written note above, the transcript below, the folder on the left](docs/screenshots/notes.png)

The notes are plain Markdown files with YAML front matter in `~/Documents/MurmurNotes`.
The file is the source of truth, not a database. Edit a note in any editor and the app
re-reads it; delete one in Finder and it is gone. That costs cheap search and instant
renames, and buys the thing that matters: the notes outlive the tool.

## What stays on the machine

- **Speech-to-text** runs on-device with NVIDIA's Parakeet models, through
  [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine. The
  model (~600 MB) is downloaded on first use and cached; audio is never uploaded.
- **Dictation audio** lives in memory only and is gone once the text is typed. The
  dictation log — raw and cleaned text, when, and which app it went to — is at
  `~/Library/Application Support/Murmr Flow/dictations.jsonl`.
- **Recorded audio** is written to a temporary folder while the notetaker runs and
  deleted as soon as the note is saved. The note is the only copy.
- **Notes** are plain Markdown files with YAML front matter in `~/Documents/MurmurNotes`.
  Edit or delete them in any editor; the app re-reads the folder.
- **API keys** are stored in the macOS Keychain.
- **What leaves the machine** is the transcript text, sent to the clean-up provider you
  configure, and nothing if you configure none.

There is no account, no telemetry, and no server belonging to this project.

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

## Building from source

### Requirements

- macOS 14 or later, Apple Silicon
- Xcode 26, or the matching Command Line Tools on their own. The build works with
  either; only `swift test` needs the extra flags described under [Tests](#tests) when
  Xcode is absent.
- A code signing certificate — an `Apple Development` one is ideal:

  ```sh
  security find-identity -v -p codesigning
  ```

  If you have none, `./scripts/make-cert.sh` creates a persistent self-signed one.
  This matters more than it sounds: macOS ties permission grants to the code
  signature, so an unstable signing identity makes them reset on every rebuild.

### Build

```sh
./scripts/build.sh      # compile, assemble the .app, sign it
./scripts/install.sh    # copy to /Applications and launch
```

`build.sh` accepts `CONFIG=release`, `UNIVERSAL=1`, `VERSION=` and
`SIGNING_IDENTITY=`.

### Tests

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

### Layout

```
Package.swift              SwiftPM executable; no .xcodeproj by design
src/murmr-flow/            app code — app/, core/, dictation/, meetings/
resources/                 Info.plist and entitlements templates
scripts/                   build, install, verify, helpers
tests/                     swift-testing suites
docs/screenshots/          the images above, made by scripts/screenshot.sh
```

Files and directories are lowercase `kebab-case`; Swift *type* names stay
`PascalCase`.

Xcode can open `Package.swift` directly for a debugger or SwiftUI previews.

### Scripts

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
| `demo-data.sh` | Swap your notes and history for invented ones (`--restore` puts yours back) |
| `screenshot.sh` | Capture the main window to `docs/screenshots/` |

### Screenshots

The images in this README come from a machine full of meetings that never happened.
`demo-data.sh` moves your own notes and dictation log aside and writes a folder of
fiction in the same on-disk formats the app already reads, so nothing in the app knows
it is being photographed — and `tests/murmr-flow-tests/demo-data-tests.swift` reads
that fiction back through `NoteStore` and `HistoryStore`, so a format change breaks the
test rather than quietly aging the screenshots.

```sh
./scripts/demo-data.sh            # invented notes and history in place of yours
./scripts/dev.sh                  # build, install, launch
./scripts/screenshot.sh home      # with Home open
./scripts/screenshot.sh notes     # with Notetaker open and a note selected
./scripts/demo-data.sh --restore  # your own data back
```

Captured without the drop shadow, on purpose: a shadow baked into the PNG is the wrong
shadow against every background but the one it was taken on, and GitHub's dark theme is
not that background.

Capturing another app's window needs the Screen Recording grant, and macOS gives it to
the terminal rather than to Murmr Flow — so on a machine without it, `screencapture`
answers *"could not create image from display"* and there is nothing a script can do
about that from the inside. Take the shot with macOS's own screenshotter instead
(⌘⇧4, Space, click the window) and file it under the right name:

```sh
./scripts/screenshot.sh home --adopt
```

## Contributing

Issues and pull requests are welcome. The house rules are short: lowercase
`kebab-case` filenames, `PascalCase` Swift types, and a comment earns its place by
saying *why* rather than restating the line below it. `swift test` should be green
before you open a PR.

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — the Neural Engine
  runtime that makes on-device Parakeet fast enough to dictate into.
- [NVIDIA Parakeet](https://huggingface.co/nvidia) — the speech models.
- [Mona Sans](https://github.com/github/mona-sans) and
  [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) — the bundled typefaces.

## Licence

[MIT](LICENSE).
