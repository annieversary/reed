import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// Everything being saved to the library: what's being saved now and how far along, what's waiting its turn,
/// what couldn't be saved, and what was saved lately.
struct DownloadsView: View {
    let library: Library
    @Binding var selection: UUID?
    var onDeleteArticle: (Article) -> Void
    var onDeleteBook: (Book) -> Void

    private enum Item: Identifiable {
        case article(Article), book(Book)
        var id: UUID {
            switch self {
            case .article(let article): article.id
            case .book(let book): book.id
            }
        }
    }

    var body: some View {
        let saving = library.saving
        let current = saving.flatMap { item(withID: $0.id) }
        let waiting = library.waiting
        let upNext = waiting.articles.map(Item.article) + waiting.books.map(Item.book)
        let failed = library.articles.filter { $0.state == .failed }.map(Item.article)
            + library.books.filter { $0.state == .failed }.map(Item.book)
        let recent = library.articles.filter { $0.state.isReadable && $0.downloadedAt != nil }
            .sorted { $0.downloadedAt! > $1.downloadedAt! }.prefix(10)
        VStack(spacing: 0) {
            #if os(macOS)
            ColumnHeader(title: "Downloads", subtitle: Self.summary(saving: current != nil, waiting: upNext.count, failed: failed.count)) {}
            #endif
            List(selection: $selection) {
                #if os(iOS)
                Text(Self.summary(saving: current != nil, waiting: upNext.count, failed: failed.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                #endif
                if let saving, let current {
                    Section {
                        row(current) { SavingRow(item: current, progress: saving) }
                    } header: { header("NOW") }
                }
                if !upNext.isEmpty {
                    Section {
                        ForEach(Array(upNext.enumerated()), id: \.element.id) { index, item in
                            row(item) {
                                ItemSummary(item: item, detail: waitingMessage(of: item)) {
                                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } header: { header("UP NEXT") }
                }
                if !failed.isEmpty {
                    Section {
                        ForEach(failed) { item in
                            row(item) {
                                ItemSummary(item: item, detail: failureMessage(of: item)) {
                                    Button("Retry", systemImage: "arrow.clockwise") { retry(item) }
                                        .labelStyle(.iconOnly).buttonStyle(.reedSecondaryIcon).controlSize(.small)
                                        .help("Try saving it again")
                                }
                            }
                        }
                    } header: { header("COULDN'T SAVE") }
                }
                if !recent.isEmpty {
                    Section {
                        ForEach(recent) { article in
                            row(.article(article)) {
                                ItemSummary(item: .article(article), detail: Self.saved(article)) {
                                    if article.state == .partial {
                                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                                            .help(DownloadState.partial.label)
                                    }
                                }
                            }
                        }
                    } header: { header("RECENTLY SAVED") }
                }
            }
            .listStyle(.plain)
            .animation(.snappy(duration: 0.25), value: saving)
            .overlay {
                if current == nil && upNext.isEmpty && failed.isEmpty && recent.isEmpty {
                    Text("Nothing saved yet.").font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
                }
            }
        }
        .columnTitle("Downloads")
    }

    private func item(withID id: UUID) -> Item? {
        if let article = library.articles.first(where: { $0.id == id }) { return .article(article) }
        return library.books.first { $0.id == id }.map(Item.book)
    }

    /// A row that opens what it shows: an article in the reader, a book on its shelf.
    @ViewBuilder private func row(_ item: Item, @ViewBuilder content: () -> some View) -> some View {
        let insets = EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12)
        switch item {
        case .article(let article):
            content()
                .listLink(value: article.id, insets: insets)
                .contextMenu {
                    if article.state == .failed || article.state == .partial {
                        Button("Retry Download", systemImage: "arrow.clockwise") { library.retry(article) }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { onDeleteArticle(article) }
                }
        case .book(let book):
            content()
                .contentShape(Rectangle())
                .onTapGesture { NotificationCenter.default.post(name: .reedShowBook, object: [book.id]) }
                .listRowSeparator(.hidden)
                .listRowInsets(insets)
                .contextMenu {
                    if book.state == .failed { Button("Retry", systemImage: "arrow.clockwise") { library.retry(book) } }
                    if book.state != .downloading {
                        Button("Delete", systemImage: "trash", role: .destructive) { onDeleteBook(book) }
                    }
                }
        }
    }

    private func retry(_ item: Item) {
        switch item {
        case .article(let article): library.retry(article)
        case .book(let book): library.retry(book)
        }
    }

    private func failureMessage(of item: Item) -> String? {
        switch item {
        case .article(let article): article.failureMessage
        case .book(let book): book.failureMessage
        }
    }

    private func waitingMessage(of item: Item) -> String? {
        guard case .article(let article) = item, article.isWaitingToRetry else { return nil }
        return article.failureMessage
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).tracking(1.7).foregroundStyle(.secondary)
    }

    private static func saved(_ article: Article) -> String? {
        article.downloadedAt.map { "Saved \($0.formatted(.relative(presentation: .named)))" }
    }

    private static func summary(saving: Bool, waiting: Int, failed: Int) -> String {
        var parts: [String] = []
        if saving { parts.append("Saving 1") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if failed > 0 { parts.append("\(failed) couldn't be saved") }
        return parts.isEmpty ? "All caught up" : parts.joined(separator: " · ")
    }

    /// Where it's from, its title, and a line about how it stands, with `accessory` beside them.
    private struct ItemSummary<Accessory: View>: View {
        let item: Item
        var detail: String?
        @ViewBuilder var accessory: Accessory

        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source).font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(ReedStyle.accent)
                    Text(title).font(.system(size: 15, weight: .medium, design: .serif)).lineLimit(2)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                accessory.font(.system(size: 11))
            }
            .padding(.vertical, 8).padding(.horizontal, 7)
        }

        private var source: String {
            switch item {
            case .article(let article): article.domain
            case .book: "BOOK"
            }
        }

        private var title: String {
            switch item {
            case .article(let article): article.title
            case .book(let book): book.title
            }
        }
    }

    /// The one being saved: its step, and a bar while the step can tell how far it has got.
    private struct SavingRow: View {
        let item: Item
        let progress: SaveProgress

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ItemSummary(item: item) {}
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).tint(ReedStyle.accent)
                            .animation(.easeOut(duration: 0.3), value: fraction)
                    }
                    HStack(spacing: 6) {
                        if progress.fraction == nil { ProgressView().controlSize(.mini) }
                        Text(progress.step).lineLimit(1)
                        Spacer(minLength: 0)
                        if let fraction = progress.fraction {
                            Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.bottom, 8)
            }
        }
    }
}
