import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// The top of a sheet: an icon, a title ending in a full stop, and what the sheet is for.
struct SheetHeading: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(ReedStyle.accent)
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, design: .serif))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Links typed or pasted into a sheet, with a line beneath for what they were understood as or why they
/// failed. Return, or pasting whole links into the empty field, submits them; text that failed isn't
/// submitted again until it's changed. The prompt is verbatim, since
/// a string literal would be parsed as Markdown and a URL in it styled as a link.
struct LinkField: View {
    let prompt: String
    @Binding var text: String
    /// The text that couldn't be used, and why.
    var failure: (text: String, reason: String)?
    var detail: String?
    var focused: FocusState<Bool>.Binding
    var onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Link", text: $text, prompt: Text(verbatim: prompt), axis: .vertical)
                .font(.system(size: 17)).lineLimit(2...6)
                .warmField()
                .focused(focused).onSubmit { onSubmit(text) }
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                #endif
                .onChange(of: text) { old, new in
                    if failure?.text == new { return }
                    if new == old + "\n" { text = old; onSubmit(old) }
                    else if old.isEmpty, new.count > 1, Self.isWholeLinks(new) { onSubmit(new) }
                }
            if let failure, failure.text == text {
                Text(failure.reason).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Whether `text` is only whole links, as pasted rather than partly typed.
    static func isWholeLinks(_ text: String) -> Bool {
        let found = ArticleURL.links(in: text)
        return !found.isEmpty && found.allSatisfy { (try? ArticleURL.parse($0).host())?.contains(".") == true }
    }
}

/// Pastes text from the clipboard without the system asking first, trimmed.
struct SheetPasteButton: View {
    var onPaste: (String) -> Void

    var body: some View {
        PasteButton(payloadType: String.self) { strings in
            let text = strings.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in onPaste(text) }
        }
        .labelStyle(.titleAndIcon).tint(ReedStyle.accent)
    }
}

/// On iPhone, a sheet only as tall as what's in it.
private struct FittedSheet: ViewModifier {
    @State private var height: CGFloat = 300

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .presentationDetents([.height(height)])
        #else
        content
        #endif
    }
}

extension View {
    /// A text field drawn on the warm paper colour, as in Reed's sheets.
    func warmField() -> some View {
        textFieldStyle(.plain).padding(13)
            .background(ReedStyle.warm, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.12)))
    }

    func fittedSheet() -> some View { modifier(FittedSheet()) }

    /// A sheet's margins, and on the Mac its width.
    func sheetLayout() -> some View {
        #if os(macOS)
        padding(32).frame(width: 510)
        #else
        padding(32)
        #endif
    }
}

extension Binding {
    /// Whether an optional holds something, emptied when set to false, as an alert or dialog shown for it expects.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}
