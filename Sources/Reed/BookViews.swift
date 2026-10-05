import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import ReedCore
#endif

enum BookFilter: String, CaseIterable, Identifiable {
    case all = "All books", favorites = "Favorite books"
    var id: Self { self }
    var symbol: String { self == .all ? "books.vertical" : "star" }
    func includes(_ book: Book) -> Bool { self == .all || book.isFavorite }
}

/// A chapter opened from a book's contents, and the element to open it at.
struct BookPage: Hashable {
    let chapter: UUID
    var anchor: String?
}

/// The books on the shelf, the ones being read first.
struct BookShelfView: View {
    let library: Library
    let filter: BookFilter
    @Binding var selection: UUID?
    var onDelete: (Book) -> Void
    @State private var importing = false

    private var books: [Book] {
        library.books.filter(filter.includes).sorted { ($0.openedAt ?? $0.addedAt) > ($1.openedAt ?? $1.addedAt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            ColumnHeader(title: filter.rawValue, subtitle: count) {
                HeaderButton(help: "Add a book", symbol: "plus") { importing = true }
            }
            #endif
            List(selection: $selection) {
                #if os(iOS)
                Text(count).font(.system(size: 11)).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                #endif
                ForEach(books) { book in
                    BookRow(library: library, book: book)
                        .background(NavigationLink(value: book.id) { EmptyView() }.opacity(0))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .swipeActions(edge: .trailing) {
                            if book.state != .downloading {
                                Button { onDelete(book) } label: { Label("Delete", systemImage: "trash") }.tint(.red)
                            }
                            Button { library.toggleFavorite(book) } label: {
                                Label(book.isFavorite ? "Unfavorite" : "Favorite", systemImage: book.isFavorite ? "star.slash" : "star")
                            }
                            .tint(.orange)
                        }
                        .contextMenu { BookMenu(library: library, book: book, onDelete: onDelete) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if books.isEmpty {
                    VStack(spacing: 14) {
                        Text(filter == .favorites && !library.books.isEmpty ? "No favorite books yet." : "No books yet.")
                            .font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
                        if filter == .all {
                            Text("Add an EPUB that isn't locked to a store's app.").font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("Add a Book", systemImage: "plus") { importing = true }.buttonStyle(.reedSecondary)
                        }
                    }
                    .multilineTextAlignment(.center).padding(30)
                }
            }
            ActivityFooter(library: library)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let books = urls.filter { $0.pathExtension.lowercased() == "epub" }
            add(books)
            return !books.isEmpty
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): add(urls)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .columnTitle(filter.rawValue) {
            Button("Add a book", systemImage: "plus") { importing = true }
        }
    }

    private var count: String { "\(books.count) \(books.count == 1 ? "book" : "books")" }

    private func add(_ urls: [URL]) {
        Task {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { selection = try await library.add(bookAt: url, name: url.lastPathComponent).id }
                catch { library.errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct BookRow: View {
    let library: Library
    let book: Book

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCover(library: library, book: book).frame(width: 54, height: 80)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(book.title).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(3).lineSpacing(2)
                    Spacer(minLength: 4)
                    if book.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(ReedStyle.accent) }
                }
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.system(size: 12, design: .serif).italic()).foregroundStyle(.secondary).lineLimit(1)
                }
                BookStatus(book: book).font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 7)
        .accessibilityElement(children: .combine)
    }
}

/// Where reading a book has got to, or why it can't be read yet.
private struct BookStatus: View {
    let book: Book

    var body: some View {
        HStack(spacing: 5) {
            switch book.state {
            case .queued, .downloading:
                ProgressView().controlSize(.mini)
                Text("Preparing chapters…")
            case .failed:
                Image(systemName: "exclamationmark.circle")
                Text("Couldn't open this book")
            case .ready, .partial:
                if book.isRead {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Finished")
                } else if book.openedAt == nil {
                    Text("\(book.chapters.count) chapters")
                } else if let next = book.upNext {
                    Text("Chapter \(next.index + 1) of \(book.chapters.count) · \(Int(book.progress * 100))%")
                }
            }
        }
    }
}

/// The book's cover, or its title set in type where it has none.
struct BookCover: View {
    let library: Library
    let book: Book
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(ReedStyle.accent.opacity(0.14))
                    .overlay {
                        Text(book.title).font(.system(size: 9, design: .serif)).multilineTextAlignment(.center)
                            .foregroundStyle(ReedStyle.accent).padding(6)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .task(id: book.coverFile) { image = await Self.load(library.cover(of: book)) }
    }

