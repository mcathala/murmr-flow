# Bundled fonts

Both are bundled rather than assumed present. A font the app merely *hopes* is installed
gives every other machine a silent fallback to the system face — and the app then looks
subtly wrong in a way nobody can describe.

Static weights, not the variable files. Mona Sans ships a lovely variable font with weight,
width and optical-size axes, but macOS's resolution of arbitrary axis values through
`Font.custom(_:size:).weight(_:)` is inconsistent — a named static face per weight is dull
and works. Four weights is all the interface uses.

| Family | Version | Licence | Source |
|---|---|---|---|
| Mona Sans | 2.0.27 | SIL OFL 1.1 | https://github.com/github/mona-sans |
| JetBrains Mono | 2.304 | SIL OFL 1.1 | https://github.com/JetBrains/JetBrainsMono |

Both licences are alongside the fonts as required, and the build copies them into the app
bundle. OFL permits bundling inside an application, including one that is distributed.

Registered through `ATSApplicationFontsPath` in `Info.plist`, which makes them available to
this process only — nothing is installed into the user's font library.
