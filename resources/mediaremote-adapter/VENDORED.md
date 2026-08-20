# mediaremote-adapter (vendored)

- **Upstream:** https://github.com/ungive/mediaremote-adapter
- **Version:** see `VERSION` (tracks upstream release tags)
- **Licence:** BSD 3-Clause — see `LICENSE`

## Why this is here

macOS gates the private `MediaRemote` framework by bundle identifier. A signed app that
calls it directly gets symbols which resolve and then return nothing — verified: identical
code returns full now-playing data as a loose script and `nil` inside a signed bundle with
the Hardened Runtime.

`/usr/bin/perl` *is* entitled to talk to MediaRemote, so this adapter is a small
Objective-C dylib that perl loads on our behalf and drives over stdout as JSON.

## Why we can't use public APIs instead

Neither public signal can answer "is music playing". Measured on a Bluetooth headset,
both `kAudioDevicePropertyDeviceIsRunningSomewhere` and
`kAudioProcessPropertyIsRunningOutput` stay **true for about ten seconds after playback
stops**, because the audio process keeps its output stream open:

```
t+1s   rate=0.0   device=true    procsOutputting=1   ← wrong
t+9s   rate=0.0   device=true    procsOutputting=1   ← wrong
t+10s  rate=0.0   device=false   procsOutputting=0   ← finally right
```

Pressing the dictation key inside that window made us believe music was playing and toggle
it *on*. The adapter reports the media application's real playback rate, which is correct
immediately — and lets us send explicit pause/play instead of a blind toggle.

## Deviation from upstream

Upstream builds with cmake. `scripts/build-adapter.sh` compiles the same sources with
`clang` instead, so building Murmr Flow needs no extra tooling. The perl script only
requires `Name.framework/Name` to be a loadable dylib, so nothing is lost.

## Updating

1. Pick the upstream release you want.
2. Replace `src/`, `include/`, `bin/` and `LICENSE` from that tag.
3. Put the tag in `VERSION`.
4. Re-run the build — `scripts/build-adapter.sh` rebuilds automatically when sources change.

Only the file list in `scripts/build-adapter.sh` should ever need touching.
