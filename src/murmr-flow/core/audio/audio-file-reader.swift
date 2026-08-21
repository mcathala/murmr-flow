import AVFoundation

/// Reads a recording back as the mono Float samples the speech model takes.
enum AudioFileReader {

    enum ReaderError: LocalizedError {
        case empty
        case unreadable

        var errorDescription: String? {
            switch self {
            case .empty: "The recording is empty."
            case .unreadable: "The recording could not be read."
            }
        }
    }

    /// Loads the whole file into memory.
    ///
    /// An hour at 16 kHz is 230 MB of Float, which is affordable once. Reading in chunks
    /// rather than one buffer the size of the file keeps the peak at roughly the array
    /// itself, instead of the array plus a full-size scratch copy.
    static func samples(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            // Float32 regardless of what is on disk: `processingFormat` drives the
            // conversion, so the Int16 file comes back as Float without a second pass.
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw ReaderError.unreadable
        }

        let total = file.length
        guard total > 0 else { throw ReaderError.empty }

        let format = file.processingFormat
        let chunkFrames: AVAudioFrameCount = 16_000 * 10  // ten seconds
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw ReaderError.unreadable
        }

        var samples = [Float]()
        samples.reserveCapacity(Int(total))

        while file.framePosition < total {
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            guard let channel = buffer.floatChannelData?[0] else { throw ReaderError.unreadable }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        }

        guard !samples.isEmpty else { throw ReaderError.empty }
        return samples
    }

    /// Root-mean-square level of a slice, used to tell real speech from a silent stream.
    ///
    /// The speech model will happily invent words from room noise, so a segment is only
    /// trusted if there was actually something there to hear.
    static func level(of samples: [Float], from start: Int, to end: Int) -> Float {
        let lower = max(0, min(start, samples.count))
        let upper = max(lower, min(end, samples.count))
        guard upper > lower else { return 0 }

        var sum: Float = 0
        for index in lower..<upper {
            sum += samples[index] * samples[index]
        }
        return (sum / Float(upper - lower)).squareRoot()
    }
}
