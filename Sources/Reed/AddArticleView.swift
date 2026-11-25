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

    private var links: [String] { ArticleURL.links(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add article.").font(.system(size: 26, design: .serif))
            LinkField(prompt: "Link to an article", text: $text, failure: failure, detail: sites, focused: $focused, onSubmit: save)
            HStack {
                if text.isEmpty { SheetPasteButton(onPaste: save) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(links.count > 1 ? "Save \(links.count)" : "Save") { save(text) }
                    .buttonStyle(.borderedProminent).tint(ReedStyle.accent).keyboardShortcut(.defaultAction)
                    .disabled(links.isEmpty)
            }
            .controlSize(.large)
        }
        .sheetLayout()
        .fittedSheet()
        #if os(macOS)
        .onAppear { focused = true }
        #endif
    }

    /// The sites of the links in the field, so a mistyped one shows before it's saved.
    private var sites: String? {
        let hosts = links.compactMap { try? ArticleURL.parse($0).host() }
        guard hosts.count == links.count, let first = hosts.first else { return nil }
        let unique = hosts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return hosts.count == 1 ? first : "\(hosts.count) links from \(unique.joined(separator: ", "))"
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
