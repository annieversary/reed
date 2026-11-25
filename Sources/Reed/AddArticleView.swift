import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// Saves the links pasted or typed in. Pasting a link into the empty field saves it straight away.
struct AddArticleView: View {
    var onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    /// Why the links in the field couldn't be saved, until they're changed.
    @State private var failure: (text: String, reason: String)?
    @FocusState private var focused: Bool
    #if os(iOS)
    @State private var height: CGFloat = 300
    #endif

    private var links: [String] { ArticleURL.links(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add article.").font(.system(size: 26, design: .serif))
            VStack(alignment: .leading, spacing: 8) {
                TextField("Article link", text: $text, prompt: Text(verbatim: "Link to an article"), axis: .vertical)
                    .font(.system(size: 17)).lineLimit(2...6)
                    .warmField()
                    .focused($focused).onSubmit { save(text) }
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #endif
                    .onChange(of: text) { old, new in
                        if failure?.text == new { return }
                        if new == old + "\n" { text = old; save(old) }
                        else if old.isEmpty, new.count > 1, isLinks(new) { save(new) }
                    }
                if let failure, failure.text == text {
                    Text(failure.reason).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if let sites {
                    Text(sites).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack {
                if text.isEmpty {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in save(strings.joined(separator: "\n")) }
                    }
                    .labelStyle(.titleAndIcon).tint(ReedStyle.accent)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(links.count > 1 ? "Save \(links.count)" : "Save") { save(text) }
                    .buttonStyle(.borderedProminent).tint(ReedStyle.accent).keyboardShortcut(.defaultAction)
                    .disabled(links.isEmpty)
            }
            .controlSize(.large)
        }
        .sheetLayout()
        #if os(macOS)
        .onAppear { focused = true }
        #else
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationDetents([.height(height)])
        #endif
    }

    /// The sites of the links in the field, so a mistyped one shows before it's saved.
    private var sites: String? {
        let hosts = links.compactMap { try? ArticleURL.parse($0).host() }
        guard hosts.count == links.count, let first = hosts.first else { return nil }
        let unique = hosts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return hosts.count == 1 ? first : "\(hosts.count) links from \(unique.joined(separator: ", "))"
    }

    /// Whether `text` is only whole links, as pasted rather than partly typed.
    private func isLinks(_ text: String) -> Bool {
        let found = ArticleURL.links(in: text)
        return !found.isEmpty && found.allSatisfy { (try? ArticleURL.parse($0).host())?.contains(".") == true }
    }

    /// Saves each link in `input`, leaving any that couldn't be saved in the field with the reason.
    private func save(_ input: String) {
        let found = ArticleURL.links(in: input)
        guard !found.isEmpty else { return }
        var failed: [String] = []
        var firstError: Error?
        for link in found {
            do { try onSave(link) }
            catch { failed.append(link); firstError = firstError ?? error }
        }
        guard let firstError else { dismiss(); return }
        text = failed.joined(separator: "\n")
        failure = (text, firstError.localizedDescription)
    }
}
