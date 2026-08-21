import FluidAudio
import Foundation
import Testing

@testable import MurmrFlow

@Suite("Segmenting")
struct SegmentingTests {

    /// Token text arrives with the word-boundary marker already turned into a leading
    /// space, so that is how these fixtures are written.
    private func token(
        _ text: String, _ start: TimeInterval, _ end: TimeInterval
    ) -> TokenTiming {
        TokenTiming(token: text, tokenId: 1, startTime: start, endTime: end, confidence: 1)
    }

    @Test("a pause starts a new segment")
    func pauseSplits() {
        let segments = TranscriptionService.segments(from: [
            token(" one", 0.0, 0.2),
            token(" two", 0.2, 0.4),
            // A gap well past the threshold.
            token(" three", 2.0, 2.2),
        ])

        #expect(segments.count == 2)
        #expect(segments[0].text == "one two")
        #expect(segments[1].text == "three")
    }

    @Test("punctuation never opens a segment")
    func punctuationStaysPut() {
        // The model emits a full stop a beat after the word it belongs to, often past the
        // pause threshold — which used to leave one segment ending mid-sentence and the
        // next starting with a stray "?".
        let segments = TranscriptionService.segments(from: [
            token(" Wednesday", 0.0, 0.3),
            token("?", 1.4, 1.5),
            token(" That", 2.6, 2.8),
            token(" works", 2.8, 3.0),
        ])

        #expect(segments.count == 2)
        #expect(segments[0].text == "Wednesday?")
        #expect(segments[1].text == "That works")
    }

    @Test("an uninterrupted monologue is still broken up")
    func maxLength() {
        // No pause anywhere, so only the length cap can split it.
        let tokens = (0..<400).map { index -> TokenTiming in
            let start = Double(index) * 0.1
            return token(" word", start, start + 0.1)
        }
        let segments = TranscriptionService.segments(from: tokens)

        #expect(segments.count > 1)
        for segment in segments {
            #expect(segment.end - segment.start <= TranscriptionService.maxSegmentDuration + 0.2)
        }
    }

    @Test("no tokens means no segments")
    func empty() {
        #expect(TranscriptionService.segments(from: []).isEmpty)
    }

    // MARK: - Silence

    private func samples(seconds: Double, loudFrom: Double, loudTo: Double) -> [Float] {
        let rate = 16_000.0
        return (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            return (time >= loudFrom && time < loudTo) ? 0.4 : 0
        }
    }

    @Test("words invented in open silence are dropped")
    func silenceDropped() {
        // Audio is silent for the first 8s, then real speech. A model asked to transcribe
        // the silence will happily produce a sentence there.
        let audio = samples(seconds: 12, loudFrom: 8, loudTo: 12)
        let tokens = [
            token(" invented", 1.0, 1.4),
            token(" nonsense", 1.4, 1.8),
            token(" real", 8.5, 8.9),
            token(" words", 8.9, 9.3),
        ]

        let kept = TranscriptionService.dropInvented(tokens, over: audio)
        #expect(kept.count == 2)
        #expect(kept.map(\.token).joined() == " real words")
    }

    @Test("a real word at the very edge of speech is kept")
    func edgesKept() {
        // This is the case that made per-token filtering worse than useless: alignment is
        // approximate, so a correct leading word can sit over silence by the model's own
        // timing. Measured on a real clip, " The" came in at rms 0.00000.
        let audio = samples(seconds: 5, loudFrom: 0.5, loudTo: 4.0)
        let tokens = [
            token(" The", 0.16, 0.24),   // before the signal starts
            token(" middle", 2.0, 2.4),
            token("k", 4.05, 4.3),       // after it ends
            token(".", 4.35, 4.4),
        ]

        let kept = TranscriptionService.dropInvented(tokens, over: audio)
        #expect(kept.count == 4)
    }

    @Test("a wholly silent stream keeps nothing")
    func allSilence() {
        let audio = [Float](repeating: 0, count: 16_000 * 5)
        let kept = TranscriptionService.dropInvented(
            [token(" ghost", 1.0, 1.4)], over: audio
        )
        #expect(kept.isEmpty)
    }

    @Test("with no audio to check, nothing is thrown away")
    func noAudioIsNoOpinion() {
        let tokens = [token(" hello", 0, 0.4)]
        #expect(TranscriptionService.dropInvented(tokens, over: []).count == 1)
    }
}
