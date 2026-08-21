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
        // 14.2 is the floor: FluidAudio needs 14.0+, and Core Audio process taps —
        // which meetings mode uses to capture system audio — were introduced in 14.2.
        .macOS("14.2")
    ],
    dependencies: [
        // Parakeet speech-to-text, Silero VAD and speaker diarization as CoreML models
        // that run on the Apple Neural Engine. Apache-2.0.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "MurmrFlow",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "src/murmr-flow",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
