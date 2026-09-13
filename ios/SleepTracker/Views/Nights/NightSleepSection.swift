import SwiftUI

/// Sleep as far as sound can tell.
///
/// Everything here is an estimate from when noises happened — moving versus still, which is
/// roughly what actigraphy measures. It is deliberately not a hypnogram: there are no
/// stages, because a microphone cannot see brain or eye activity, and inventing them would
/// make the rest of the report untrustworthy too.
struct NightSleepSection: View {
    let session: NightSession

    var body: some View {
        let sleep = SleepTimeline.estimate(for: session)
        if !sleep.epochs.isEmpty {
            SectionHeader("Sleep")
            VStack(alignment: .leading, spacing: Layout.loose) {
                if sleep.settled {
                    headline(sleep)
                    strip(sleep)
                    figures(sleep)
                } else {
                    Text("Never settled for long enough to call it sleep — there was activity "
                        + "throughout. If that is wrong, the gate is probably too sensitive.")
                        .font(.explain)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Estimated from sound alone: quiet reads as asleep, movement as restless, "
                    + "sustained activity or talking as awake. Not sleep stages — those need "
                    + "brain activity, which a microphone cannot hear.")
                    .font(.fine)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .card()
        }
    }

    private func headline(_ sleep: SleepTimeline.Estimate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sleep.asleepSeconds.short)
                .font(.displayValue)
                .foregroundStyle(Theme.textPrimary)
            Text("asleep of \(sleep.inBedSeconds.short)")
                .font(.rowLabel)
                .foregroundStyle(Theme.textMuted)
        }
    }

    /// One mark per five minutes, in order. Reads as the shape of the night rather than as
    /// a chart to be measured off.
    private func strip(_ sleep: SleepTimeline.Estimate) -> some View {
        HStack(spacing: 1) {
            ForEach(sleep.epochs) { epoch in
                Rectangle()
                    .fill(colour(epoch.state))
                    .frame(height: height(epoch.state))
                    .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 26, alignment: .bottom)
        .padding(.vertical, 2)
    }

    private func figures(_ sleep: SleepTimeline.Estimate) -> some View {
        let onset = session.start.addingTimeInterval(sleep.onsetS ?? 0)
        let wake = session.start.addingTimeInterval(sleep.finalWakeS ?? 0)
        return VStack(alignment: .leading, spacing: 3) {
            line("Settled", Fmt.hourMinute.string(from: onset))
            line("Up", Fmt.hourMinute.string(from: wake))
            line(
                "Woke",
                sleep.awakenings == 0
                    ? "not that sound could tell"
                    : "\(sleep.awakenings) time\(sleep.awakenings == 1 ? "" : "s")"
            )
            line("Settled time", "\(Int((sleep.efficiency * 100).rounded()))% of the night")
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.rowMeta).foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value).font(.rowMeta).foregroundStyle(Theme.textSecondary)
        }
    }

    private func colour(_ state: SleepTimeline.State) -> Color {
        switch state {
        case .asleep: Theme.surface2
        case .restless: Theme.spectrumCyan.opacity(0.75)
        case .awake: Theme.spectrumAmber
        }
    }

    private func height(_ state: SleepTimeline.State) -> Double {
        switch state {
        case .asleep: 8
        case .restless: 16
        case .awake: 26
        }
    }
}
