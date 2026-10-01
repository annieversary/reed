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

/// A source's front page, as last fetched; it is fetched again only when asked. Choosing a link saves
/// it and opens it; swiping saves it for later, or removes it again.
struct SourceListView: View {
    let library: Library
    let source: ExternalSource
    let open: (Article) -> Void
    let remove: (Article) -> Void
    @State private var openedID: String?
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.rawValue).font(.system(size: 26, design: .serif))
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered).clipShape(RoundedRectangle(cornerRadius: 9))
                .disabled(loading).help("Refresh (⌘R)").accessibilityLabel("Refresh")
                .keyboardShortcut("r")
            }
            .padding(20)
            Divider()
            #endif
            List(selection: Binding(get: { openedID }, set: choose)) {
                #if os(iOS)
                if page != nil {
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
                #endif
                ForEach(items ?? []) { item in
                    let saved = library.article(at: item.url)
                    SourceRow(item: item, saved: saved != nil)
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
            }
            .listStyle(.plain)
            #if os(iOS)
            .environment(\.defaultMinListRowHeight, 0)
            #endif
            .refreshable { await load() }
            .overlay {
                if let failure, items?.isEmpty ?? true {
                    VStack(spacing: 14) {
                        Text("Couldn't load \(source.rawValue).").font(.system(size: 18, design: .serif))
                        Text(failure).font(.system(size: 12)).multilineTextAlignment(.center)
                        Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                    }
                    .foregroundStyle(.secondary).padding(30)
                } else if items == nil {
                    ProgressView()
                }
            }
        }
        .task { if page == nil { await load() } }
        .navigationTitle(source.rawValue)
        #if os(macOS)
        .toolbar(removing: .title)
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(source.rawValue).font(.system(size: 19, design: .serif))
            }
        }
        #endif
    }

    private var page: FrontPage? { library.frontPages[source] }
    private var items: [SourceItem]? { page?.items }

    private var summary: String {
        guard let page else { return loading ? "Loading…" : " " }
        if loading { return "Refreshing…" }
        if failure != nil { return "Couldn't refresh" }
        return "Updated \(page.fetchedAt.formatted(.relative(presentation: .named)))"
    }

    private func load() async {
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
    let saved: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(item.domain.lowercased()).font(.system(size: 9, weight: .semibold)).tracking(1.1)
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
            Text(details).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
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
