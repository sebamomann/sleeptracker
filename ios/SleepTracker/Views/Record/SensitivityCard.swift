import SwiftUI

/// What the app has learned about this room, and the one dial worth having.
///
/// The thresholds move on their own after every night, which is only reassuring if you can
/// see them do it — an app that silently changes how much it records is indistinguishable
/// from one that is broken.
struct SensitivityCard: View {
    @State private var state = Calibration.state

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.loose) {
            Text("Listening \(Int(state.gateDb)) dB above the room, ignoring anything under "
                + "\(Int(state.minPeakDb)) dBFS.")
                .font(.explain)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(state.why)
                .font(.rowMeta)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.line)

            Stepper(value: target, in: 1 ... 20, step: 1) {
                Text("Aim for \(Int(state.targetPerHour)) events an hour")
                    .font(.rowLabel)
            }

            Text(state.nights == 0
                ? "It will start adjusting after the first full night."
                : "Learned from \(state.nights) night\(state.nights == 1 ? "" : "s"). "
                + "Moves at most 2 dB a night, so one noisy night cannot swing it.")
                .font(.fine)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if state.nights > 0 {
                Button("Forget what it learned") {
                    Calibration.reset()
                    state = Calibration.state
                }
                .font(.fine)
            }
        }
        .card()
        .onAppear { state = Calibration.state }
    }

    private var target: Binding<Double> {
        Binding(
            get: { state.targetPerHour },
            set: { newValue in
                Calibration.setTarget(newValue)
                state = Calibration.state
            }
        )
    }
}
