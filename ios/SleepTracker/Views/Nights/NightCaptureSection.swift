import SwiftUI

/// Whether the recorder itself behaved: the verdict, the background-capture evidence, the
/// counters, the full event list and the diagnostics log.
///
/// Collapsed by default and placed last. While the approach was unproven this was the whole
/// report; now it is what you open when something looks wrong.
struct NightCaptureSection: View {
    let session: NightSession
    @ObservedObject var player: EventPlayer
    @ObservedObject var store: NightsStore
    var onEditNote: (NightSession.EventRecord) -> Void

    @State private var expanded = false

    var body: some View {
        // One container, so the transition has a parent whose layout it can animate against.
        // Previously `body` returned the header and the block as two loose views, which left
        // the transition to animate inside whatever VStack happened to enclose it.
        VStack(alignment: .leading, spacing: Layout.section) {
            disclosure
            if expanded {
                detail
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Layout.section) {
            Verdict(title: verdictTitle, detail: verdictDetail, good: session.survived)
            backgroundEvidence
            tiles
            if session.envelope.count > 1 {
                SectionHeader("Loudness")
                EnvelopeChart(session: session)
            }
            eventList
            NightDiagnosticsSection(session: session)
        }
        .transition(.opacity)
    }

    private var disclosure: some View {
        Button {
            withAnimation(Motion.respecting(Motion.standard)) { expanded.toggle() }
        } label: {
            HStack {
                Text("Recording detail").font(.sectionTitle)
                if !session.survived, !session.tooShort {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.fine).foregroundStyle(Theme.gap)
                }
                Spacer()
                Image(systemName: "chevron.down").font(.fine)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.top, Layout.loose)
        }
        .buttonStyle(.plain)
    }

    // MARK: - The point of the whole exercise

    /// Whether capture kept running while the app was not in the foreground. On the web this
    /// was always zero; here it is the number that decides whether the approach works.
    private var backgroundEvidence: some View {
        let background = session.backgroundSeconds
        let events = session.backgroundEvents.count
        let worked = background > 5 && session.dead < 30

        return VStack(alignment: .leading, spacing: Layout.loose) {
            Text("BACKGROUND CAPTURE")
                .font(.metricLabel).tracking(0.4).foregroundStyle(Theme.textMuted)

            if background < 5 {
                Text("The app stayed in the foreground for this session, so it does not test "
                    + "anything. Start it, lock the phone, and leave it.")
                    .font(.explain).foregroundStyle(Theme.textSecondary)
            } else {
                Text(worked
                    ? "Recorded for \(background.short) with the app backgrounded, capturing "
                    + "\(events) event\(events == 1 ? "" : "s") in that time."
                    : "Spent \(background.short) backgrounded but lost \(session.dead.short) "
                    + "of audio — capture did not survive.")
                    .font(.explain)
                    .foregroundStyle(worked ? Theme.event : Theme.gap)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .card()
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            StatTile(
                label: "Wall clock",
                value: session.wall.clock,
                note: "\(Fmt.hourMinute.string(from: session.startedAt))"
                    + " → \(Fmt.hourMinute.string(from: session.endAt))"
            )
            StatTile(
                label: "Audio captured",
                value: session.audio.clock,
                note: session.wall > 0
                    ? String(
                        format: "%.2f%% of wall clock",
                        session.audio / session.wall * 100
                    )
                    : nil
            )
            StatTile(
                label: "Dead time",
                value: session.dead.short,
                note: session.realGaps.isEmpty
                    ? "no gaps"
                    :
                    "\(session.realGaps.count) gaps, worst \((session.worstGapMs / 1000).short)",
                tint: session.dead > 30 ? Theme.gap : Theme.textPrimary
            )
            StatTile(
                label: "Backgrounded",
                value: session.backgroundSeconds.short,
                note: "\(session.backgroundEvents.count) events while locked",
                tint: session.backgroundSeconds > 5 ? Theme.event : Theme.textPrimary
            )
            StatTile(
                label: "Noise floor",
                value: "\(Int(session.floorDb)) dB",
                note: "gate at \(Int(session.thresholdDb)) dB"
            )
            StatTile(
                label: "Kept",
                value: session.keptAudio.short,
                note: "\(session.events.count) events · "
                    + String(format: "%.1f%% of the audio", session.keptFraction * 100)
            )
            if session.interruptions > 0 {
                StatTile(
                    label: "Interruptions",
                    value: "\(session.interruptions)",
                    note: "calls, alarms, media resets",
                    tint: Theme.gap
                )
            }
            if let rejected = session.rejectedEvents, rejected > 0 {
                StatTile(
                    label: "Not worth a file",
                    value: "\(rejected)",
                    note: "too short or too quiet for the gate"
                )
            }
            if session.droppedEvents > 0 {
                StatTile(
                    label: "Dropped",
                    value: "\(session.droppedEvents)",
                    note: "audio aged out of the ring",
                    tint: Theme.gap
                )
            }
        }
    }

    @ViewBuilder
    private var eventList: some View {
        SectionHeader("All events (\(session.events.count))")
        if session.events.isEmpty {
            Text("Nothing crossed the gate. Either the room was quiet, or capture never ran "
                + "— the dead-time tile above says which.")
                .font(.explain).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .card()
        } else {
            EventList(
                events: session.events,
                sessionID: session.id,
                player: player,
                store: store,
                onEditNote: onEditNote
            )
        }
    }

    // MARK: -

    private var verdictTitle: String {
        if session.tooShort {
            return "Too short to judge"
        }
        if session.survived {
            return "Survived — capture ran end to end"
        }
        if session.diedAndStayedDead {
            let at = Date(timeIntervalSince1970: (session.lastFrameAtMs ?? session.t0) / 1000)
            return "Capture died at \(Fmt.time.string(from: at))"
        }
        return "Lost \(session.dead.short) of audio"
    }

    private var verdictDetail: String {
        if session.tooShort {
            return "Run it for longer than a minute before drawing any conclusion."
        }
        if session.survived {
            return "Every second of wall clock is accounted for in captured audio."
        }
        if session.diedAndStayedDead {
            let ran = session.trailingDead > 0 ? session.wall - session.trailingDead : session.wall
            return "It ran for \(ran.short), then stopped for the remaining "
                + "\(session.trailingDead.short) and never resumed."
        }
        return "Capture stopped and restarted. The diagnostics below show what coincided."
    }
}
