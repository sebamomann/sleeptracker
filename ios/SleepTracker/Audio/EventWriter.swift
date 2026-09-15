import AVFoundation

/// Turns a gated stretch of samples into a file on disk with labels attached.
///
/// Kept away from the recorder because it is slow and blocking by nature — encoding,
/// then reading the file back to classify it — and because none of it needs to know
/// anything about the night in progress.
struct EventWriter {
    /// Ramp at each edge. A gated clip starts at an arbitrary sample, so its first and last
    /// values are almost never zero, and that step discontinuity is audible as a click.
    static let fadeMS = 40.0
    /// 32 kbps mono AAC: about a tenth the size of the equivalent WAV, and ample for 16 kHz
    /// speech and snoring.
    static let bitRate = 32000

    let format: AVAudioFormat

    struct Written {
        let record: NightSession.EventRecord
        let url: URL
        /// Whether it is worth asking the transcriber about. Transcription is asynchronous
        /// and belongs to whoever owns the session, so it is not started here.
        let isSpeech: Bool
    }

    func write(_ pending: PendingEvent) throws -> Written {
        var faded = pending.samples
        Self.fadeEdges(&faded, rate: format.sampleRate, ms: Self.fadeMS)

        // Not Opus, despite Opus being the better codec: on iOS it means a CAF container
        // nothing outside Apple's stack will open, whereas m4a plays everywhere and is read
        // natively by both the classifier and the transcriber.
        let file = String(
            format: "%04d-%@.m4a",
            pending.index,
            Fmt.fileTime.string(from: pending.at)
        )
        let url = SessionStore.shared.eventsDirectory(for: pending.nightID)
            .appendingPathComponent(file)
        try Self.encode(faded, format: format, to: url)

        // Classified after the file exists: the classifier reads a URL rather than taking a
        // buffer, and this is not the audio thread, so it can take its time.
        let labels = EventClassifier.shared.classify(url: url)

        let record = NightSession.EventRecord(
            index: pending.index,
            file: file,
            atMs: pending.at.timeIntervalSince1970 * 1000,
            startS: pending.startS,
            endS: pending.endS,
            durationS: Double(faded.count) / format.sampleRate,
            peakDb: pending.peakDb,
            labels: labels.isEmpty ? nil : labels
        )

        return Written(
            record: record,
            url: url,
            isSpeech: labels.contains {
                $0.identifier.lowercased().contains("speech")
            }
        )
    }

    /// Writes mono float samples as 32 kbps AAC. Shared with `TrainingExport`, which
    /// decodes, amplifies and re-encodes a clip through the same path rather than its own.
    static func encode(_ samples: [Float], format: AVAudioFormat, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: Self.bitRate
        ]
        let audioFile = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try audioFile.write(from: buffer)
    }

    /// Raised-cosine ramp at both edges, in place.
    static func fadeEdges(_ s: inout [Float], rate: Double, ms: Double) {
        let n = min(Int(rate * ms / 1000), s.count / 2)
        guard n >= 1 else { return }
        for i in 0 ..< n {
            let gain = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(n)))
            s[i] *= gain
            s[s.count - 1 - i] *= gain
        }
    }
}
