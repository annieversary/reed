import SwiftUI

struct AddArticleView: View {
    var onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeading(symbol: "tray.and.arrow.down", title: "Add article.", detail: "The article will be saved for offline reading.")
            AddressField(label: "Article link", prompt: "https://example.com/an-interesting-article", text: $url, focused: $focused, onSubmit: save)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Keep Reed open while saving.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheetLayout()
        .onAppear { focused = true }
    }

    private func save() {
        do { try onSave(url); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
