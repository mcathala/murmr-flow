# Murmr mark

Five capsule bars, the same construction as a sound-level meter, whose inner three bars
trace the V of an M between two full-height stems. Chosen 2026-09-07 after tuning on the
design page.

Geometry on a 1024 grid (x = bar centres, y = top–bottom):

| bar    | x   | y        |
|--------|-----|----------|
| stem   | 252 | 223–773  |
| outer  | 382 | 340–610  |
| middle | 512 | 450–670  |
| outer  | 642 | 340–610  |
| stem   | 772 | 223–773  |

Bar width 90, pitch 130, capsule radius 45. Icon: gold `#EBCE83` on navy `#04101F`,
corner radius 230. `murmr-m.glyph.svg` is the single-colour mark for template images
and in-app use.

`candidates/` keeps the earlier rounds and the generator that produced them.

## Where it is used

- `app-icon.svg` — the same mark on Apple's icon grid (an 824-pt squircle on the 1024
  canvas). `scripts/build-icon.sh` rasterises it into `AppIcon.icns` during
  `scripts/build.sh`; `Info.plist` names it via `CFBundleIconFile`.
- `src/murmr-flow/app/design/mark.swift` — the same numbers in Swift, for the menu-bar
  glyph (a template image) and the panel's level meter, whose resting shape is the mark.
  Change the geometry in one place and mirror it in the other.
