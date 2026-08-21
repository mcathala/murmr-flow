import Foundation

/// Turning a stream of loudness readings into something a person can read.
///
/// Kept in one place because the microphone and the system-audio tap must agree: two
/// meters side by side are only comparable if they were measured the same way, and their
/// whole purpose is to be compared — a flat "Them" beside a moving "You" is how you
/// discover a capture that started cleanly and recorded silence.
enum AudioLevel {

    /// Fast attack, slow release.
    ///
    /// A meter should jump the instant you speak and fall back gently. Symmetrical
    /// smoothing gives you either a twitchy meter or a sluggish one; this gives neither.
    static func smooth(_ current: Float, towards target: Float) -> Float {
        let weight: Float = target > current ? attack : release
        return current * weight + target * (1 - weight)
    }

    private static let attack: Float = 0.35
    private static let release: Float = 0.88

    /// Where each of the three bars lights, in dBFS of RMS.
    ///
    /// Set against where speech and silence actually sit rather than by feel:
    ///
    ///   - a still room measures about −50 dBFS
    ///   - a room with a fan or air conditioning, −40 to −32
    ///   - conversational speech into a laptop microphone, −26 to −14
    ///
    /// So the first bar goes at −32: above a noisy room, below quiet speech. It is a
    /// genuine trade — someone speaking very softly in a loud room will not register —
    /// and it is the right way round, because a meter that is always lit tells you nothing
    /// at all, whereas one that occasionally under-reads still answers the question it
    /// exists for.
    ///
    /// The old first bar was −34 dBFS of *peak*, which is far lower than it sounds: noise
    /// peaks several times above its RMS, so a microphone's own noise floor cleared it and
    /// the bar never went out.
    static let barThresholds: [Float] = [-32, -25, -18]

    /// dBFS mapped to 0…1 for the waveform.
    ///
    /// Linear amplitude is the wrong scale for a display: RMS speech is a small fraction
    /// of full scale, so drawn linearly a normal voice barely moves the bars. Hearing is
    /// logarithmic and the meter should be too.
    static func normalised(_ level: Float) -> Double {
        guard let db = decibels(level) else { return 0 }
        return min(max((Double(db) - floorDB) / (ceilingDB - floorDB), 0), 1)
    }

    static func isLit(_ level: Float, bar index: Int) -> Bool {
        guard let db = decibels(level), index < barThresholds.count else { return false }
        return db > barThresholds[index]
    }

    private static func decibels(_ level: Float) -> Float? {
        guard level > 0 else { return nil }
        return 20 * log10(level)
    }

    private static let floorDB: Double = -50
    private static let ceilingDB: Double = -6
}
