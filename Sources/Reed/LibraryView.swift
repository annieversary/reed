import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

enum CollectionFilter: String, CaseIterable, Identifiable {
    case all = "All articles", unread = "Unread", favorites = "Favorites", read = "Finished"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .unread: "book.closed"
        case .favorites: "star"
        case .read: "checkmark.circle"
        }
    }
    func includes(_ article: Article) -> Bool {
        switch self {
        case .all: true
        case .unread: !article.isRead
        case .favorites: article.isFavorite
        case .read: article.isRead
        }
    }
}

enum SidebarItem: Hashable {
    case collection(CollectionFilter), discover(Discover)
}

struct LibraryView: View {
    @Bindable var library: Library
    @Environment(Narrator.self) private var narrator
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// Set once the layout is known: on iPhone a selection would open straight past the sidebar.
    @State private var selection: SidebarItem?
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var matches: [SearchIndex.Match] = []
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var articleToDelete: Article?
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var searchRevealed = false
    @FocusState private var searchFocused: Bool
    /// Articles that just stopped matching the filter, kept briefly so the change shows before the row goes.
    @State private var lingering: Set<UUID> = []

    private var filter: CollectionFilter? {
        if case .collection(let filter) = selection { filter } else { nil }
    }

    private var visibleArticles: [Article] {
        let candidates: [Article]
        if query.isEmpty {
            candidates = library.articles
        } else {
            let byID = Dictionary(uniqueKeysWithValues: library.articles.map { ($0.id, $0) })
            candidates = matches.compactMap { byID[$0.id] }
        }
        return candidates.filter { (filter ?? .all).includes($0) || lingering.contains($0.id) }
    }
    private var snippets: [UUID: String] {
        query.isEmpty ? [:] : Dictionary(matches.compactMap { match in match.snippet.map { (match.id, $0) } }) { first, _ in first }
    }

    private struct Search: Equatable {
        let query: String
        let revision: Int
    }
    private var selectedArticle: Article? { library.articles.first { $0.id == selectedID } }

    private struct Membership: Equatable {
        let filter: CollectionFilter
        let ids: [UUID]
    }
    private var membership: Membership {
        let filter = filter ?? .all
        return Membership(filter: filter, ids: library.articles.filter { filter.includes($0) }.map(\.id))
    }

