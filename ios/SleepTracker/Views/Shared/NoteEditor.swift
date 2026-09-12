import SwiftUI

/// Sheet for writing the note on a marked event.
struct NoteEditor: View {
    let event: NightSession.EventRecord
    let sessionID: String
    @ObservedObject var store: NightsStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(event: NightSession.EventRecord, sessionID: String, store: NightsStore) {
        self.event = event
        self.sessionID = sessionID
        self.store = store
        _text = State(initialValue: event.note ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(Fmt.dateTimeLong.string(from: event.at)
                    + (event.topLabel.map { " · \($0.display)" } ?? ""))
                    .font(.rowMeta)
                    .foregroundStyle(Theme.textMuted)

                if let transcript = event.transcript, !transcript.isEmpty {
                    Text("“\(transcript)”").font(.callout).foregroundStyle(Theme.textSecondary)
                }

                TextField("What about this?", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(3 ... 8)
                    .padding(Layout.cardPadding)
                    .cardSurface()
                    .focused($focused)

                Spacer()
            }
            .padding(Layout.gutter)
            .spectrogramGround()
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setNote(sessionID: sessionID, eventIndex: event.index, note: text)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
