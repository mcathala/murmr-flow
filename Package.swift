// swift-tools-version: 6.0
import PackageDescription

// Murmr Flow is built as a SwiftPM executable that `scripts/build.sh` wraps into a
// proper .app bundle. There is deliberately no .xcodeproj:
//
//   - the whole build is text-based and diffable (no project.pbxproj merge conflicts)
//   - the same script works locally and in CI
//   - Xcode can still open Package.swift directly for debugging and previews
//
// `src` is one of SwiftPM's predefined source directories (searched in the order
// Sources, Source, src, srcs), so this layout is supported rather than a workaround.
// An explicit `path` is still needed because the directory is lowercase while the
// target name is not.

let package = Package(
    name: "MurmrFlow",
    platforms: [
        // macOS 14 is the floor: FluidAudio requires 14.0+, and Core Audio process
        // taps (meetings mode, v2) require 14.4+.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MurmrFlow",
            path: "src/murmr-flow",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
