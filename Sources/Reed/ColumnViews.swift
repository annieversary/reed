import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// The title at the top of a list column on the Mac, with what it holds below and its buttons beside it.
/// On iOS the title is in the navigation bar instead; see `columnTitle(_:actions:)`.
struct ColumnHeader<Buttons: View, Below: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var buttons: Buttons
    @ViewBuilder var below: Below

    init(title: String, subtitle: String, @ViewBuilder buttons: () -> Buttons, @ViewBuilder below: () -> Below = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.buttons = buttons()
        self.below = below()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 26, design: .serif))
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    buttons
                }
                below
            }
            .padding(20)
            Divider()
        }
    }
}

/// A round button in a column's header.
struct HeaderButton: View {
    let help: String
    /// Spoken, when `help` says more than VoiceOver should, such as a shortcut.
    var label: String?
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 32, height: 32)
        }
        .buttonStyle(.reedSecondaryIcon)
        .help(help).accessibilityLabel(label ?? help)
    }
}

/// What the library is busy with, such as saving an article, at the foot of a column.
struct ActivityFooter: View {
    let library: Library

    var body: some View {
        if let activity = library.activity {
            Divider()
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text(activity).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(14)
        }
    }
}

extension View {
    /// Names a list column. The Mac shows the name in the column's header rather than the toolbar;
    /// iOS shows it in the navigation bar, with `actions` beside it.
    func columnTitle<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        #if os(macOS)
        navigationTitle(title).toolbar(removing: .title)
        #else
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text(title).font(.system(size: 19, design: .serif)) }
                ToolbarItemGroup(placement: .primaryAction) { actions() }
            }
        #endif
    }
}

extension View {
    /// Greys a card out the further its article has been read, fully once finished, and a little once opened.
    func readFading(_ article: Article?) -> some View {
        let read = article.map { $0.isRead ? 1 : max($0.progress, $0.openedAt == nil ? 0 : 0.2) } ?? 0
        return saturation(1 - read).opacity(1 - 0.5 * read)
    }
}
