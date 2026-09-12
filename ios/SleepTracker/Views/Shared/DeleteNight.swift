import SwiftUI

/// What deleting a night would actually destroy.
///
/// Deletion removes the directory: the session and every recording in it, with no undo and
/// no copy anywhere else, since nothing leaves the phone. So the confirmation names what
/// goes — and calls out marked events specifically, because those are the ones deliberately
/// kept and the worst to lose by a mis-swipe.
struct NightDeletion: Identifiable {
    let session: NightSession
    var id: String { session.id }

    var title: String {
        "Delete \(Fmt.dayTime.string(from: session.startedAt))?"
    }

    var detail: String {
        var parts = ["\(session.events.count) recording\(session.events.count == 1 ? "" : "s")"]
        let marked = session.markedEvents.count
        if marked > 0 {
            parts.append("\(marked) of them marked")
        }
        let bytes = SessionStore.shared.bytes(of: session.id)
        if bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ") + ". This cannot be undone."
    }
}

extension View {
    /// Attaches the delete confirmation. Shared so a swipe in the list and the button on a
    /// night's own screen ask the same question and read the same way.
    func confirmNightDeletion(
        _ pending: Binding<NightDeletion?>,
        onConfirm: @escaping (NightDeletion) -> Void
    ) -> some View {
        confirmationDialog(
            pending.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { presented in
                    if !presented {
                        pending.wrappedValue = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { deletion in
            Button("Delete night", role: .destructive) { onConfirm(deletion) }
            Button("Keep", role: .cancel) {}
        } message: { deletion in
            Text(deletion.detail)
        }
    }
}
