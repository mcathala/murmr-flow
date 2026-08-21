import AVFoundation

/// Converts incoming audio to 16 kHz mono and streams it to a WAV file as it arrives.
///
/// Both capture paths need exactly this. The microphone and the system-audio tap each
/// hand over buffers on a real-time thread, in whatever format the hardware picked, and
/// both want the one format the speech model reads.
///
/// Streaming rather than accumulating, because meetings are long. An hour of 48 kHz
/// stereo float held in memory is about 1.4 GB; the same hour on disk as 16 kHz mono
/// Int16 is 115 MB. Dictation can afford to convert once at the end — a meeting cannot.
///
/// One converter instance serves the whole recording, deliberately. `AVAudioConverter`
/// carries its resampling filter state across calls, so feeding it sequentially is
/// continuous. Creating a fresh one per buffer is what puts a click at every boundary.
final class AudioFileWriter: @unchecked Sendable {

    /// What the speech model expects.
    static let sampleRate: Double = 16_000

    /// Int16 on disk rather than float: half the bytes, and the model reads back at a
    /// precision far below what 24 bits of headroom would buy.
    static var fileFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )
    }

    enum WriterError: LocalizedError {
        case formatUnavailable
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .formatUnavailable: "The 16 kHz output format is unavailable."
            case .converterUnavailable: "The audio could not be converted for recording."
            }
        }
    }

    let url: URL

    private let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter
    /// Optional so `finish()` can release it. `AVAudioFile` writes its header on
    /// close, and close only happens on deinit — holding it would leave the file
    /// unreadable until the writer itself went away.
    private var file: AVAudioFile?

    /// Conversion and file I/O both happen here, never on the audio thread.
    private let queue: DispatchQueue

    /// Guarded by `queue`.
    private var framesWritten: AVAudioFramePosition = 0
    private var isFinished = false

    /// Loudness of the most recent buffer, 0…1. Its own lock rather than the queue,
    /// because the UI reads it ten times a second and must never wait behind a disk write.
    private let levelLock = NSLock()
    private var recentLevel: Float = 0

    /// For the live meters. A flat meter is how you find out a stream is silent while
    /// there is still time to do something about it.
    var level: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return recentLevel
    }

    init(sourceFormat: AVAudioFormat, url: URL, label: String) throws {
        guard let target = Self.fileFormat else { throw WriterError.formatUnavailable }
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw WriterError.converterUnavailable
        }

        self.url = url
        self.sourceFormat = sourceFormat
        self.converter = converter
        self.file = try AVAudioFile(
            forWriting: url,
            settings: target.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        self.queue = DispatchQueue(label: "app.murmr.MurmrFlow.audio-write.\(label)")
    }

    // MARK: - Input

    /// Accepts a buffer from `AVAudioEngine`. Safe to call on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        let frames = buffer.frameLength
        guard frames > 0, let copy = makeCopy(frames: frames) else { return }
        Self.copyBytes(
            from: UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: buffer.audioBufferList)
            ),
            into: copy
        )
        enqueue(copy)
    }

    /// Accepts a Core Audio buffer list, which is what a process tap delivers. Safe to
    /// call on the audio thread.
    func append(bufferList: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard let first = list.first, first.mDataByteSize > 0 else { return }

        let bytesPerFrame = sourceFormat.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let frames = AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)

        guard frames > 0, let copy = makeCopy(frames: frames) else { return }
        Self.copyBytes(from: list, into: copy)
        enqueue(copy)
    }

    // MARK: - Finishing

    /// Flushes everything queued, closes the file, and returns the duration written.
    ///
    /// Synchronous on purpose: the file's header is only correct once it is closed, so a
    /// caller that returns the URL must know the write has landed.
    @discardableResult
    func finish() -> TimeInterval {
        queue.sync {
            isFinished = true
            file = nil
            return TimeInterval(framesWritten) / Self.sampleRate
        }
    }

    // MARK: - Plumbing

    /// The caller's buffer is only valid for the duration of its callback, so take a copy
    /// before handing it to another thread.
    private func makeCopy(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { return nil }
        // Set the length before copying: it is what sizes `mDataByteSize` on the
        // destination buffers, and a zero-length buffer would accept nothing.
        copy.frameLength = frames
        return copy
    }

    private static func copyBytes(
        from source: UnsafeMutableAudioBufferListPointer,
        into buffer: AVAudioPCMBuffer
    ) {
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let src = source[index].mData, let dst = destination[index].mData else {
                continue
            }
            let bytes = Int(min(source[index].mDataByteSize, destination[index].mDataByteSize))
            memcpy(dst, src, bytes)
        }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        // AVAudioPCMBuffer is not Sendable, but this one was just allocated here and is
        // never touched again on this thread, so the handoff is a move, not sharing.
        let handoff = Handoff(buffer: buffer)
        queue.async { [weak self] in
            self?.convertAndWrite(handoff.buffer)
        }
    }

    /// Runs on `queue`.
    private func convertAndWrite(_ input: AVAudioPCMBuffer) {
        guard !isFinished else { return }

        let ratio = Self.sampleRate / sourceFormat.sampleRate
        // The converter can emit slightly more than the ratio suggests when it flushes
        // buffered filter tail, so leave headroom rather than truncating.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat, frameCapacity: capacity
        ) else { return }

        let supply = Supply(buffer: input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let next = supply.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        guard error == nil, output.frameLength > 0 else { return }

        note(level: Self.peak(of: output))

        guard let file else { return }
        do {
            try file.write(from: output)
            framesWritten += AVAudioFramePosition(output.frameLength)
        } catch {
            // A failed write means a full disk or a vanished file. Nothing useful can be
            // done from the writer queue, and the transcript will simply be short.
        }
    }

    private func note(level: Float) {
        levelLock.lock()
        recentLevel = max(level, recentLevel * 0.72)
        levelLock.unlock()
    }

    /// Peak of an Int16 buffer, normalised to 0…1.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var loudest: Int32 = 0
        for index in 0..<frames {
            loudest = max(loudest, Int32(abs(Int32(channel[index]))))
        }
        return Float(loudest) / Float(Int16.max)
    }

    /// Yields the input buffer exactly once, which is the contract `AVAudioConverter`'s
    /// input block expects. A reference type because mutating a captured local from that
    /// block is a data-race warning under Swift 6.
    private final class Supply: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    /// Moves a buffer from the audio thread to the writer queue.
    private struct Handoff: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }
}
