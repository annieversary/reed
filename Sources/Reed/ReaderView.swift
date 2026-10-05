import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// A saved article or book chapter, read offline.
struct ReaderView: View {
    let library: Library
    let readable: any Readable
    /// An element to open at, by ID, as when following a link from another chapter.
    var anchor: String?
    /// Opens another chapter of the book, at an element if given.
    var onOpenChapter: (BookChapter, String?) -> Void = { _, _ in }
    /// The article after this one in the list it was opened from.
    var next: Article?
    var onOpenNext: () -> Void = {}
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @Environment(\.openURL) private var openURL
    @Environment(Narrator.self) private var narrator
    @State private var passages: [[String]]?
    @State private var reader = ReaderProxy()
    @State private var narrationAway: NarrationDirection?
    @State private var notes: [ArticleNote]?
    @State private var notesOpen = false
    @State private var findingChapters = false
    @State private var commentsOpen = false
    /// The comments last fetched from each place the article is discussed.
    @State private var discussions: [DiscussionSite: Discussion] = [:]

    private var article: Article? { readable as? Article }
    private var chapter: BookChapter? { readable as? BookChapter }
    private var isNarrating: Bool { narrator.readableID == readable.id }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 16) {
                Text(readable.source).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if library.contentURL(for: readable) != nil {
                    progressLabel
                    if !isNarrating { listenButton }
                }
                if article?.sourceURL != nil { commentsButton }
                readerMenu
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            Divider()
            #endif
            if let url = library.contentURL(for: readable) {
                if let article, article.state == .partial {
                    HStack {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("Text is saved. \(article.missingImageCount) \(article.missingImageCount == 1 ? "image is" : "images are") unavailable.")
                        Spacer()
                        Button("Retry") { library.retry(article) }.buttonStyle(.plain).foregroundStyle(ReedStyle.accent)
                    }
                    .font(.caption).padding(12).background(.yellow.opacity(0.08))
                }
                OfflineWebView(url: url, fontSize: fontSize, progress: readable.progress, anchor: anchor, passages: passages,
                               narrating: isNarrating ? NarrationPosition(passage: narrator.current, sentence: narrator.sentence) : nil,
                               proxy: reader, notes: notes, notesOpen: notesOpen, cards: endCards) { value in
                    library.updateProgress(readable, value: value)
                } onAddLink: { link in
                    do { try library.add(link.absoluteString) }
                    catch { library.errorMessage = error.localizedDescription }
                } onNarrateFrom: { passage in
                    narrator.play(readable, from: passage, in: library)
                } onNarrationAway: { direction in
                    withAnimation(.easeOut(duration: 0.2)) { narrationAway = direction }
                } onNotesOpen: { open in
                    notesOpen = open
                } onNoteChange: { passage, text in
                    library.setNote(text, at: passage, for: readable)
                } onOpenSibling: { file, anchor in
                    guard let index = BookFiles.chapterIndex(of: file),
                          let target = chapter?.book?.orderedChapters.first(where: { $0.index == index }) else { return }
                    onOpenChapter(target, anchor)
                } onOpenCard: { id in
                    if id == Self.commentsCard { commentsOpen = true } else { onOpenNext() }
                }
                .id(readable.id.uuidString + (readable.contentVersion ?? "") + (anchor ?? ""))
                // Text runs under the home indicator, but not under the narration controls.
                .ignoresSafeArea(edges: narrator.readableID == nil ? .bottom : [])
                .task(id: url) {
                    let text = library.passages(for: readable)
                    notes = text.map { library.notes(for: readable, passages: $0) }
                    passages = text?.map(ArticleSpeech.sentences(in:))
                }
                // Drawn by the app rather than the page, so it sits above the narration controls.
                .overlay(alignment: .bottom) {
                    if isNarrating, let narrationAway { returnToNarrationButton(narrationAway) }
                }
            } else if let article {
                VStack(spacing: 18) {
                    if article.state == .downloading || article.state == .queued {
                        ProgressView().controlSize(.large)
                        Text("Saving").font(.system(size: 25, design: .serif))
                        if article.state == .downloading, let imageActivity = library.imageActivity {
                            Text(imageActivity).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                        Text("Save failed.").font(.system(size: 25, design: .serif))
                        Text(article.failureMessage ?? "The article couldn't be downloaded.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                        HStack {
                            Button("Retry download") { library.retry(article) }.buttonStyle(.borderedProminent)
                            if let url = article.sourceURL { Button("Open original") { openURL(url) }.buttonStyle(.reedSecondary) }
                        }
                    }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReedStyle.paper)
            } else {
                Text("This chapter isn't saved.").font(.system(size: 20, design: .serif)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(ReedStyle.paper)
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .toolbar {
            if library.contentURL(for: readable) != nil {
                ToolbarItem(placement: .principal) { progressLabel }
                if !isNarrating { ToolbarItem(placement: .primaryAction) { listenButton } }
            }
            if article?.sourceURL != nil { ToolbarItem(placement: .primaryAction) { commentsButton } }
            ToolbarItem(placement: .primaryAction) { readerMenu }
        }
        #endif
        .sheet(isPresented: $findingChapters) { if let article { FindChaptersView(library: library, start: article) } }
        .inspector(isPresented: $commentsOpen) {
            if let article {
                DiscussionView(library: library, article: article, isPresented: $commentsOpen) { discussions[$0] = $1 }
                    .inspectorColumnWidth(min: 320, ideal: 420)
            }
        }
        .task(id: article?.id) { if let article { loadDiscussions(of: article) } }
        .onAppear { if let chapter { library.open(chapter) } }
        .onDisappear { library.save() }
    }

    private static let commentsCard = "comments"

    private var endCards: [EndCard] {
        var cards: [EndCard] = []
        if let sites = article?.discussionSites, !sites.isEmpty {
            let counted = sites.compactMap { site in discussions[site].map { (site, $0.count) } }
            let total = counted.reduce(0) { $0 + $1.1 }
            let title = counted.isEmpty ? "Read the discussion" : "\(total) \(total == 1 ? "comment" : "comments")"
            let detail = counted.count > 1 ? counted.map { "\($1) on \($0.name)" }.joined(separator: " · ") : ""
            cards.append(EndCard(id: Self.commentsCard, kicker: "DISCUSSION", source: sites.map { $0.name.uppercased() }.joined(separator: " · "),
                                 title: title, detail: detail))
        }
        if let next {
            let detail = [next.author, next.state.isReadable ? "\(next.readingMinutes) min read" : nil].compactMap { $0 }.filter { !$0.isEmpty }
            cards.append(EndCard(id: "next", kicker: "NEXT ARTICLE", source: next.domain.uppercased(), title: next.title, detail: detail.joined(separator: " · ")))
        }
        return cards
    }

    /// The comments kept from when they were last shown. Opening an article fetches nothing, so no site learns it was read.
    private func loadDiscussions(of article: Article) {
        discussions = Dictionary(article.discussionSites.compactMap { site in library.discussion(site, of: article).map { (site, $0) } },
                                 uniquingKeysWith: { first, _ in first })
    }

    private var progressLabel: some View {
        Group {
            if readable.isRead { Text("Finished") } else { PercentText(fraction: readable.progress) }
        }
        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.1), value: readable.progress)
        // Opening another article shows its position straight away rather than counting to it.
        .id(readable.id)
    }

    private var listenButton: some View {
        Button("Listen", systemImage: "headphones") {
            Task {
                // Pick up where listening stopped; otherwise start from what's on screen.
                let visible = readable.narrationPassage == nil ? await reader.visiblePassage() : nil
                narrator.play(readable, from: visible, in: library)
            }
        }
            .labelStyle(.iconOnly)
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
            .help("Listen")
    }

    private var commentsButton: some View {
        Button("Comments", systemImage: "text.bubble") { commentsOpen.toggle() }
            .labelStyle(.iconOnly)
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
            .help("Comments")
    }

    private func returnToNarrationButton(_ direction: NarrationDirection) -> some View {
        Button("Back to the Paragraph Being Read", systemImage: direction == .up ? "arrow.up" : "arrow.down") {
            reader.followNarration()
        }
        .labelStyle(.iconOnly).buttonStyle(.plain)
        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
        .frame(width: 38, height: 38)
        .background(ReedStyle.accent, in: Circle())
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.bottom, 16)
        .transition(.opacity.combined(with: .offset(y: 8)))
        .help("Back to the Paragraph Being Read")
    }

    private var readerMenu: some View {
        Menu {
            if let article {
                if article.isCached {
                    Button("Save to Library", systemImage: "tray.and.arrow.down") { library.keep(article) }
                } else {
                    Button("Remove from Library", systemImage: "tray.and.arrow.up") { library.removeFromLibrary(article) }
                }
                Divider()
                Button(article.isFavorite ? "Remove Favorite" : "Favorite", systemImage: article.isFavorite ? "star.slash" : "star") {
                    library.toggleFavorite(article)
                }
            } else if let book = chapter?.book {
                // Books are favorited whole, rather than by chapter.
                Button(book.isFavorite ? "Remove Book from Favorites" : "Favorite Book", systemImage: book.isFavorite ? "star.slash" : "star") {
                    library.toggleFavorite(book)
                }
            }
            Button(readable.isRead ? "Mark Unread" : "Mark Finished", systemImage: readable.isRead ? "circle" : "checkmark.circle") {
                library.toggleRead(readable)
            }
            #if os(iOS)
            ControlGroup { textSizeButtons }.menuActionDismissBehavior(.disabled)
            #else
            Menu("Text Size", systemImage: "textformat.size") { textSizeButtons }
            #endif
            if let article, article.mayHaveOtherChapters {
                Button("Find Other Chapters…", systemImage: "square.stack.3d.up") { findingChapters = true }
            }
            if let url = article?.sourceURL {
                Divider()
                Button("Open Original", systemImage: "safari") { openURL(url) }
            }
        } label: { Label("More", systemImage: "ellipsis") }
        .labelStyle(.iconOnly)
        #if os(macOS)
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        #endif
        .help("More")
    }

    @ViewBuilder private var textSizeButtons: some View {
        Button("Smaller", systemImage: "textformat.size.smaller") { fontSize = max(14, fontSize - 1) }
        Button("Reset", systemImage: "textformat.size") { fontSize = 19 }
        Button("Larger", systemImage: "textformat.size.larger") { fontSize = min(28, fontSize + 1) }
    }
}

/// Counts through every whole percent between two values when animated.
private struct PercentText: View, Animatable {
    var fraction: Double
    nonisolated var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View { Text("\(Int(fraction * 100))%") }
}
