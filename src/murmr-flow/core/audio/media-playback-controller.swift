import Foundation
import OSLog

/// Pauses whatever is playing while you dictate, and resumes only what it paused.
///
/// Uses the vendored `mediaremote-adapter`, driven through `/usr/bin/perl`. See
/// `third-party/mediaremote-adapter/VENDORED.md` for why that indirection is necessary —
/// briefly, macOS gates `MediaRemote` by bundle identifier, perl is entitled and we are
/// not, and every public alternative reports stale state for roughly ten seconds after
/// playback stops.
///
/// Because this reports the *media application's* playback state rather than audio-device
/// activity, opening our own microphone cannot pollute the answer. That is why the query
/// can run concurrently with the start of recording instead of delaying it.
actor MediaPlaybackController {

    /// `MRCommand` identifiers.
    private enum Command: String {
        case play = "0"
        case pause = "1"
    }

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "media")

    /// Generous enough for a process spawn, short enough that a wedged adapter cannot
    /// hold a dictation open.
    private static let timeout: TimeInterval = 2.0

    private struct NowPlaying: Decodable {
        let playbackRate: Double?
        let playing: Bool?

        var isPlaying: Bool {
            // playbackRate is the authoritative signal; `playing` is a convenience field
            // and has been seen disagreeing with it on a loaded-but-paused track.
            if let playbackRate { return playbackRate > 0 }
            return playing ?? false
        }
    }

    // MARK: - API

    /// Pauses playback if something is genuinely playing.
    /// - Returns: whether *we* paused, which is what `resumeIfWePaused` needs.
    func pauseIfPlaying() async -> Bool {
        guard let state = await run(["get", "--no-artwork"]) else {
            Self.log.notice("pause skipped: adapter unavailable")
            return false
        }
        guard let decoded = try? JSONDecoder().decode(NowPlaying.self, from: state),
              decoded.isPlaying
        else {
            Self.log.notice("pause skipped: nothing playing")
            return false
        }

        _ = await run(["send", Command.pause.rawValue])
        Self.log.notice("paused playback")
        return true
    }

    /// Resumes only if we were the ones who paused. Anything paused by the user stays
    /// paused. An explicit play command, not a toggle — so this cannot start something
    /// that was already stopped.
    func resumeIfWePaused(_ wePaused: Bool) async {
        guard wePaused else { return }
        _ = await run(["send", Command.play.rawValue])
        Self.log.notice("resumed playback")
    }

    // MARK: - Adapter invocation

    private static var scriptURL: URL? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }

    private static var frameworkURL: URL? {
        Bundle.main.privateFrameworksURL?
            .appendingPathComponent("MediaRemoteAdapter.framework")
    }

    /// Runs the adapter and returns stdout, or `nil` on any failure. Every problem
    /// degrades to "do nothing": losing music-pause is a minor annoyance, whereas
    /// disrupting a dictation over it would not be acceptable.
    private func run(_ arguments: [String]) async -> Data? {
        guard let script = Self.scriptURL, let framework = Self.frameworkURL else {
            Self.log.notice("adapter not found in the app bundle")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            Self.log.notice("adapter failed to launch: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Read before waiting: a full pipe buffer would otherwise deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(Self.timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            process.terminate()
            Self.log.notice("adapter timed out")
            return nil
        }

        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
