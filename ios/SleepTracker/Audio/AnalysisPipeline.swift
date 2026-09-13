import Foundation

/// The gate, the ring and the health counters, and the queue that owns them.
///
/// Split from `NightRecorder` because it is the one part with a hard threading contract:
/// three threads touch this app and only one of them may touch this state. Keeping it behind
/// a type with a serial queue makes the contract enforceable rather than merely documented.
///
/// Nothing here knows about sessions, files or SwiftUI.
final class AnalysisPipeline {
    /// Fires on the pipeline's own queue when the gate closes an event.
    var onEvent: ((PendingEvent) -> Void)?
    /// Fires when an event closed but its audio had already scrolled out of the ring.
    var onDropped: (() -> Void)?
    /// Fires on the pipeline's own queue with the current floor and peak, for the meter.
    var onLevel: ((_ floorDB: Double, _ peakDB: Double) -> Void)?

    private let sampleRate: Double
    private let ringSeconds: Int
    private let queue = DispatchQueue(
        label: "de.sebamomann.sleeptracker.analysis",
        qos: .userInitiated
    )

    // Touched only on `queue`.
    private var gate: NoiseGate?
    private var ring: SampleRing?
    private var health = CaptureHealth()
    private var totalSamples = 0
    private var eventCounter = 0
    private var nightID = ""
    private var nightStart = Date()

    init(sampleRate: Double, ringSeconds: Int) {
        self.sampleRate = sampleRate
        self.ringSeconds = ringSeconds
    }

    /// Begin a night. Safe to call before any samples arrive, and only then.
    func begin(nightID: String, at start: Date) {
        queue.sync {
            self.nightID = nightID
            nightStart = start
            totalSamples = 0
            eventCounter = 0
            health = CaptureHealth()
            ring = SampleRing(capacity: Int(sampleRate) * ringSeconds)
            let newGate = NoiseGate(sampleRate: sampleRate)
            newGate.onEvent = { [weak self] event in self?.harvest(event) }
            gate = newGate
        }
    }

    /// Hand over samples from the audio thread. Returns immediately.
    func push(_ samples: [Float]) {
        queue.async { [weak self] in self?.consume(samples) }
    }

    /// Read the analysis state into a session. Blocks briefly; call from the main actor at
    /// save points, not per buffer.
    func snapshot(into session: inout NightSession) {
        queue.sync {
            session.audioSec = health.audioSeconds
            session.gaps = health.gaps
            session.lastFrameAtMs = health.lastFrameAt.map { $0.timeIntervalSince1970 * 1000 }
            guard let gate else { return }
            session.floorDb = gate.floorDB
            session.thresholdDb = gate.threshold
            session.rejectedEvents = gate.rejected
            session.envelope = gate.envelope.map(\.rounded)
        }
    }

    // MARK: - On `queue`

    private func consume(_ samples: [Float]) {
        guard let gate, let ring else { return }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ring.append(base, count: buffer.count)
            gate.process(base, count: buffer.count, totalSamplesBefore: totalSamples)
        }
        totalSamples += samples.count
        health.note(totalSamples: totalSamples, sampleRate: sampleRate)
        onLevel?(gate.floorDB, gate.read())
    }

    private func harvest(_ event: GateEvent) {
        guard let ring else { return }
        let samples = ring.slice(from: event.startSample, to: event.endSample)
        // An empty slice means the audio scrolled out of the ring before we reached it.
        // Writing it as a file of zeroes would be worse than admitting it is gone.
        guard !samples.isEmpty else {
            onDropped?()
            return
        }

        eventCounter += 1
        onEvent?(PendingEvent(
            samples: samples,
            index: eventCounter,
            at: nightStart.addingTimeInterval(Double(event.startSample) / sampleRate),
            startS: Double(event.startSample) / sampleRate,
            endS: Double(event.endSample) / sampleRate,
            peakDb: event.peakDB,
            nightID: nightID
        ))
    }
}
