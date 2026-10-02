import Foundation
import Observation
import SwiftData

@MainActor @Observable
public final class Library {
    public private(set) var articles: [Article] = []
    /// Front-page stories downloaded ahead to read offline, kept outside the library until saved.
    public private(set) var cached: [Article] = []
    /// Cached articles kept even once they leave the front pages, such as the one being read.
    public var retained: Set<UUID> = []
    public var errorMessage: String?
    public private(set) var activity: String?
    /// Image progress of the article being saved, such as "Saving image 2 of 5…".
    public private(set) var imageActivity: String?
    /// The front page last fetched from each source, kept between launches.
    public private(set) var frontPages: [ExternalSource: FrontPage] = [:]
    /// Subscribed feeds, in the order they were added.
    public private(set) var feeds: [Feed] = [] { didSet { feedItems = Self.river(of: feeds) } }
    /// Entries from every feed, newest first, each link only once.
    public private(set) var feedItems: [SourceItem] = []
    /// When the feeds were last looked at, so what has arrived since can be told apart.
    public private(set) var feedsVisitedAt: Date?
    public private(set) var refreshingFeeds = false
    /// Advances whenever the search index changes, so searches can be rerun.
    public private(set) var searchRevision = 0
    public let container: ModelContainer
    public let storage: ArticleStorage
    private let downloader: ArticleDownloader
    private let extractor = ArticleExtractor()
    private let searchIndex: SearchIndex
    private var worker: Task<Void, Never>?
    private var progressSave: Task<Void, Never>?
    /// Articles removed while downloading, deleted once their download settles.
    private var discarded: Set<UUID> = []

