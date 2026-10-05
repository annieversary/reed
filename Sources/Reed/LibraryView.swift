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
    case collection(CollectionFilter), books(BookFilter), discover(Discover)
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
    @State private var selectedBookID: UUID?
    /// The chapter open in the selected book, if any.
    @State private var bookPath: [BookPage] = []
    @State private var bookToDelete: Book?
    @State private var query = ""
    @State private var matches: [SearchIndex.Match] = []
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var articleToDelete: Article?
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var searchRowHeight: CGFloat = 0
    /// How much of the search row is scrolled out of view, from 0 to 1.
    @State private var searchTucked: CGFloat = 0
    @FocusState private var searchFocused: Bool
    /// Articles that just stopped matching the filter, kept briefly so the change shows before the row goes.
    @State private var lingering: Set<UUID> = []
    @State private var expandedSeries: Set<UUID> = []
    /// The article a new series is being made from.
    @State private var seriesStart: Article?
    @State private var chaptersStart: Article?
    @State private var seriesToRename: Series?
    @State private var seriesName = ""
    /// The article after the open one in the list, kept while the open one lingers out of it, as when finishing it in Unread.
    @State private var nextID: UUID?

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
    private enum Entry: Identifiable {
        case article(Article), series(Series, [Article])
        var id: UUID {
            switch self {
            case .article(let article): article.id
            case .series(let series, _): series.id
            }
        }
        var articleCount: Int {
            switch self {
            case .article: 1
            case .series(_, let parts): parts.count
            }
        }
    }

    /// The list's rows: series gathered into one row where their first listed part would be, except in
    /// search results and favorites, which are about single articles. A series is unread while any part
    /// is, and finished once every part is. Unread lists oldest first, so the queue reads in order saved.
    private var entries: [Entry] {
        let filter = filter ?? .all
        guard query.isEmpty, filter != .favorites else { return visibleArticles.map(Entry.article) }
        var shown = Set<UUID>()
        var entries: [Entry] = []
        // Looked up once, rather than searching every series and article for each row.
        let byID = Dictionary(uniqueKeysWithValues: library.articles.map { ($0.id, $0) })
        let seriesOf = Dictionary(library.series.flatMap { series in series.parts.map { ($0, series) } }) { first, _ in first }
        for article in filter == .unread ? Array(library.articles.reversed()) : library.articles {
            if let series = seriesOf[article.id] {
                guard shown.insert(series.id).inserted else { continue }
                let parts = series.parts.compactMap { byID[$0] }
                let included = filter == .read ? parts.allSatisfy(filter.includes) : parts.contains(where: filter.includes)
                if included || parts.contains(where: { lingering.contains($0.id) }) { entries.append(.series(series, parts)) }
            } else if filter.includes(article) || lingering.contains(article.id) {
                entries.append(.article(article))
            }
        }
        return entries
    }

    private struct Following: Equatable {
        let current: UUID?
        /// Nil when the open article isn't in the list.
        let next: UUID??
    }
    /// What comes after the open article in the article list, reading each series' parts in place of its row.
    private var following: Following {
        guard filter != nil, let selectedID else { return Following(current: selectedID, next: nil) }
        let ids = entries.flatMap { entry -> [UUID] in
            switch entry {
            case .article(let article): [article.id]
            case .series(_, let parts): parts.map(\.id)
            }
        }
        guard let index = ids.firstIndex(of: selectedID) else { return Following(current: selectedID, next: nil) }
        return Following(current: selectedID, next: .some(ids.indices.contains(index + 1) ? ids[index + 1] : nil))
    }

    private func openNext() {
        guard let next = library.articles.first(where: { $0.id == nextID }) else { return }
        if let series = library.series(of: next) { expandedSeries.insert(series.id) }
        selectedID = next.id
    }

    private var snippets: [UUID: String] {
        query.isEmpty ? [:] : Dictionary(matches.compactMap { match in match.snippet.map { (match.id, $0) } }) { first, _ in first }
    }

    private struct Search: Equatable {
        let query: String
        let revision: Int
    }
    private var selectedArticle: Article? { (library.articles + library.cached).first { $0.id == selectedID } }

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
                    SourceListView(library: library, origin: origin) { selectedID = $0.id }
                        .id(origin)
                } else if case .books(let filter) = selection {
                    BookShelfView(library: library, filter: filter, selection: $selectedBookID) { bookToDelete = $0 }
                } else {
                    articleList
                }
            }
            .navigationSplitViewColumnWidth(min: 270, ideal: 340, max: 430)
            .safeAreaInset(edge: .bottom, spacing: 0) { narrationBar(when: columnsStack) }
        } detail: {
            Group {
                if case .books = selection {
                    if let book = library.books.first(where: { $0.id == selectedBookID }) {
                        BookView(library: library, book: book, path: $bookPath) { bookToDelete = $0 }
                            .id(book.id)
                    } else {
                        bookPlaceholder
                    }
                } else if let article = selectedArticle {
                    ReaderView(library: library, readable: article, next: library.articles.first { $0.id == nextID }, onOpenNext: openNext)
                        .id(article.id)
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
        .onReceive(NotificationCenter.default.publisher(for: .reedShowBook)) { notification in
            guard let ids = notification.object as? [UUID], let book = ids.first else { return }
            selection = .books(.all)
            selectedBookID = book
            // After the book's selection has reset what's open in it.
            Task { bookPath = ids.dropFirst().map { BookPage(chapter: $0) } }
        }
        .onAppear { if !columnsStack { selection = .collection(.all) } }
        .onChange(of: [selectedID, narrator.readableID], initial: true) { _, ids in library.retained = Set(ids.compactMap { $0 }) }
        .onChange(of: selectedBookID) { bookPath = [] }
        .onChange(of: following, initial: true) { old, new in
            if let next = new.next { nextID = next } else if old.current != new.current { nextID = nil }
        }
        .onChange(of: SubstackAccount.shared.isSignedIn, initial: true) { _, signedIn in
            guard !signedIn else { return }
            library.forgetFrontPage(of: .substack)
            if selection == .discover(.frontPage(.substack)) { selection = .collection(.all) }
        }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) { NavigationStack { SettingsView() } }
        #endif
        #if DEBUG && os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("reed.smokeSelectArticle"))) { notification in
            selectedID = notification.object as? UUID
        }
        #endif
        .alert("Library error", isPresented: Bindable(library).errorMessage.isPresent(), presenting: library.errorMessage) { _ in
            Button("OK") { library.errorMessage = nil }
        } message: { Text($0) }
        .confirmationDialog("Delete this saved article?", isPresented: $articleToDelete.isPresent(), titleVisibility: .visible,
                            presenting: articleToDelete) { article in
            Button("Delete Article", role: .destructive) {
                if selectedID == article.id { selectedID = nil }
                if narrator.readableID == article.id { narrator.stop() }
                library.delete(article)
            }
        } message: { _ in Text("Its offline copy will be removed from this device.") }
        .confirmationDialog("Delete this book?", isPresented: $bookToDelete.isPresent(), titleVisibility: .visible,
                            presenting: bookToDelete) { book in
            Button("Delete Book", role: .destructive) {
                if selectedBookID == book.id { selectedBookID = nil }
                if book.chapters.contains(where: { $0.id == narrator.readableID }) { narrator.stop() }
                library.delete(book)
            }
        } message: { _ in Text("Its chapters and the notes written beside them will be removed from this device.") }
        .sheet(item: $seriesStart) { article in
            MakeSeriesView(library: library, start: article) { expandedSeries.insert($0.id) }
        }
        .sheet(item: $chaptersStart) { article in FindChaptersView(library: library, start: article) }
        .alert("Rename series", isPresented: $seriesToRename.isPresent(), presenting: seriesToRename) { series in
            TextField("Name", text: $seriesName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { library.rename(series, to: seriesName) }
        }
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
        if shown, narrator.readableID != nil {
            NarrationBar(narrator: narrator, onOpen: openNarrated)
        }
    }

    /// When the columns stack, the article is pushed from the article list's selection, so that list
    /// must be the one showing, and hold the article, from the sidebar, Discover or another collection.
    private func openNarrated() {
        guard let id = narrator.readableID else { return }
        if let book = library.books.first(where: { $0.chapters.contains { $0.id == id } }) {
            if case .books = selection {} else { selection = .books(.all) }
            if selectedBookID != book.id { selectedBookID = book.id }
            // After the book's selection has reset what's open in it.
            Task { bookPath = [BookPage(chapter: id)] }
            return
        }
        if let article = library.articles.first(where: { $0.id == id }), let series = library.series(of: article) {
            expandedSeries.insert(series.id)
        }
        if columnsStack, filter == nil || !visibleArticles.contains(where: { $0.id == id }) {
            selection = .collection(.all)
            query = ""
        }
        selectedID = id
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
                    ForEach(BookFilter.allCases) { item in
                        NavigationLink(value: SidebarItem.books(item)) {
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol).frame(width: 18)
                                Text(item.rawValue)
                                Spacer(minLength: 2)
                                Text("\(library.books.filter { item.includes($0) }.count)")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                } header: { Text("BOOKS").font(.system(size: 10, weight: .medium)).tracking(1.7) }
                Section {
                    ForEach(ExternalSource.allCases.filter { $0 != .substack || SubstackAccount.shared.isSignedIn }) { source in
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
        let entries = entries
        let articleCount = Self.count(of: entries)
        return VStack(spacing: 0) {
            #if os(macOS)
            ColumnHeader(title: (filter ?? .all).rawValue, subtitle: articleCount) {
                HeaderButton(help: "Save an article (⌘N)", label: "Save an article", symbol: "plus") { showingAdd = true }
            } below: {
                searchField
            }
            #endif
            List(selection: $selectedID) {
                #if os(iOS)
                Fading(hidden: $searchTucked) { searchField }
                    .padding(.horizontal, 20).padding(.bottom, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { searchRowHeight = $0 }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .id(ListRow.search)
                Text(articleCount).font(.system(size: 11)).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .id(ListRow.count)
                #endif
                let snippets = snippets
                ForEach(entries) { entry in
                    switch entry {
                    case .article(let article):
                        actionable(ArticleRow(article: article, snippet: snippets[article.id]), for: article,
                                   insets: EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    case .series(let series, let parts):
                        seriesRows(series, parts: parts)
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
            .pullToReveal(ListRow.search, next: ListRow.count, height: searchRowHeight, startHidden: query.isEmpty, tucked: $searchTucked)
            // Each collection opens with the search field tucked away.
            .id(filter)
            // The list stays alive under a pushed article, so its field would keep the keyboard up.
            .onChange(of: selectedID) { searchFocused = false }
            .onDisappear { searchFocused = false }
            #endif
            .overlay {
                if entries.isEmpty {
                    Text(emptyMessage).font(.system(size: 18, design: .serif))
                        .foregroundStyle(.secondary)
                }
            }
            ActivityFooter(library: library)
        }
        .columnTitle((filter ?? .all).rawValue) {
            Button("Save an article", systemImage: "plus") { showingAdd = true }
        }
    }

    #if os(iOS)
    private enum ListRow { case search, count }
    #endif

    @ViewBuilder private func seriesRows(_ series: Series, parts: [Article]) -> some View {
        let expanded = Binding(get: { expandedSeries.contains(series.id) },
                               set: { if $0 { expandedSeries.insert(series.id) } else { expandedSeries.remove(series.id) } })
        if let first = parts.first {
            // Opens the part to carry on with, or the first once every part is finished. The tag replaces
            // the series' own ID, which the list would otherwise select.
            let next = (SeriesRow.upNext(in: parts) ?? first).id
            SeriesRow(series: series, parts: parts, expanded: expanded)
                .background(NavigationLink(value: next) { EmptyView() }.opacity(0))
                .tag(next)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: expanded.wrappedValue ? 0 : 4, trailing: 12))
                .contextMenu {
                    Button(expanded.wrappedValue ? "Hide Parts" : "Show Parts", systemImage: "list.bullet") {
                        withAnimation(.snappy(duration: 0.25)) { expanded.wrappedValue.toggle() }
                    }
                    Button("Rename Series…", systemImage: "pencil") { seriesName = series.name; seriesToRename = series }
                    if let last = parts.last(where: \.mayHaveOtherChapters) {
                        Button("Find Other Chapters…", systemImage: "square.stack.3d.up") { chaptersStart = last }
                    }
                    let finished = parts.allSatisfy(\.isRead)
                    Button(finished ? "Mark All Unread" : "Mark All Finished", systemImage: "checkmark.circle") {
                        library.setRead(!finished, for: parts)
                    }
                    Divider()
                    Button("Ungroup Series", systemImage: "square.stack.3d.down.right") { library.ungroup(series) }
                }
            if expanded.wrappedValue {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    actionable(PartRow(article: part, number: index + 1, seriesName: series.name), for: part,
                               insets: EdgeInsets(top: 0, leading: 19, bottom: 0, trailing: 12))
                }
                .onMove { library.moveParts(of: series, from: $0, to: $1) }
            }
        }
    }

    /// A row that opens `article`, with its swipe actions and context menu.
    private func actionable(_ row: some View, for article: Article, insets: EdgeInsets) -> some View {
        // A hidden link keeps row navigation without the disclosure chevron.
        row
            .background(NavigationLink(value: article.id) { EmptyView() }.opacity(0))
            .listRowSeparator(.hidden)
            .listRowInsets(insets)
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
                } else if article.state == .ready {
                    Button("Refresh", systemImage: "arrow.clockwise") { library.retry(article) }
                }
                Divider()
                seriesMenu(for: article)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { articleToDelete = article }
                    .disabled(article.state == .downloading)
            }
    }

    @ViewBuilder private func seriesMenu(for article: Article) -> some View {
        if let series = library.series(of: article) {
            if let index = series.parts.firstIndex(of: article.id) {
                if index > 0 {
                    Button("Move Earlier", systemImage: "arrow.up") { library.moveParts(of: series, from: [index], to: index - 1) }
                }
                if index < series.parts.count - 1 {
                    Button("Move Later", systemImage: "arrow.down") { library.moveParts(of: series, from: [index], to: index + 2) }
                }
            }
            Button("Remove from Series", systemImage: "minus.circle") { library.removeFromSeries(article) }
        } else if library.series.isEmpty {
            Button("Make Series…", systemImage: "square.stack") { seriesStart = article }
        } else {
            Menu("Add to Series", systemImage: "square.stack") {
                ForEach(library.series) { series in
                    Button(series.name) { library.add(article, to: series) }
                }
                Divider()
                Button("New Series…") { seriesStart = article }
            }
        }
        if article.mayHaveOtherChapters {
            Button("Find Other Chapters…", systemImage: "square.stack.3d.up") { chaptersStart = article }
        }
    }

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

    private static func count(of entries: [Entry]) -> String {
        let count = entries.reduce(0) { $0 + $1.articleCount }
        return "\(count) \(count == 1 ? "article" : "articles")"
    }

    private var bookPlaceholder: some View {
        Text(library.books.isEmpty ? "No books yet." : "No book selected.")
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReedStyle.warm)
    }

    private var readerPlaceholder: some View {
        VStack(spacing: 14) {
            Text(library.articles.isEmpty ? "No articles saved." : "No article selected.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Save an article", systemImage: "plus") { showingAdd = true }
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReedStyle.warm)
    }
}

#if os(iOS)
private extension View {
    /// Lets a pull down uncover `field`, a row `height` tall at the top of the list, as it would a
    /// navigation bar's search field: if `startHidden`, the list opens scrolled just past it. Scrolling
    /// never comes to rest with it partly shown; `next` is the row below it, which takes the top when it
    /// is hidden. A list too short to scroll it away keeps it shown. `tucked` follows how much of it is
    /// out of view, from 0 to 1. Does nothing before iOS 18.
    @ViewBuilder func pullToReveal(_ field: some Hashable, next: some Hashable, height: CGFloat, startHidden: Bool, tucked: Binding<CGFloat>) -> some View {
        if #available(iOS 18.0, *) {
            modifier(PullToReveal(field: field, next: next, height: height, startHidden: startHidden, fraction: tucked))
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
private struct PullToReveal<ID: Hashable, Next: Hashable>: ViewModifier {
    let field: ID
    let next: Next
    let height: CGFloat
    let startHidden: Bool
    @Binding var fraction: CGFloat
    /// How far the field is scrolled out of view, from 0 (fully shown) to `height` (fully hidden).
    @State private var tucked: CGFloat = 0
    /// Whether the field was last moving into view, so a short pull is enough to finish revealing it.
    @State private var opening = false
    /// How far the content can scroll, once laid out; lists shorter than the field just keep it in view.
    @State private var room: CGFloat?
    @State private var placed = false

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    min(max(0, geometry.contentOffset.y + geometry.contentInsets.top), height)
                } action: { old, new in
                    opening = new < old
                    tucked = new
                    fraction = height > 0 ? new / height : 0
                }
                .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                    guard geometry.contentSize.height > 0 else { return nil }
                    return geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                } action: { _, new in
                    room = new
                }
                .onScrollPhaseChange { _, phase in
                    guard phase == .idle, tucked > 0.5, tucked < height - 0.5 else { return }
                    let reveal = (room ?? 0) < height || tucked < height * (opening ? 0.75 : 0.25)
                    withAnimation(.snappy(duration: 0.25)) {
                        if reveal { proxy.scrollTo(field, anchor: .top) } else { proxy.scrollTo(next, anchor: .top) }
                    }
                }
                .onChange(of: height > 0 && room != nil, initial: true) { _, measured in
                    guard measured, let room, !placed else { return }
                    placed = true
                    if startHidden && room >= height { proxy.scrollTo(next, anchor: .top) }
                }
        }
    }
}

/// Fades `content` out as `hidden` goes from 0 to 1. It reads the binding itself, so only this view
/// updates while it changes.
private struct Fading<Content: View>: View {
    @Binding var hidden: CGFloat
    @ViewBuilder let content: Content
    var body: some View { content.opacity(1 - hidden) }
}
#endif

private struct ArticleRow: View {
    let article: Article
    /// The passage that matched a search, shown in place of the excerpt.
    let snippet: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(article.domain).font(.system(size: 9, weight: .semibold)).tracking(1.1)
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