    private static func load(_ url: URL?) async -> Image? {
        guard let url else { return nil }
        let data = await Task.detached { try? Data(contentsOf: url) }.value
        guard let data else { return nil }
        #if os(macOS)
        return NSImage(data: data).map(Image.init(nsImage:))
        #else
        return UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

/// What can be done to a book, from its row or its contents.
private struct BookMenu: View {
    let library: Library
    let book: Book
    var onDelete: (Book) -> Void

    var body: some View {
        Button(book.isFavorite ? "Remove Favorite" : "Favorite", systemImage: "star") { library.toggleFavorite(book) }
        if book.state == .failed || book.state == .partial {
            Button("Try Again", systemImage: "arrow.clockwise") { library.retry(book) }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { onDelete(book) }
            .disabled(book.state == .downloading)
    }
}

/// A book's contents, from which its chapters open.
struct BookView: View {
    let library: Library
    let book: Book
    @Binding var path: [BookPage]
    var onDelete: (Book) -> Void
    @Environment(Narrator.self) private var narrator
    /// Whether there's room for the cover beside the title, rather than above it.
    @State private var wide = true

    var body: some View {
        NavigationStack(path: $path) {
            contents
                .navigationDestination(for: BookPage.self) { page in
                    if let chapter = book.chapters.first(where: { $0.id == page.chapter }) {
                        ReaderView(library: library, readable: chapter, anchor: page.anchor) { target, anchor in
                            open(target, at: anchor)
                        }
                    }
                }
        }
        // Following listening into the next chapter, when the one being read was on screen.
        .onChange(of: narrator.readableID) { old, new in
            guard let old, path.last?.chapter == old, let next = book.chapters.first(where: { $0.id == new }) else { return }
            open(next)
        }
    }

    /// Opens a chapter in place of the one open, so going back returns to the contents.
    private func open(_ chapter: BookChapter, at anchor: String? = nil) {
        path = [BookPage(chapter: chapter.id, anchor: anchor)]
    }

    private var contents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 22)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                layout {
                    BookCover(library: library, book: book).frame(width: 110, height: 165)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.title).font(.system(size: 28, design: .serif)).lineSpacing(2)
                        if let author = book.author, !author.isEmpty {
                            Text(author).font(.system(size: 15, design: .serif).italic()).foregroundStyle(.secondary)
                        }
                        BookStatus(book: book).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
                        if book.state.isReadable, let next = book.upNext {
                            Button(book.openedAt == nil ? "Start Reading" : book.isRead ? "Read Again" : "Continue Reading") { open(next) }
                                .buttonStyle(.borderedProminent).tint(ReedStyle.accent).padding(.top, 10)
                        }
                    }
                    // Clear of the menu in the corner.
                    .padding(.trailing, wide ? 30 : 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    Menu { BookMenu(library: library, book: book, onDelete: onDelete) } label: { Label("More", systemImage: "ellipsis") }
                        .labelStyle(.iconOnly)
                        #if os(macOS)
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        #endif
                }
                .padding(.bottom, 30)
                if book.state == .failed {
                    Text(book.failureMessage ?? "This book couldn't be opened.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if book.state.isReadable {
                    Text("CONTENTS").font(.system(size: 10, weight: .medium)).tracking(1.7).foregroundStyle(.secondary).padding(.bottom, 8)
                    ForEach(book.orderedChapters) { chapter in
                        Button { open(chapter) } label: { ChapterRow(chapter: chapter, isCurrent: chapter.index == book.currentChapter) }
                            .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(.horizontal, wide ? 32 : 22).padding(.vertical, 36)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 460 } action: { wide = $0 }
        .background(ReedStyle.paper)
        .navigationTitle(book.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct ChapterRow: View {
    let chapter: BookChapter
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(chapter.title).font(.system(size: 16, design: .serif)).fontWeight(isCurrent ? .semibold : .regular)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Group {
                if chapter.isRead {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Finished")
                } else if chapter.progress > 0 {
                    Text("\(Int(chapter.progress * 100))%")
                } else {
                    Text("\(max(1, Int(ceil(Double(chapter.wordCount) / 230)))) min")
                }
            }
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
