import SwiftUI

struct AddArticleView: View {
    var onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 30, weight: .light)).foregroundStyle(ReedStyle.accent)
            VStack(alignment: .leading, spacing: 8) {
                Text("Add article.").font(.system(size: 30, design: .serif))
                Text("The article will be saved for offline reading.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                // A verbatim prompt, since a string literal would be parsed as Markdown and the URL styled as a link.
                TextField("Article link", text: $url, prompt: Text(verbatim: "https://example.com/an-interesting-article"))
                    .textFieldStyle(.plain).padding(13)
                    .background(ReedStyle.warm, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.12)))
                    .focused($focused).onSubmit(save)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #endif
                PasteButton(payloadType: String.self) { strings in
                    guard let string = strings.first else { return }
                    Task { @MainActor in url = string.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly).buttonBorderShape(.roundedRectangle(radius: 9)).controlSize(.large)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Keep Reed open while saving.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(32)
        #if os(macOS)
        .frame(width: 510)
        #endif
        .onAppear { focused = true }
    }

    private func save() {
        do { try onSave(url); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
