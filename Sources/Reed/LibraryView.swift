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

struct LibraryView: View {
    @Bindable var library: Library
    @State private var filter: CollectionFilter? = .all
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var showingAdd = false
    @State private var articleToDelete: Article?
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var searchRevealed = false
    @FocusState private var searchFocused: Bool

    private var visibleArticles: [Article] {
        library.articles.filter {
            (filter ?? .all).includes($0) && (query.isEmpty ||
                [$0.title, $0.domain, $0.author ?? "", $0.excerpt].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    private var selectedArticle: Article? { library.articles.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } content: {
            articleList
                .navigationSplitViewColumnWidth(min: 270, ideal: 340, max: 430)
        } detail: {
            if let article = selectedArticle {
                ArticleDetailView(library: library, article: article)
            } else {
                readerPlaceholder
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddArticleView { url in
                let article = try library.add(url)
                filter = .all
                query = ""
                selectedID = article.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reedAddArticle)) { _ in showingAdd = true }
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
                    library.delete(article)
                }
                articleToDelete = nil
            }
        } message: { Text("Its offline copy will be removed from this device.") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "leaf").font(.system(size: 24, weight: .light)).foregroundStyle(ReedStyle.accent)
                Text("reed").font(.system(size: 34, weight: .regular, design: .serif)).tracking(-1.8)
                Spacer()
            }
            .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 30)
            List(selection: $filter) {
                Section {
                    ForEach(CollectionFilter.allCases) { item in
                        NavigationLink(value: item) {
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
                if searchVisible {
                    searchField
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                }
                Text(articleCount).font(.system(size: 11)).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                #endif
                ForEach(visibleArticles) { article in
                    // A hidden link keeps row navigation without the disclosure chevron.
                    ArticleRow(article: article)
                        .background(NavigationLink(value: article.id) { EmptyView() }.opacity(0))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
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
            #if os(iOS)
            .environment(\.defaultMinListRowHeight, 0)
            .onPullDown {
                withAnimation { searchRevealed = true }
                searchFocused = true
            }
            .onChange(of: searchFocused) { _, focused in
                if !focused && query.isEmpty { withAnimation { searchRevealed = false } }
            }
            #endif
            .overlay {
                if visibleArticles.isEmpty {
                    Text(query.isEmpty ? "No articles saved." : "No articles found.").font(.system(size: 18, design: .serif))
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
    /// Search hides until a pull-down reveals it; without scroll geometry (before iOS 18) it always shows.
    private var searchVisible: Bool {
        if #available(iOS 18.0, *) { searchRevealed || !query.isEmpty } else { true }
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
    /// Runs `action` when the user drags the scroll view past its top edge. Does nothing before iOS 18.
    @ViewBuilder func onPullDown(perform action: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top < -60 } action: { _, pulled in
                if pulled { action() }
            }
        } else {
            self
        }
    }
}
#endif

private struct ArticleRow: View {
    let article: Article
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(article.domain.lowercased()).font(.system(size: 9, weight: .semibold)).tracking(1.1)
                Spacer()
                if article.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)) }
            }.foregroundStyle(ReedStyle.accent)
            Text(article.title).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(3).lineSpacing(2)
            if !article.excerpt.isEmpty {
                Text(article.excerpt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
            }
            HStack(spacing: 5) {
                if article.state == .downloading || article.state == .queued { ProgressView().controlSize(.mini) }
                else { Image(systemName: article.state.isReadable ? "checkmark.circle" : "exclamationmark.circle").font(.system(size: 10)) }
                Text(article.state.isReadable ? "\(article.readingMinutes) min read" : article.state.label)
                if article.state == .partial { Image(systemName: "photo.badge.exclamationmark") }
                Spacer()
                Text(article.isRead ? "Finished" : article.savedAt.formatted(.dateTime.month(.abbreviated).day()))
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(.vertical, 15).padding(.horizontal, 7)
        .accessibilityElement(children: .combine)
    }
}
