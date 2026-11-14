import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// Something just done that can be taken back for a few seconds, offered at the bottom of the window.
@MainActor @Observable final class UndoToast {
    struct Offer: Identifiable {
        let id = UUID()
        let message: String
        let undo: () -> Void
        /// Lets it stand, once it can no longer be undone.
        let commit: () -> Void
    }

    private(set) var offer: Offer?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// Offers to undo something, letting whatever was offered before stand.
    func offer(_ message: String, undo: @escaping () -> Void, commit: @escaping () -> Void = {}) {
        let previous = offer
        let offer = Offer(message: message, undo: undo, commit: commit)
        withAnimation(.snappy(duration: 0.25)) { self.offer = offer }
        previous?.commit()
        expiry?.cancel()
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            self?.dismiss()
        }
    }

    func undo() {
        guard let offer else { return }
        expiry?.cancel()
        withAnimation(.snappy(duration: 0.25)) { self.offer = nil }
        offer.undo()
    }

    func dismiss() {
        guard let offer else { return }
        expiry?.cancel()
        withAnimation(.snappy(duration: 0.25)) { self.offer = nil }
        offer.commit()
    }

    /// Marks those not finished yet as finished, offering to undo it.
    func markFinished(_ readables: [any Readable], in library: Library) {
        let mark = library.markFinished(readables)
        guard !mark.isEmpty else { return }
        let message = readables.count == 1 ? "Marked “\(readables[0].title)” finished" : "Marked \(readables.count) finished"
        offer(message) { library.undo(mark) }
    }

    /// Finishes it, offering to undo that, or marks it unread.
    func toggleRead(_ readable: any Readable, in library: Library) {
        if readable.isRead { library.toggleRead(readable) } else { markFinished([readable], in: library) }
    }
}

struct UndoToastView: View {
    let toast: UndoToast

    var body: some View {
        if let offer = toast.offer {
            HStack(spacing: 14) {
                Text(offer.message).lineLimit(1).truncationMode(.middle)
                Button("Undo") { toast.undo() }
                    .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(ReedStyle.accent)
                Button("Dismiss", systemImage: "xmark") { toast.dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary).imageScale(.small)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(offer.id)
        }
    }
}
