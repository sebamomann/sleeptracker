import SwiftUI

struct SessionDetailView: View {
    @State private var session: NightSession
    @StateObject private var player = EventPlayer()
    @State private var showDiagnostics = false
    @State private var classifying = false

    init(session: NightSession) { _session = State(initialValue: session) }

    private var store: SessionStore { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Verdict(title: verdictTitle, detail: verdictDetail, good: session.survived)
                backgroundEvidence
                tiles
                composition
                if session.envelope.count > 1 {
                    SectionHeader(text: "The night")
                    EnvelopeChart(session: session)
                }
                events
                diagnostics
                exportRow
            }
            .padding(16)
        }
        .background(Theme.surface0)
        .navigationTitle(Self.dayFormatter.string(from: session.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }

    // MARK: - The point of the whole exercise

    /// Whether capture kept running while the app was not in the foreground. On the web this
    /// was always zero; here it is the number that decides whether the approach works.
    private var backgroundEvidence: some View {
        let bg = session.backgroundSeconds
        let bgEvents = session.backgroundEvents.count
        let worked = bg > 5 && session.dead < 30

        return VStack(alignment: .leading, spacing: 8) {
            Text("BACKGROUND CAPTURE")
                .font(.caption2.weight(.medium)).tracking(0.4)
                .foregroundStyle(Theme.textMuted)

            if bg < 5 {
                Text("The app stayed in the foreground for this session, so it does not test "
                     + "anything. Start it, lock the phone, and leave it.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            } else {
                Text(worked
                     ? "Recorded for \(bg.short) with the app backgrounded, capturing "
                       + "\(bgEvents) event\(bgEvents == 1 ? "" : "s") in that time."
                     : "Spent \(bg.short) backgrounded but lost \(session.dead.short) of audio "
                       + "— capture did not survive.")
                    .font(.subheadline)
                    .foregroundStyle(worked ? Theme.event : Theme.gap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }

    // MARK: - What the night was made of

    @ViewBuilder
    private var composition: some View {
        let breakdown = session.byLabel
        let unlabelled = session.unlabelledEvents

        if !breakdown.isEmpty || !unlabelled.isEmpty {
            SectionHeader(text: "What it heard")
            VStack(alignment: .leading, spacing: 9) {
                if breakdown.isEmpty {
                    Text("Nothing is labelled yet.")
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                } else {
                    let longest = breakdown.first?.seconds ?? 1
                    ForEach(breakdown, id: \.label) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.display).font(.caption.weight(.medium))
                                Spacer()
                                Text("\(row.count) · \(row.seconds.short)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.textMuted)
                            }
                            // Bar length is time, not count: forty one-second ticks matter
                            // less than four thirty-second episodes.
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.signal)
                                    .frame(width: max(3, geo.size.width * row.seconds / longest))
                            }
                            .frame(height: 5)
                        }
                    }
                }

                if !unlabelled.isEmpty {
                    Divider().overlay(Theme.line)
                    Button {
                        classifyMissing(unlabelled)
                    } label: {
                        HStack(spacing: 7) {
                            if classifying { ProgressView().controlSize(.mini) }
                            Text(classifying
                                 ? "Classifying…"
                                 : "Classify \(unlabelled.count) unlabelled event\(unlabelled.count == 1 ? "" : "s")")
                                .font(.caption.weight(.medium))
                        }
                    }
                    .disabled(classifying)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        }
    }

    /// Label events recorded before classification existed, or missed at the time.
    private func classifyMissing(_ pending: [NightSession.EventRecord]) {
        classifying = true
        let id = session.id
        let store = self.store
        Task.detached(priority: .utility) {
            var labelled: [Int: [SoundLabel]] = [:]
            for e in pending {
                let url = store.url(forEvent: e, in: id)
                let labels = EventClassifier.shared.classify(url: url)
                if !labels.isEmpty { labelled[e.index] = labels }
            }
            // Frozen before crossing to the main actor: a var captured by a concurrently
            // executing closure is a data race, and an error under Swift 6.
            let results = labelled
            await MainActor.run {
                for (index, labels) in results {
                    if let i = session.events.firstIndex(where: { $0.index == index }) {
                        session.events[i].labels = labels
                    }
                }
                if session.knownLabels == nil {
                    session.knownLabels = EventClassifier.shared.knownLabels
                }
                try? store.save(session)
                classifying = false
            }
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            StatTile(label: "Wall clock", value: session.wall.clock,
                     note: "\(Self.timeFormatter.string(from: session.startedAt)) → \(Self.timeFormatter.string(from: session.endAt))")
            StatTile(label: "Audio captured", value: session.audio.clock,
                     note: session.wall > 0
                        ? String(format: "%.2f%% of wall clock", session.audio / session.wall * 100)
                        : nil)
            StatTile(label: "Dead time", value: session.dead.short,
                     note: session.realGaps.isEmpty
                        ? "no gaps"
                        : "\(session.realGaps.count) gaps, worst \((session.worstGapMs / 1000).short)",
                     tint: session.dead > 30 ? Theme.gap : Theme.textPrimary)
            StatTile(label: "Backgrounded", value: session.backgroundSeconds.short,
                     note: "\(session.backgroundEvents.count) events while locked",
                     tint: session.backgroundSeconds > 5 ? Theme.event : Theme.textPrimary)
            StatTile(label: "Noise floor", value: "\(Int(session.floorDb)) dB",
                     note: "gate at \(Int(session.thresholdDb)) dB")
            StatTile(label: "Kept", value: session.keptAudio.short,
                     note: "\(session.events.count) events · "
                         + String(format: "%.1f%% of the audio", session.keptFraction * 100))
            if session.interruptions > 0 {
                StatTile(label: "Interruptions", value: "\(session.interruptions)",
                         note: "calls, alarms, media resets", tint: Theme.gap)
            }
            if session.droppedEvents > 0 {
                StatTile(label: "Dropped", value: "\(session.droppedEvents)",
                         note: "audio aged out of the ring", tint: Theme.gap)
            }
        }
    }

    // MARK: - Events

    @ViewBuilder
    private var events: some View {
        SectionHeader(text: "Events (\(session.events.count))")
        if session.events.isEmpty {
            Text("Nothing crossed the gate. Either the room was quiet, or capture never ran "
                 + "— the dead-time tile above says which.")
                .font(.footnote).foregroundStyle(Theme.textMuted)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(spacing: 0) {
                ForEach(session.events) { e in
                    Button {
                        player.toggle(url: store.url(forEvent: e, in: session.id), index: e.index)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: player.playingIndex == e.index
                                  ? "stop.circle.fill" : "play.circle")
                                .font(.title3)
                                .foregroundStyle(Theme.event)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 7) {
                                    Text(Self.secondsFormatter.string(from: e.at))
                                        .font(.callout.monospaced())
                                        .foregroundStyle(Theme.textPrimary)
                                    if let l = e.topLabel {
                                        Text(l.display)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(Theme.signal)
                                        Text("\(Int(l.confidence * 100))%")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                                Text("\(String(format: "%.1f", e.durationS))s · peak \(Int(e.peakDb)) dB")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            if session.backgroundEvents.contains(e) {
                                Text("locked")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Theme.event.opacity(0.18), in: Capsule())
                                    .foregroundStyle(Theme.event)
                            }
                        }
                        .padding(.vertical, 9).padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                    if e.index != session.events.last?.index {
                        Divider().overlay(Theme.line)
                    }
                }
            }
            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnostics: some View {
        Button { showDiagnostics.toggle() } label: {
            HStack {
                Text("Diagnostics (\(session.marks.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.top, 8)
        }
        .buttonStyle(.plain)

        if showDiagnostics {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(session.marks) { m in
                    let at = Date(timeIntervalSince1970: m.at / 1000)
                    HStack(alignment: .top, spacing: 10) {
                        Text(Self.secondsFormatter.string(from: at))
                            .font(.caption2.monospaced()).foregroundStyle(Theme.textMuted)
                        Text(at.timeIntervalSince(session.startedAt).clock)
                            .font(.caption2.monospaced()).foregroundStyle(Theme.textMuted)
                        Text(m.what)
                            .font(.caption2.monospaced())
                            .foregroundStyle(m.what.uppercased() == m.what
                                             ? Theme.gap : Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.vertical, 5).padding(.horizontal, 12)
                }
                Text("device: \(session.device.model) · iOS \(session.device.systemVersion) · app \(session.device.appVersion)"
                     + " · classifier labels: \(session.knownLabels?.count ?? 0)")
                    .font(.caption2.monospaced()).foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 8).padding(.horizontal, 12)
            }
            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        }
    }

    private var exportRow: some View {
        let json = store.directory(for: session.id).appendingPathComponent("session.json")
        return HStack(spacing: 10) {
            ShareLink(item: json) {
                Label("Share session.json", systemImage: "square.and.arrow.up")
                    .font(.subheadline)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: store.bytes(of: session.id),
                                            countStyle: .file))
                .font(.caption.monospaced()).foregroundStyle(Theme.textMuted)
        }
        .padding(.top, 6)
    }

    // MARK: -

    private var verdictTitle: String {
        if session.tooShort { return "Too short to judge" }
        if session.survived { return "Survived — capture ran end to end" }
        if session.diedAndStayedDead {
            let at = Date(timeIntervalSince1970: (session.lastFrameAtMs ?? session.t0) / 1000)
            return "Capture died at \(Self.secondsFormatter.string(from: at))"
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
            return "It ran for \((session.trailingDead > 0 ? session.wall - session.trailingDead : session.wall).short), "
                 + "then stopped for the remaining \(session.trailingDead.short) and never resumed."
        }
        return "Capture stopped and restarted. The diagnostics below show what coincided with it."
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let secondsFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}
