import SwiftUI

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

/// An address typed or pasted into a sheet. The prompt is verbatim, since a string literal would be parsed
/// as Markdown and a URL in it styled as a link.
struct AddressField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(label, text: $text, prompt: Text(verbatim: prompt))
                .warmField()
                .focused(focused).onSubmit(onSubmit)
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                #endif
            PasteButton(payloadType: String.self) { strings in
                guard let string = strings.first else { return }
                Task { @MainActor in text = string.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .labelStyle(.iconOnly).buttonBorderShape(.roundedRectangle(radius: 9)).controlSize(.large)
        }
    }
}

extension View {
    /// A text field drawn on the warm paper colour, as in Reed's sheets.
    func warmField() -> some View {
        textFieldStyle(.plain).padding(13)
            .background(ReedStyle.warm, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.12)))
    }

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
