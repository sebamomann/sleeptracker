import Foundation

/// Near-silent stretches bracketed by sound — pauses in an ongoing episode.
///
/// The rules are pinned by `QuietGapsTests`.
///
/// This is the inverse of the gate, and needs different rules: plain silence is
/// uninformative, since most of a quiet night is silence. A run only qualifies when sound
/// stops right at its start and resumes right at its end, and when it is short enough to be
/// an interruption rather than simply a quiet room.
///
/// An observational signal, not a diagnosis. A fan, rolling over, or breathing quietly all
/// look identical from here.
enum QuietGaps {
    static let minSeconds = 10.0
    static let maxSeconds = 90.0
    static let marginDB = 4.0
    static let adjoinSeconds = 5.0

    static func find(in session: NightSession) -> [NightSession.QuietGap] {
        let envelope = session.envelope
        let events = session.events
        guard !envelope.isEmpty, !events.isEmpty else { return [] }

        let quietBelow = session.floorDb + marginDB
        var gaps: [NightSession.QuietGap] = []
        var runStart: Int?

        func closeRun(at end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let length = Double(end - start)
            // The upper bound is what separates a pause from plain quiet: the gap IS the
            // space between two events, so adjacency alone can never rule out the hours
            // between one episode and the next.
            guard length >= minSeconds, length <= maxSeconds else { return }
            let stopped = events.contains { abs($0.endS - Double(start)) <= adjoinSeconds }
            let resumed = events.contains { abs($0.startS - Double(end)) <= adjoinSeconds }
            guard stopped, resumed else { return }
            gaps.append(.init(startS: Double(start), endS: Double(end), durationS: length))
        }

        for i in envelope.indices {
            let peak = envelope[i].count > 1 ? envelope[i][1] : -100
            if peak < quietBelow {
                if runStart == nil {
                    runStart = i
                }
            } else {
                closeRun(at: i)
            }
        }
        closeRun(at: envelope.count)
        return gaps
    }
}