    public init(root: URL? = nil, downloader: ArticleDownloader = ArticleDownloader()) throws {
        let root = try root ?? ArticleStorage.defaultRoot()
        storage = try ArticleStorage(root: root)
        self.downloader = downloader
        let configuration = ModelConfiguration(url: root.appendingPathComponent("Library.store"))
        container = try ModelContainer(for: Article.self, configurations: configuration)
        searchIndex = try SearchIndex(url: root.appendingPathComponent("Search.sqlite"))
        let stored = try container.mainContext.fetch(FetchDescriptor<Article>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)]))
        articles = stored.filter { !$0.isCached }
        cached = stored.filter(\.isCached)
        try storage.cleanStaging()
        for article in stored {
            if article.state == .downloading { article.state = .queued }
            if article.state.isReadable && contentURL(for: article) == nil {
                article.state = .failed
                article.failureMessage = ReedError.damagedArticle.localizedDescription
            }
        }
        try container.mainContext.save()
        for source in ExternalSource.allCases {
            if let data = try? Data(contentsOf: Self.frontPageURL(root: root, source: source)),
               let page = try? JSONDecoder().decode(FrontPage.self, from: data) {
                frontPages[source] = page
            }
        }
        syncCache()
        if let data = try? Data(contentsOf: Self.feedsURL(root: root)),
           let store = try? JSONDecoder().decode(FeedStore.self, from: data) {
            feeds = store.feeds
            feedItems = Self.river(of: feeds)
            feedsVisitedAt = store.visitedAt
        }
        let entries = articles.map(searchEntry)
        Task { [weak self, searchIndex] in
            try? await searchIndex.sync(entries)
            self?.searchRevision += 1
        }
    }

    @discardableResult public func add(_ input: String) throws -> Article {
        let url = try ArticleURL.parse(input)
        if let existing = article(at: url) { return existing }
        if let cached = cachedArticle(at: url) { keep(cached); return cached }
        let article = Article(url: url)
        container.mainContext.insert(article)
        do { try container.mainContext.save() }
        catch { container.mainContext.delete(article); throw error }
        articles.insert(article, at: 0)
        reindex(article)
        resumeDownloads()
        return article
    }

    /// The saved article for `url`, whether saved from that link or redirected to it.
    public func article(at url: URL) -> Article? {
        articles.first { $0.isAt(url) }
    }

    public func cachedArticle(at url: URL) -> Article? {
        cached.first { $0.isAt(url) }
    }

    /// The copy of `url` to read: the saved one, else the cached one, cached now if need be.
    public func readable(at url: URL) -> Article? {
        if let saved = article(at: url) { return saved }
        let article: Article
        if let existing = cachedArticle(at: url) {
            article = existing
            if article.state == .failed { article.state = .queued; save() }
        } else {
            article = Article(url: url)
            article.isCached = true
            container.mainContext.insert(article)
            do { try container.mainContext.save() }
            catch { container.mainContext.delete(article); errorMessage = error.localizedDescription; return nil }
        }
        // Cached articles download in order, so the one being opened goes first.
        cached.removeAll { $0.id == article.id }
        cached.insert(article, at: 0)
        resumeDownloads()
        return article
    }

    /// Moves a cached article into the library, without downloading it again.
    public func keep(_ article: Article) {
        guard article.isCached else { return }
        article.isCached = false
        article.savedAt = .now
        if article.state == .failed { article.state = .queued; article.failureMessage = nil }
        save()
        cached.removeAll { $0.id == article.id }
        articles.insert(article, at: 0)
        reindex(article)
        resumeDownloads()
    }

    /// Takes the article out of the library but keeps its copy cached, so it stays readable while it is open
    /// or on a front page.
    public func removeFromLibrary(_ article: Article) {
        guard !article.isCached else { return }
        article.isCached = true
        article.isFavorite = false
        save()
        articles.removeAll { $0.id == article.id }
        cached.append(article)
        let id = article.id
        Task { [weak self, searchIndex] in
            try? await searchIndex.remove(id)
            self?.searchRevision += 1
        }
    }

    /// Caches each front-page story that isn't in the library, in front-page order, and drops cached ones
    /// no longer on any front page.
    private func syncCache() {
        var kept: [Article] = []
        for item in ExternalSource.allCases.flatMap({ frontPages[$0]?.items ?? [] })
        where article(at: item.url) == nil && !kept.contains(where: { $0.isAt(item.url) }) {
            if let existing = cachedArticle(at: item.url) {
                // Earlier failures are often just being offline.
                if existing.state == .failed { existing.state = .queued; existing.failureMessage = nil }
                kept.append(existing)
            } else {
                let article = Article(url: item.url)
                article.isCached = true
                container.mainContext.insert(article)
                kept.append(article)
            }
        }
        for article in cached where !kept.contains(where: { $0.id == article.id }) {
            if retained.contains(article.id) { kept.append(article) }
            else if article.state == .downloading { discarded.insert(article.id) }
            else { erase(article) }
        }
        cached = kept
        save()
    }

    public func refreshFrontPage(of source: ExternalSource) async throws {
        let page = FrontPage(items: try await source.frontPage(using: downloader), fetchedAt: .now)
        frontPages[source] = page
        syncCache()
        resumeDownloads()
        // The cache only spares a fetch at launch, so failing to write it isn't worth reporting.
        let url = Self.frontPageURL(root: storage.root, source: source)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(page).write(to: url, options: .atomic)
    }

    static func frontPageURL(root: URL, source: ExternalSource) -> URL {
        root.appendingPathComponent("FrontPages", isDirectory: true).appendingPathComponent(source.key + ".json")
    }

    /// The feeds at `input`: the address itself if it is a feed, otherwise the feeds the page links to.
    public func findFeeds(at input: String) async throws -> [FeedCandidate] {
        let url = try ArticleURL.parse(input)
        guard case .fetched(let data, let finalURL, _, _) = try await downloader.feed(at: url) else { throw ReedError.noFeed }
        if let parsed = await Self.parse(data, from: finalURL) {
            return [FeedCandidate(url: finalURL, title: parsed.title ?? finalURL.host() ?? finalURL.absoluteString)]
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else { throw ReedError.noFeed }
        let found = FeedParser.discover(in: html, base: finalURL)
        if found.isEmpty { throw ReedError.noFeed }
        return found
    }

    @discardableResult public func subscribe(to url: URL) async throws -> Feed {
        if let existing = feed(at: url) { return existing }
        guard case .fetched(let data, let finalURL, let etag, let lastModified) = try await downloader.feed(at: url),
              let parsed = await Self.parse(data, from: finalURL) else { throw ReedError.noFeed }
        if let existing = feed(at: url) ?? feed(at: finalURL) { return existing }
        let feed = Feed(url: finalURL, parsed: parsed, fetchedAt: .now, etag: etag, lastModified: lastModified)
        feeds.append(feed)
        do { try saveFeeds() } catch { feeds.removeAll { $0.id == feed.id }; throw error }
        return feed
    }

    public func feed(at url: URL) -> Feed? { feeds.first { $0.url == url } }

    public func unsubscribe(_ feed: Feed) {
        let previous = feeds
        feeds.removeAll { $0.id == feed.id }
        do { try saveFeeds() } catch { feeds = previous; errorMessage = error.localizedDescription }
    }

    /// Fetches every feed again. A feed that fails keeps its earlier entries and records why.
    public func refreshFeeds() async {
        guard !refreshingFeeds, !feeds.isEmpty else { return }
        refreshingFeeds = true
        defer { refreshingFeeds = false }
        let results = await Self.fetch(feeds.map { FeedRequest(id: $0.id, url: $0.url, etag: $0.etag, lastModified: $0.lastModified) },
                                       using: downloader)
        let now = Date.now
        // Applied by identity, so feeds added or removed during the refresh stay that way.
        feeds = feeds.map { feed in
            var feed = feed
            switch results[feed.id] {
            case nil, .failure(is CancellationError): break
            case .success(nil): feed.fetchedAt = now; feed.failure = nil
            case .success(let fetched?):
                feed.update(with: fetched.feed, at: now)
                feed.etag = fetched.etag
                feed.lastModified = fetched.lastModified
            case .failure(let error): feed.failure = error.localizedDescription
            }
            return feed
        }
        // Subscriptions are unchanged by a refresh, so failing to write only loses the cache.
        try? saveFeeds()
    }

    /// Records a visit to the feeds, returning when they were visited before.
    public func visitFeeds() -> Date? {
        let previous = feedsVisitedAt
        feedsVisitedAt = .now
        try? saveFeeds()
        return previous
    }

    private struct FeedStore: Codable {
        var feeds: [Feed]
        var visitedAt: Date?
    }

    private struct FeedRequest: Sendable {
        let id: UUID, url: URL, etag: String?, lastModified: String?
    }

    private struct FetchedFeed: Sendable {
        let feed: ParsedFeed, etag: String?, lastModified: String?
    }

    /// Each feed's new contents, or nil where it hasn't changed.
    private nonisolated static func fetch(_ requests: [FeedRequest], using downloader: ArticleDownloader) async -> [UUID: Result<FetchedFeed?, any Error>] {
        await withTaskGroup(of: (UUID, Result<FetchedFeed?, any Error>).self) { group in
            for request in requests {
                group.addTask {
                    do {
                        switch try await downloader.feed(at: request.url, etag: request.etag, lastModified: request.lastModified) {
                        case .unchanged: return (request.id, .success(nil))
                        case .fetched(let data, let url, let etag, let lastModified):
                            guard let parsed = FeedParser.parse(data, from: url) else { throw ReedError.unreadableFeed }
                            return (request.id, .success(FetchedFeed(feed: parsed, etag: etag, lastModified: lastModified)))
                        }
                    } catch { return (request.id, .failure(error)) }
                }
            }
            var results: [UUID: Result<FetchedFeed?, any Error>] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
    }

    private nonisolated static func parse(_ data: Data, from url: URL) async -> ParsedFeed? {
        FeedParser.parse(data, from: url)
    }

    nonisolated static func river(of feeds: [Feed]) -> [SourceItem] {
        var seen = Set<URL>()
        return feeds.flatMap(\.items)
            .sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
            .filter { seen.insert($0.url).inserted }
            .prefix(300)
            .map { $0 }
    }

    private func saveFeeds() throws {
        try JSONEncoder().encode(FeedStore(feeds: feeds, visitedAt: feedsVisitedAt)).write(to: Self.feedsURL(root: storage.root), options: .atomic)
    }

    static func feedsURL(root: URL) -> URL { root.appendingPathComponent("Feeds.json") }

    public func addShared(from inbox: ShareInbox) {
        do {
            try inbox.drain { input in
                // Links that can never be saved are dropped rather than retried forever.
                do { try add(input) } catch ReedError.invalidURL {}
            }
        } catch { errorMessage = error.localizedDescription }
    }

    public func resumeDownloads() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.activity = nil; self.imageActivity = nil }
            while let article = self.articles.last(where: { $0.state == .queued }) ?? self.cached.first(where: { $0.state == .queued }) {
                if Task.isCancelled { break }
                await self.download(article)
            }
        }
    }

    public func retry(_ article: Article) {
        guard article.state != .downloading && article.state != .queued else { return }
        article.state = .queued
        article.failureMessage = nil
        save()
        resumeDownloads()
    }

    public func delete(_ article: Article) {
        // Active downloads cannot be deleted until they settle, avoiding orphaned work.
        guard article.state != .downloading else { return }
        let id = article.id
        guard let index = articles.firstIndex(where: { $0.id == id }) else { return }
        if erase(article) { articles.remove(at: index) }
    }


    /// Whether the article's metadata is gone; leftover files are reported but don't count against it.
    @discardableResult private func erase(_ article: Article) -> Bool {
        let id = article.id
        container.mainContext.delete(article)
        do { try container.mainContext.save() } catch { errorMessage = error.localizedDescription; return false }
        Task { [searchIndex] in try? await searchIndex.remove(id) }
        do { try storage.removeArticle(id) } catch { errorMessage = error.localizedDescription }
        return true
    }

    /// Favoriting a cached article saves it, so it isn't dropped with the front page.
    public func toggleFavorite(_ article: Article) {
        article.isFavorite.toggle()
        if article.isFavorite && article.isCached { keep(article) } else { save() }
    }
    public func toggleRead(_ article: Article) { article.isRead.toggle(); save() }

    public func updateProgress(_ article: Article, value: Double) {
        guard value.isFinite else { return }
        article.progress = min(max(value, 0), 1)
        if value >= 0.95 { article.isRead = true }
        progressSave?.cancel()
        progressSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self?.save()
        }
    }

    public func save() {
        do { try container.mainContext.save() } catch { errorMessage = error.localizedDescription }
    }

    public func contentURL(for article: Article) -> URL? {
        guard let version = article.contentVersion else { return nil }
        let url = storage.contentURL(article.id, version: version)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The saved article's text to read aloud, or nil if it isn't saved.
    public func passages(for article: Article) -> [String]? {
        guard let url = contentURL(for: article), let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ArticleSpeech.passages(title: article.title, html: html)
    }

    /// The first image saved with the article, if any.
    public func leadImage(for article: Article) -> URL? {
        guard let url = contentURL(for: article), let html = try? String(contentsOf: url, encoding: .utf8),
              let source = ArticleHTML.firstImage(in: html) else { return nil }
        let image = url.deletingLastPathComponent().appendingPathComponent(source)
        return FileManager.default.fileExists(atPath: image.path) ? image : nil
    }

    public func search(_ text: String) async -> [SearchIndex.Match] {
        (try? await searchIndex.search(text)) ?? []
    }

    // Index failures aren't surfaced: the index is brought up to date again at every launch.
    private func reindex(_ article: Article) {
        let entry = searchEntry(for: article)
        Task { [weak self, searchIndex] in
            try? await searchIndex.index(entry)
            self?.searchRevision += 1
        }
    }

    private func searchEntry(for article: Article) -> SearchIndex.Entry {
        SearchIndex.Entry(id: article.id, version: article.contentVersion, title: article.title, author: article.author,
                          domain: article.domain, content: contentURL(for: article))
    }

    private func download(_ article: Article) async {
        article.state = .downloading
        save()
        var staging: URL?
        // Caching happens quietly; only saving to the library is reported.
        func report(_ message: String) { if !article.isCached { activity = message } }
        defer {
            imageActivity = nil
            if let staging { try? FileManager.default.removeItem(at: staging) }
        }
        do {
            report("Fetching \(article.domain)…")
            let page = try await downloader.page(at: ArticleURL.parse(article.originalURL))
            report("Finding the article…")
            let extracted = try await extractor.extract(html: page.html, url: page.url) { [downloader] url in
                String(decoding: try await downloader.json(at: url), as: UTF8.self)
            }
            let directory = try storage.createStagingDirectory()
            staging = directory
            var body = extracted.html
            var missing = 0
            var totalBytes = 0
            for (index, image) in extracted.images.enumerated() {
                try Task.checkCancellation()
                let message = "Saving image \(index + 1) of \(extracted.images.count)…"
                imageActivity = message
                report(message)
                do {
                    guard index < 40, totalBytes < 64 * 1024 * 1024, let url = URL(string: image.url) else {
                        throw ReedError.oversizedDownload
                    }
                    let data = try await downloader.image(at: url)
                    guard totalBytes + data.count <= 64 * 1024 * 1024 else { throw ReedError.oversizedDownload }
                    try data.write(to: directory.appendingPathComponent(image.filename), options: .atomic)
                    totalBytes += data.count
                } catch is CancellationError { throw CancellationError() }
                catch {
                    missing += 1
                    // Preserve alt text, but never leave a remote or broken image request in the reader.
                    let pattern = "<img\\b[^>]*\\bsrc=\"" + NSRegularExpression.escapedPattern(for: image.filename) + "\"[^>]*>"
                    let replacement = "<span class=\"missing-image\">[Image unavailable\(image.alt.isEmpty ? "" : ": " + ArticleHTML.escape(image.alt))]</span>"
                    let regex = try NSRegularExpression(pattern: pattern)
                    body = regex.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body),
                                                          withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
                }
            }
            let document = ArticleHTML.document(title: extracted.title, author: extracted.author,
                                                domain: page.url.host() ?? "", minutes: max(1, Int(ceil(Double(extracted.wordCount) / 230))), body: body)
            try document.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            let version = UUID().uuidString
            try storage.commit(staging: directory, id: article.id, version: version)
            staging = nil
            article.title = extracted.title
            article.author = extracted.author
            article.publishedAt = extracted.publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            article.excerpt = extracted.excerpt
            article.resolvedURL = page.url.absoluteString
            article.wordCount = extracted.wordCount
            article.imageCount = extracted.images.count - missing
            article.missingImageCount = missing
            article.contentVersion = version
            article.downloadedAt = .now
            article.state = missing > 0 ? .partial : .ready
            article.failureMessage = nil
            try container.mainContext.save()
            if !article.isCached { reindex(article) }
        } catch {
            article.state = .failed
            article.failureMessage = error.localizedDescription
            save()
        }
        if discarded.remove(article.id) != nil { erase(article) }
    }
}

private extension Article {
    func isAt(_ url: URL) -> Bool { originalURL == url.absoluteString || resolvedURL == url.absoluteString }
}
