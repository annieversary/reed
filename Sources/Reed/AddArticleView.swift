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
                Text("Keep a good read.").font(.system(size: 30, design: .serif))
                Text("Paste an article link. Reed will save a clean copy and its images for offline reading.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("https://example.com/an-interesting-article", text: $url)
                .textFieldStyle(.plain).padding(13)
                .background(ReedStyle.warm, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.12)))
                .focused($focused).onSubmit(save)
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                #endif
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Keep Reed open while saving.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save article", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
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
