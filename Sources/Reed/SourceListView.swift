import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

extension ExternalSource {
    var symbol: String {
        switch self {
        case .hackerNews: "y.square"
        case .lobsters: "l.square"
        }
    }
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
/// again only when asked; feeds also when they are an hour old. Choosing a link saves it and opens it;
/// swiping saves it for later, or removes it again.
struct SourceListView: View {
    let library: Library
    let origin: Discover
    let open: (Article) -> Void
    let remove: (Article) -> Void
    @State private var openedID: String?
    @State private var failure: String?
    @State private var loading = false
    @State private var feedFilter: UUID?
    /// When the feeds were visited before this visit; entries posted since then are new.
    @State private var newSince: Date?
    @State private var visited = false
    @State private var showingAddFeed = false
    @State private var showingFeeds = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(origin.title).font(.system(size: 26, design: .serif))
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if origin == .feeds {
                    headerButton("Manage feeds", symbol: "list.bullet") { showingFeeds = true }
                }
                headerButton("Refresh (⌘R)", symbol: "arrow.clockwise") { Task { await load() } }
                    .disabled(isLoading).keyboardShortcut("r")
            }
            .padding(20)
            Divider()
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
        .navigationTitle(origin.title)
        #if os(macOS)
        .toolbar(removing: .title)
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(origin.title).font(.system(size: 19, design: .serif))
            }
            if origin == .feeds {
                ToolbarItem(placement: .primaryAction) {
                    Button("Manage feeds", systemImage: "list.bullet") { showingFeeds = true }
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private func headerButton(_ help: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered).clipShape(RoundedRectangle(cornerRadius: 9))
        .help(help).accessibilityLabel(help)
    }
    #endif

    private func row(for item: SourceItem) -> some View {
        let saved = library.article(at: item.url)
        return SourceRow(item: item, label: label(for: item), saved: saved != nil)
            .background(NavigationLink(value: item.id) { EmptyView() }.opacity(0))
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .swipeActions(edge: .trailing) {
                if let saved {
                    Button { remove(saved) } label: { Label("Remove", systemImage: "tray.and.arrow.up") }
                        .tint(.red)
                } else {
                    Button { save(item) } label: { Label("Save", systemImage: "tray.and.arrow.down") }
                        .tint(ReedStyle.accent)
                }
            }
            .contextMenu {
                if let saved {
                    Button("Remove from Library", systemImage: "tray.and.arrow.up", role: .destructive) { remove(saved) }
                } else {
                    Button("Save to Library", systemImage: "tray.and.arrow.down") { save(item) }
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
                Group {
                    Text("No feeds yet.").font(.system(size: 18, design: .serif))
                    Text("Subscribe to blogs and sites you like,\nand their new posts will gather here.")
                        .font(.system(size: 12)).multilineTextAlignment(.center).lineSpacing(3)
                }
                .foregroundStyle(.secondary)
                Button("Add a Feed") { showingAddFeed = true }.buttonStyle(.bordered)
            }
            .padding(30)
        } else if let failure = currentFailure, items?.isEmpty ?? true {
            VStack(spacing: 14) {
                Text("Couldn't load \(origin == .feeds ? "your feeds" : origin.title).").font(.system(size: 18, design: .serif))
                Text(failure).font(.system(size: 12)).multilineTextAlignment(.center)
                Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
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

    private func label(for item: SourceItem) -> String {
        guard let feedID = item.feedID, let feed = library.feeds.first(where: { $0.id == feedID }) else { return item.domain }
        return feed.title
    }

    private var summary: String {
        switch origin {
        case .frontPage(let source):
            guard let page = library.frontPages[source] else { return loading ? "Loading…" : " " }
            if loading { return "Refreshing…" }
            if failure != nil { return "Couldn't refresh" }
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

    /// Saving happens as the row is chosen, so the article is ready by the time its page is shown.
    private func choose(_ id: String?) {
        openedID = id
        guard let item = items?.first(where: { $0.id == id }), let article = save(item) else { return }
        open(article)
    }

    @discardableResult private func save(_ item: SourceItem) -> Article? {
        do { return try library.add(item.url.absoluteString) }
        catch { library.errorMessage = error.localizedDescription; return nil }
    }
}

private struct SourceRow: View {
    let item: SourceItem
    /// The site or feed the link comes from.
    let label: String
    let saved: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(label.lowercased()).font(.system(size: 9, weight: .semibold)).tracking(1.1).lineLimit(1)
                Spacer()
                if saved {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                        Text("Saved")
                    }
                    .font(.system(size: 9, weight: .medium))
                }
            }.foregroundStyle(ReedStyle.accent)
            Text(item.title).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(3).lineSpacing(2)
            if let excerpt = item.excerpt, excerpt != item.title {
                Text(excerpt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
            }
            if !details.isEmpty {
                Text(details).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 15).padding(.horizontal, 7)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts: [String] = []
        if let points = item.points { parts.append("\(points) \(points == 1 ? "point" : "points")") }
        if let comments = item.comments { parts.append("\(comments) \(comments == 1 ? "comment" : "comments")") }
        if let author = item.author { parts.append("by \(author)") }
        if let postedAt = item.postedAt { parts.append(postedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))) }
        return parts.joined(separator: " · ")
    }
}
