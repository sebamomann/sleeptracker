import Foundation

/// Thresholds the app learns instead of being told.
///
/// What counts as an event cannot be written down once. It depends on the room, on how far
/// the phone sleeps from the bed, and on that phone's microphone gain — a night peaking at
/// -20 dBFS on the pillow and one peaking at -45 across the room need different numbers to
/// mean the same thing. A hardcoded -52 dBFS is only ever right for one setup.
///
/// So each finished night feeds a small controller: the gate moves toward whatever produces
/// the target number of events per hour, and the absolute floor follows the peaks this room
/// actually produces. Mirrors `calibrate()` in `public/analysis.js`, where the rules are
/// pinned by tests — including that it converges rather than oscillates.
enum Calibration {
    /// Nights of history to judge by: long enough to smooth one noisy night, short enough to
    /// follow a phone moved to the other side of the bed.
    static let window = 5
    /// Most the gate may move in one night. The clamp is what stops a party next door
    /// deafening the app for a week.
    static let maxStepDB = 2.0
    static let gateRange = 10.0 ... 26.0
    static let peakRange = -60.0 ... -30.0
    /// How far below the room's typical event peak the absolute floor sits.
    static let peakMarginDB = 12.0
    /// A ten-minute test says nothing about a night.
    static let minHours = 0.5

    struct NightStat: Codable {
        var hours: Double
        var events: Int
        var medianPeakDb: Double?
    }

    struct State: Codable {
        var gateDb = GateConfig().gateDB
        var minPeakDb = GateConfig().minPeakDB
        /// The one number a person should set.
        var targetPerHour = 4.0
        var history: [NightStat] = []
        var nights = 0
        var ratePerHour: Double?
        var why = "No nights yet — using the starting values."
    }

    // MARK: - Persistence

    private static let key = "sleeptracker.calibration"

    static var state: State {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(State.self, from: data)
            else { return State() }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// The gate settings tonight should run with.
    static func config() -> GateConfig {
        var config = GateConfig()
        config.gateDB = state.gateDb
        config.minPeakDB = state.minPeakDb
        return config
    }

    static func reset() {
        state = State()
    }

    static func setTarget(_ perHour: Double) {
        var next = state
        next.targetPerHour = max(1, min(30, perHour))
        apply(to: &next)
        state = next
    }

    // MARK: - Learning

    static func learn(from session: NightSession) {
        var next = state
        let peaks = session.events.map(\.peakDb).sorted()
        next.history.insert(NightStat(
            hours: session.wall / 3600,
            events: session.events.count,
            medianPeakDb: peaks.isEmpty ? nil : peaks[peaks.count / 2]
        ), at: 0)
        next.history = Array(next.history.prefix(14))
        apply(to: &next)
        state = next
    }

    private static func apply(to next: inout State) {
        let usable = next.history.filter { $0.hours >= minHours }.prefix(window)
        guard !usable.isEmpty else {
            next.nights = 0
            next.why = "No nights yet — using the starting values."
            return
        }

        let rates = usable.map { Double($0.events) / max($0.hours, 0.001) }.sorted()
        let rate = rates[rates.count / 2]

        // Proportional in octaves, so the response is the same whether the rate is four
        // times too high or four times too low.
        let error = rate > 0 ? log2(rate / next.targetPerHour) : -1
        let step = max(-maxStepDB, min(maxStepDB, error * 1.5))
        let moved = min(gateRange.upperBound, max(gateRange.lowerBound, next.gateDb + step))

        // The absolute floor follows what this room produces — the part that genuinely
        // cannot be guessed, being set by microphone gain and by distance from the bed.
        let peaks = usable.compactMap(\.medianPeakDb).sorted()
        if !peaks.isEmpty {
            let typical = peaks[peaks.count / 2]
            next.minPeakDb = min(
                peakRange.upperBound,
                max(peakRange.lowerBound, typical - peakMarginDB)
            )
        }

        let delta = moved - next.gateDb
        next.gateDb = moved
        next.nights = usable.count
        next.ratePerHour = rate
        next.why = describe(rate: rate, target: next.targetPerHour, delta: delta)
    }

    private static func describe(rate: Double, target: Double, delta: Double) -> String {
        let shown = String(format: "%.1f", rate)
        let goal = Int(target.rounded())
        if abs(delta) < 0.2 {
            return "\(shown)/h, about the target of \(goal) — holding."
        }
        return delta > 0
            ? "\(shown)/h against a target of \(goal) — listening less closely tonight."
            : "\(shown)/h against a target of \(goal) — listening more closely tonight."
    }
}
