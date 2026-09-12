// @preconcurrency silences one Sendable warning: AVAudioConverter's input block is
// @Sendable and captures the tap's buffer. That capture is safe because the block runs
// synchronously inside convert(), on the audio thread, while the buffer is still valid —
// handing the same buffer to another queue to read *later* was a real bug, and it is gone.
@preconcurrency import AVFoundation

/// The microphone, converted to the one format the rest of the app speaks.
///
/// Everything downstream wants 16 kHz mono float — SoundAnalysis and the gate both — while
/// the hardware offers whatever it offers, so the conversion happens here and nowhere else.
final class CaptureEngine {
    /// 16 kHz mono: SoundAnalysis and YAMNet both want it, and it is ample for snoring
    /// and speech.
    static let sampleRate = 16000.0

    let workFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: CaptureEngine.sampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Fires on the audio thread with converted, copied samples. Get off this thread
    /// promptly — anything slow here is dropped capture.
    var onSamples: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    var isRunning: Bool {
        engine.isRunning
    }

    /// Starts capture and returns a description of the hardware format, for the night's log.
    @discardableResult
    func start() throws -> String {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "SleepTracker", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "input node has no format — is the microphone permission granted?"
            ])
        }

        converter = AVAudioConverter(from: hwFormat, to: workFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()

        return "\(Int(hwFormat.sampleRate)) Hz \(hwFormat.channelCount)ch"
            + " → \(Int(Self.sampleRate)) Hz mono"
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    /// Called on the audio thread. The tap's buffer belongs to the engine and is recycled as
    /// soon as this returns, so it is converted and COPIED here; handing it to another thread
    /// to read later is a use-after-free that surfaces as intermittently corrupted audio.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = workFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: capacity)
        else { return }

        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied {
                status.pointee = .noDataNow; return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0,
              let channel = out.floatChannelData?[0] else { return }
        onSamples?(Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength))))
    }
}