    private func lingerOnRemoval(from old: Membership, to new: Membership) {
        guard old.filter == new.filter else { lingering = []; return }
        let remaining = Set(library.articles.map(\.id))
        let left = Set(old.ids).subtracting(new.ids).intersection(remaining)
        guard !left.isEmpty else { return }
        lingering.formUnion(left)
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation { lingering.subtract(left) }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
                .safeAreaInset(edge: .bottom, spacing: 0) { narrationBar(when: columnsStack) }
        } content: {
            Group {
                if case .discover(let origin) = selection {
                    SourceListView(library: library, origin: origin, open: { selectedID = $0.id }) { article in
                        if selectedID == article.id { selectedID = nil }
                        if narrator.articleID == article.id { narrator.stop() }
                        library.discard(article)
                    }
                    .id(origin)
                } else {
                    articleList
                }
            }
            .navigationSplitViewColumnWidth(min: 270, ideal: 340, max: 430)
            .safeAreaInset(edge: .bottom, spacing: 0) { narrationBar(when: columnsStack) }
        } detail: {
            Group {
                if let article = selectedArticle {
                    ArticleDetailView(library: library, article: article)
                } else {
                    readerPlaceholder
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { narrationBar(when: true) }
        }
        .sheet(isPresented: $showingAdd) {
            AddArticleView { url in
                let article = try library.add(url)
                selection = .collection(.all)
                query = ""
                selectedID = article.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reedAddArticle)) { _ in showingAdd = true }
        .onAppear { if !columnsStack { selection = .collection(.all) } }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) { NavigationStack { SettingsView() } }
        #endif
        #if DEBUG && os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("reed.smokeSelectArticle"))) { notification in
            selectedID = notification.object as? UUID
        }
        #endif
        .alert("Library error", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .confirmationDialog("Delete this saved article?", isPresented: Binding(get: { articleToDelete != nil }, set: { if !$0 { articleToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Article", role: .destructive) {
                if let article = articleToDelete {
                    if selectedID == article.id { selectedID = nil }
                    if narrator.articleID == article.id { narrator.stop() }
                    library.delete(article)
                }
                articleToDelete = nil
            }
        } message: { Text("Its offline copy will be removed from this device.") }
    }

    /// Whether the columns are shown one at a time, as on iPhone, rather than side by side.
    private var columnsStack: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    /// Narration controls, attached to each column's own content: an inset around the whole split view
    /// doesn't reach into the columns on iOS, which would leave the reader running underneath it.
    @ViewBuilder private func narrationBar(when shown: Bool) -> some View {
        if shown, narrator.articleID != nil {
            NarrationBar(narrator: narrator) { selectedID = narrator.articleID }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                Image("ReedMark").renderingMode(.template).resizable().frame(width: 34, height: 34)
                    .foregroundStyle(ReedStyle.accent)
                Text("reed").font(.system(size: 34, weight: .regular, design: .serif)).tracking(-1.8)
                Spacer()
                #if os(iOS)
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .labelStyle(.iconOnly).font(.title3).foregroundStyle(.secondary)
                #endif
            }
            .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 30)
            List(selection: $selection) {
                Section {
                    ForEach(CollectionFilter.allCases) { item in
                        NavigationLink(value: SidebarItem.collection(item)) {
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol).frame(width: 18)
                                Text(item.rawValue)
                                Spacer(minLength: 2)
                                Text("\(library.articles.filter { item.includes($0) }.count)")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                } header: { Text("LIBRARY").font(.system(size: 10, weight: .medium)).tracking(1.7) }
                Section {
                    ForEach(ExternalSource.allCases) { source in
                        discoverLink(.frontPage(source), symbol: source.symbol)
                    }
                    discoverLink(.feeds, symbol: "dot.radiowaves.up.forward")
                } header: { Text("DISCOVER").font(.system(size: 10, weight: .medium)).tracking(1.7) }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Reed")
        #if os(macOS)
        .toolbar(removing: .title)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private func discoverLink(_ origin: Discover, symbol: String) -> some View {
        NavigationLink(value: SidebarItem.discover(origin)) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(origin.title)
            }
            .padding(.vertical, 5)
        }
    }

    private var articleList: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text((filter ?? .all).rawValue).font(.system(size: 26, design: .serif))
                        Text(articleCount).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered).clipShape(RoundedRectangle(cornerRadius: 9))
                    .help("Save an article (⌘N)").accessibilityLabel("Save an article")
                }
                searchField
            }
            .padding(20)
            Divider()
            #endif
            List(selection: $selectedID) {
                #if os(iOS)
                if !pullRevealsSearch {
                    searchField
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                }
                Text(articleCount).font(.system(size: 11)).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                #endif
                let snippets = snippets
                ForEach(visibleArticles) { article in
                    // A hidden link keeps row navigation without the disclosure chevron.
                    ArticleRow(article: article, snippet: snippets[article.id])
                        .background(NavigationLink(value: article.id) { EmptyView() }.opacity(0))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .swipeActions(edge: .leading) {
                            Button { library.toggleRead(article) } label: {
                                Label(article.isRead ? "Unread" : "Finished", systemImage: article.isRead ? "book.closed" : "checkmark.circle")
                            }
                            .tint(ReedStyle.accent)
                        }
                        // No destructive role: it would remove the row before the delete is confirmed.
                        .swipeActions(edge: .trailing) {
                            if article.state != .downloading {
                                Button { articleToDelete = article } label: { Label("Delete", systemImage: "trash") }
                                    .tint(.red)
                            }
                            Button { library.toggleFavorite(article) } label: {
                                Label(article.isFavorite ? "Unfavorite" : "Favorite", systemImage: article.isFavorite ? "star.slash" : "star")
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button(article.isFavorite ? "Remove Favorite" : "Favorite", systemImage: "star") { library.toggleFavorite(article) }
                            Button(article.isRead ? "Mark Unread" : "Mark Finished", systemImage: "checkmark.circle") { library.toggleRead(article) }
                            if article.state == .failed || article.state == .partial {
                                Button("Retry Download", systemImage: "arrow.clockwise") { library.retry(article) }
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { articleToDelete = article }
                                .disabled(article.state == .downloading)
                        }
                }
            }
            .listStyle(.plain)
            .onChange(of: membership, lingerOnRemoval)
            .task(id: Search(query: query, revision: library.searchRevision)) {
                let found = await library.search(query)
                if !Task.isCancelled { matches = found }
            }
            #if os(iOS)
            .environment(\.defaultMinListRowHeight, 0)
            .pullToReveal(revealed: $searchRevealed, keepRevealed: searchFocused || !query.isEmpty) {
                searchField.padding(.horizontal, 20).padding(.bottom, 8)
            }
            // The list stays alive under a pushed article, so its field would keep the keyboard up.
            .onChange(of: selectedID) { searchFocused = false }
            .onDisappear { searchFocused = false }
            #endif
            .overlay {
                if visibleArticles.isEmpty {
                    Text(emptyMessage).font(.system(size: 18, design: .serif))
                        .foregroundStyle(.secondary)
                }
            }
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
        .navigationTitle((filter ?? .all).rawValue)
        #if os(macOS)
        .toolbar(removing: .title)
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text((filter ?? .all).rawValue).font(.system(size: 19, design: .serif))
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save an article", systemImage: "plus") { showingAdd = true }
            }
        }
        #endif
    }

    #if os(iOS)
    /// Search hides above the list until a pull-down reveals it; without scroll geometry (before iOS 18)
    /// it is an ordinary row that always shows.
    private var pullRevealsSearch: Bool {
        if #available(iOS 18.0, *) { true } else { false }
    }
    #endif

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Search", text: $query).textFieldStyle(.plain)
                .font(.system(size: 12)).focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }
        .padding(10).background(ReedStyle.warm, in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "No articles found." }
        if library.articles.isEmpty { return "No articles saved." }
        return switch filter ?? .all {
        case .all: "No articles saved."
        case .unread: "Nothing left to read."
        case .favorites: "No favorites yet."
        case .read: "Nothing finished yet."
        }
    }

    private var articleCount: String {
        "\(visibleArticles.count) \(visibleArticles.count == 1 ? "article" : "articles")"
    }

    private var readerPlaceholder: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().stroke(ReedStyle.accent.opacity(0.08), lineWidth: 1).frame(width: 150, height: 150)
                Circle().fill(ReedStyle.accent.opacity(0.05)).frame(width: 108, height: 108)
                Image(systemName: "book.pages").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(ReedStyle.accent)
            }
            VStack(spacing: 12) {
                Text("A quieter place to read.").font(.system(size: 30, design: .serif)).tracking(-0.6)
                Text("Save the articles that catch your eye.\nRead them here, even when you're offline.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5).multilineTextAlignment(.center)
            }
            Button { showingAdd = true } label: {
                Label(library.articles.isEmpty ? "Save your first article" : "Save an article", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent)
            Text("PAUSE. SAVE. COME BACK.").font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(.tertiary).padding(.top, 35)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReedStyle.warm)
    }
}

