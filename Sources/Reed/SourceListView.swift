import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

extension ExternalSource {
    var symbol: String {
        switch self {
        case .hackerNews: "y.square"
        case .lobsters: "l.square"
        case .substack: "s.square"
        }
    }

    /// What the source calls a vote for a story.
    var pointName: String { self == .substack ? "like" : "point" }
}

/// Where a list of links to browse comes from.
enum Discover: Hashable {
    case frontPage(ExternalSource), feeds

    var title: String {
        switch self {
        case .frontPage(let source): source.rawValue
        case .feeds: "Feeds"
        }
    }
}

/// A source's front page, or every subscribed feed together, as last fetched. Front pages are fetched
/// again only when asked; feeds also when they are an hour old. Choosing a link opens it without saving
/// it, from the copy cached ahead; swiping saves it for later, or removes it again.
struct SourceListView: View {
    let library: Library
    let origin: Discover
    let open: (Article) -> Void
    @State private var openedID: String?
    @State private var failure: String?
    @State private var loading = false
    @State private var feedFilter: UUID?
    /// When the feeds were visited before this visit; entries posted since then are new.
    @State private var newSince: Date?
    @State private var visited = false
    @State private var showingAddFeed = false
    @State private var showingFeeds = false
    /// The story whose comments are showing.
    @State private var commentsFor: (article: Article, site: DiscussionSite)?

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            ColumnHeader(title: origin.title, subtitle: summary) {
                if origin == .feeds {
                    HeaderButton(help: "Manage feeds", symbol: "list.bullet") { showingFeeds = true }
                }
                HeaderButton(help: "Refresh (⌘R)", symbol: "arrow.clockwise") { Task { await load() } }
                    .disabled(isLoading).keyboardShortcut("r")
            }
            #endif
            if origin == .feeds && library.feeds.count > 1 { feedChips }
            List(selection: Binding(get: { openedID }, set: choose)) {
                #if os(iOS)
                if hasContent {
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
                #endif
                let items = items ?? []
                let firstSeen = firstSeenIndex(in: items)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index == firstSeen { seenDivider }
                    row(for: item)
                }
            }
            .listStyle(.plain)
            #if os(iOS)
            .environment(\.defaultMinListRowHeight, 0)
            #endif
            .refreshable { await load() }
            .overlay { emptyState }
        }
        .task {
            switch origin {
            case .frontPage:
                if items == nil { await load() }
            case .feeds:
                // Returning from an article is the same visit.
                if !visited { newSince = library.visitFeeds(); visited = true }
                let updated = library.feeds.compactMap(\.fetchedAt).min()
                if updated.map({ Date.now.timeIntervalSince($0) > 3600 }) ?? true { await load() }
            }
        }
        .sheet(isPresented: $showingAddFeed) { AddFeedView(library: library) }
        .sheet(isPresented: $showingFeeds) { ManageFeedsView(library: library) }
        .sheet(isPresented: Binding(get: { commentsFor != nil }, set: { if !$0 { commentsFor = nil } })) {
            if let commentsFor {
                DiscussionView(library: library, article: commentsFor.article,
                               isPresented: Binding(get: { self.commentsFor != nil }, set: { if !$0 { self.commentsFor = nil } }),
                               showsDone: true, selected: commentsFor.site)
                #if os(macOS)
                .frame(minWidth: 520, idealWidth: 620, minHeight: 560, idealHeight: 760)
                #endif
            }
        }
        .columnTitle(origin.title) {
            if origin == .feeds {
                Button("Manage feeds", systemImage: "list.bullet") { showingFeeds = true }
            }
        }
    }

    private func row(for item: SourceItem) -> some View {
        let saved = library.article(at: item.url)
        return SourceRow(item: item, label: label(for: item), saved: saved != nil, pointName: pointName)
            .readFading(saved ?? library.cachedArticle(at: item.url))
            .listLink(value: item.id, insets: EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .swipeActions(edge: .trailing) {
                if let saved {
                    Button { library.removeFromLibrary(saved) } label: { Label("Remove", systemImage: "tray.and.arrow.up") }
                        .tint(.red)
                } else {
                    Button { save(item) } label: { Label("Save", systemImage: "tray.and.arrow.down") }
                        .tint(ReedStyle.accent)
                }
            }
            .contextMenu {
                if let saved {
                    Button("Remove from Library", systemImage: "tray.and.arrow.up", role: .destructive) { library.removeFromLibrary(saved) }
                } else {
                    Button("Save to Library", systemImage: "tray.and.arrow.down") { save(item) }
                }
                if let site = item.discussionURL.flatMap(DiscussionSite.init(url:)) {
                    Button("Comments", systemImage: "text.bubble") {
                        if let article = library.readable(at: item.url, discussion: item.discussionURL) { commentsFor = (article, site) }
                    }
                }
            }
    }

    private var feedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", selected: activeFilter == nil) { feedFilter = nil }
                ForEach(library.feeds) { feed in
                    chip(feed.title, selected: activeFilter == feed.id) { feedFilter = feed.id }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? AnyShapeStyle(ReedStyle.accent) : AnyShapeStyle(ReedStyle.warm), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var seenDivider: some View {
        HStack(spacing: 10) {
            Rectangle().frame(height: 0.5)
            Text("SEEN BEFORE").font(.system(size: 9, weight: .medium)).tracking(1.4).fixedSize()
            Rectangle().frame(height: 0.5)
        }
        .foregroundStyle(.tertiary)
        .padding(.vertical, 8).padding(.horizontal, 7)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .selectionDisabled()
        .accessibilityLabel("Seen before")
    }

    @ViewBuilder private var emptyState: some View {
        if origin == .feeds && library.feeds.isEmpty {
            VStack(spacing: 14) {
                Text("No feeds yet.").font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
                Button("Add a Feed") { showingAddFeed = true }.buttonStyle(.reedSecondary)
            }
            .padding(30)
        } else if let failure = currentFailure, items?.isEmpty ?? true {
            VStack(spacing: 14) {
                Text("Couldn't load \(origin == .feeds ? "your feeds" : origin.title).").font(.system(size: 18, design: .serif))
                Text(failure).font(.system(size: 12)).multilineTextAlignment(.center)
                Button("Try Again") { Task { await load() } }.buttonStyle(.reedSecondary)
            }
            .foregroundStyle(.secondary).padding(30)
        } else if items == nil || (items?.isEmpty == true && isLoading) {
            ProgressView()
        } else if items?.isEmpty == true {
            Text("Nothing here yet.").font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
        }
    }

    /// The chosen feed, while it is still subscribed.
    private var activeFilter: UUID? {
        library.feeds.contains { $0.id == feedFilter } ? feedFilter : nil
    }

    private var items: [SourceItem]? {
        switch origin {
        case .frontPage(let source):
            library.frontPages[source]?.items
        case .feeds:
            if let activeFilter { library.feeds.first { $0.id == activeFilter }?.items } else { library.feedItems }
        }
    }

    private var hasContent: Bool {
        switch origin {
        case .frontPage(let source): library.frontPages[source] != nil
        case .feeds: !library.feeds.isEmpty
        }
    }

    private var isLoading: Bool { loading || (origin == .feeds && library.refreshingFeeds) }

    private var currentFailure: String? {
        switch origin {
        case .frontPage: failure
        // Only worth a message when nothing could be fetched at all.
        case .feeds: library.feeds.allSatisfy { $0.failure != nil } ? library.feeds.first?.failure : nil
        }
    }

    /// Where entries the reader has already had a chance to see begin, if there are new ones above them.
    private func firstSeenIndex(in items: [SourceItem]) -> Int? {
        guard origin == .feeds, let newSince,
              let index = items.firstIndex(where: { ($0.postedAt ?? .distantPast) <= newSince }), index > 0 else { return nil }
        return index
    }

    private var pointName: String {
        if case .frontPage(let source) = origin { source.pointName } else { "point" }
    }

    private func label(for item: SourceItem) -> String {
        if let site = item.site { return site }
        guard let feedID = item.feedID, let feed = library.feeds.first(where: { $0.id == feedID }) else { return item.domain }
        return feed.title
    }

    private var summary: String {
        switch origin {
        case .frontPage(let source):
            guard let page = library.frontPages[source] else { return loading ? "Loading…" : " " }
            if loading { return "Refreshing…" }
            if failure != nil { return "Couldn't refresh" }
            let states = page.items.compactMap { (library.article(at: $0.url) ?? library.cachedArticle(at: $0.url))?.state }
            if states.contains(where: { $0 == .queued || $0 == .downloading }) {
                return "Downloaded \(states.filter(\.isReadable).count) of \(page.items.count) articles"
            }
            return "Updated \(page.fetchedAt.formatted(.relative(presentation: .named)))"
        case .feeds:
            let feeds = library.feeds
            guard !feeds.isEmpty else { return " " }
            var parts = ["\(feeds.count) \(feeds.count == 1 ? "feed" : "feeds")"]
            if isLoading {
                parts.append("Refreshing…")
            } else if let updated = feeds.compactMap(\.fetchedAt).max() {
                parts.append("Updated \(updated.formatted(.relative(presentation: .named)))")
            }
            let failing = feeds.filter { $0.failure != nil }.count
            if failing > 0 && !isLoading { parts.append("\(failing) couldn't refresh") }
            return parts.joined(separator: " · ")
        }
    }

    private func load() async {
        switch origin {
        case .feeds:
            await library.refreshFeeds()
        case .frontPage(let source):
            guard !loading else { return }
            loading = true
            defer { loading = false }
            do {
                try await library.refreshFrontPage(of: source)
                failure = nil
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func choose(_ id: String?) {
        openedID = id
        guard let item = items?.first(where: { $0.id == id }), let article = library.readable(at: item.url, discussion: item.discussionURL) else { return }
        open(article)
    }

    @discardableResult private func save(_ item: SourceItem) -> Article? {
        do { return try library.add(item.url.absoluteString, discussion: item.discussionURL) }
        catch { library.errorMessage = error.localizedDescription; return nil }
    }
}

private struct SourceRow: View {
    let item: SourceItem
    /// The site or feed the link comes from.
    let label: String
    let saved: Bool
    /// What the source calls a vote, such as "point".
    let pointName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(label.lowercased()).font(.system(size: 9, weight: .semibold)).tracking(1.1).lineLimit(1)
                Spacer()
                tag
            }.foregroundStyle(ReedStyle.accent)
            Text(item.title).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(3).lineSpacing(2)
            if let excerpt = item.excerpt, excerpt != item.title {
                Text(excerpt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
            }
            if !details.isEmpty {
                Text(details).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if case .note(let author, let text) = item.reason {
                VStack(alignment: .leading, spacing: 2) {
                    Text(author).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(text).font(.system(size: 11)).lineLimit(4).lineSpacing(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(ReedStyle.warm, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.vertical, 15).padding(.horizontal, 7)
        .accessibilityElement(children: .combine)
    }

    /// One mark beside the label, the most useful first: whether it's saved, paid, or why it was picked.
    @ViewBuilder private var tag: some View {
        if saved {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                Text("Saved")
            }
            .font(.system(size: 9, weight: .medium))
        } else if item.paid == true {
            tag("paid", symbol: "lock", spoken: "Paid")
        } else {
            switch item.reason {
            case .restacked(let name): tag(name, symbol: "arrow.2.squarepath", spoken: "Restacked by")
            case .liked(let name): tag(name, symbol: "heart", spoken: "Liked by")
            case .fromArchives: tag("from the archives")
            case .note, nil: EmptyView()
            }
        }
    }

    private func tag(_ text: String, symbol: String? = nil, spoken: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).accessibilityLabel(spoken ?? "") }
            Text(text.lowercased()).tracking(1.1).lineLimit(1)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private var details: String {
        var parts: [String] = []
        // A paid post's counts are often missing, and only its preview can be read.
        if item.paid != true {
            if let points = item.points { parts.append("\(points) \(pointName)\(points == 1 ? "" : "s")") }
            if let comments = item.comments { parts.append("\(comments) \(comments == 1 ? "comment" : "comments")") }
        }
        if let author = item.author { parts.append("by \(author)") }
        if let words = item.wordCount, words > 0 {
            parts.append(item.paid == true ? "\(words.formatted()) words" : "\(Article.readingMinutes(words: words)) min")
        }
        if let postedAt = item.postedAt {
            parts.append(item.reason == .fromArchives
                ? postedAt.formatted(date: .abbreviated, time: .omitted)
                : postedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
        }
        return parts.joined(separator: " · ")
    }
}