#if os(iOS)
private extension View {
    /// Keeps `field` just above the scroll view's content, so pulling down uncovers it. Letting go
    /// once it is fully uncovered sets `revealed`; scrolling it back out of view clears it again
    /// unless `keepRevealed`. Does nothing before iOS 18.
    @ViewBuilder func pullToReveal<Field: View>(revealed: Binding<Bool>, keepRevealed: Bool, @ViewBuilder field: () -> Field) -> some View {
        if #available(iOS 18.0, *) {
            modifier(PullToReveal(revealed: revealed, keepRevealed: keepRevealed, field: field()))
        } else {
            self
        }
    }
}

/// Revealing widens the top content margin rather than inserting a row, so the content stays
/// where the finger left it and settles below the field without a re-layout. Hiding narrows it
/// only once the field is out of view, where the change can't be seen.
@available(iOS 18.0, *)
private struct PullToReveal<Field: View>: ViewModifier {
    @Binding var revealed: Bool
    let keepRevealed: Bool
    let field: Field
    /// How far the content sits below its resting position; negative once scrolled down.
    @State private var pull: CGFloat = 0
    @State private var fieldHeight: CGFloat = 52

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, revealed ? fieldHeight : 0, for: .scrollContent)
            .onScrollGeometryChange(for: CGFloat.self) { -($0.contentOffset.y + $0.contentInsets.top) } action: { _, new in
                pull = new
                if revealed && !keepRevealed && pull <= -fieldHeight { revealed = false }
            }
            .onScrollPhaseChange { old, _ in
                if old == .interacting && !revealed && pull >= fieldHeight { revealed = true }
            }
            .overlay(alignment: .top) {
                field
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
                    .offset(y: pull - (revealed ? 0 : fieldHeight))
                    .opacity(revealed ? 1 : min(1, max(0, pull / fieldHeight)))
                    .allowsHitTesting(revealed)
            }
    }
}
#endif

private struct ArticleRow: View {
    let article: Article
    /// The passage that matched a search, shown in place of the excerpt.
    let snippet: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(article.domain.lowercased()).font(.system(size: 9, weight: .semibold)).tracking(1.1)
                Spacer()
                if article.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)) }
            }.foregroundStyle(ReedStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(3).lineSpacing(2)
                if let byline {
                    Text(byline).font(.system(size: 12, design: .serif).italic()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let snippet {
                Text(Self.highlighted(snippet)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).lineSpacing(3)
            } else if !article.excerpt.isEmpty {
                Text(article.excerpt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
            }
            HStack(spacing: 5) {
                if article.state == .downloading || article.state == .queued { ProgressView().controlSize(.mini) }
                else if !article.state.isReadable { Image(systemName: "exclamationmark.circle").font(.system(size: 10)) }
                Text(article.state.isReadable ? "\(article.readingMinutes) min read" : article.state.label)
                if article.state == .partial { Image(systemName: "photo.badge.exclamationmark") }
                if article.isRead {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                        .accessibilityLabel("Finished")
                } else if article.progress > 0 {
                    Text("· \(Int(article.progress * 100))%")
                }
                Spacer()
                Text("Saved \(article.savedAt.formatted(.dateTime.month(.abbreviated).day()))")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(.vertical, 15).padding(.horizontal, 7)
        .accessibilityElement(children: .combine)
    }

    private var byline: String? {
        let parts = [article.author, article.publishedAt.map(Self.formatPublished)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in snippet.components(separatedBy: SearchIndex.highlightStart).enumerated() {
            let pieces = part.components(separatedBy: SearchIndex.highlightEnd)
            guard index > 0, pieces.count > 1 else { result += AttributedString(part); continue }
            var term = AttributedString(pieces[0])
            term.foregroundColor = .primary
            term.inlinePresentationIntent = .stronglyEmphasized
            result += term + AttributedString(pieces.dropFirst().joined())
        }
        return result
    }

    private static func formatPublished(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}
