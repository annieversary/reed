import CryptoKit
import Foundation
import Observation
import SwiftData

@MainActor @Observable
public final class Library {
    public private(set) var articles: [Article] = []
    /// Front-page stories and recent feed entries downloaded ahead to read offline, kept outside the
    /// library until saved.
    public private(set) var cached: [Article] = []
    /// Cached articles kept even once they are no longer wanted, such as the one being read.
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
    /// Saved articles grouped into series, in the order they were made.
    public private(set) var series: [Series] = []
    /// Advances whenever the search index changes, so searches can be rerun.
    public private(set) var searchRevision = 0
    public let container: ModelContainer
    public let storage: ArticleStorage
    private let downloader: ArticleDownloader
    private let extractor = ArticleExtractor()
    private let renderer = PageRenderer()
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
        if let data = try? Data(contentsOf: Self.feedsURL(root: root)),
           let store = try? JSONDecoder().decode(FeedStore.self, from: data) {
            feeds = store.feeds
            feedItems = Self.river(of: feeds)
            feedsVisitedAt = store.visitedAt
        }
        if let data = try? Data(contentsOf: Self.seriesURL(root: root)),
           let stored = try? JSONDecoder().decode([Series].self, from: data) {
            let saved = Set(articles.map(\.id))
            series = stored.map { var series = $0; series.parts.removeAll { !saved.contains($0) }; return series }
                .filter { !$0.parts.isEmpty }
        }
        syncCache()
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

    /// Saves the PDF at `file`, shared as a file rather than a link. Reed keeps a copy to read it from.
    @discardableResult public func add(pdfAt file: URL, name: String) throws -> Article {
        let data = try Data(contentsOf: file)
        guard data.starts(with: Data("%PDF".utf8)) else { throw ReedError.unsupportedContent }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = articles.first(where: { $0.isFile && URL(string: $0.originalURL)?.pathComponents.dropFirst().first == digest }) {
            return existing
        }
        let article = Article(url: Article.fileURL(digest: digest, name: name))
        article.title = (name as NSString).deletingPathExtension
        let copy = storage.sharedFileURL(article.id)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: copy, options: .atomic)
        container.mainContext.insert(article)
        do { try container.mainContext.save() }
        catch { container.mainContext.delete(article); try? storage.removeArticle(article.id); throw error }
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
    /// or still wanted in the cache.
    public func removeFromLibrary(_ article: Article) {
        guard !article.isCached else { return }
        article.isCached = true
        article.isFavorite = false
        save()
        articles.removeAll { $0.id == article.id }
        cached.append(article)
        removeFromSeries(article)
        let id = article.id
        Task { [weak self, searchIndex] in
            try? await searchIndex.remove(id)
            self?.searchRevision += 1
        }
    }

    /// How many of the newest feed entries are cached.
    static let cachedFeedEntries = 50

    /// Caches each front-page story and recent feed entry that isn't in the library, front pages first and
    /// each in its own order, and drops cached articles that are neither any longer.
    private func syncCache() {
        var kept: [Article] = []
        let wanted = ExternalSource.allCases.flatMap { frontPages[$0]?.items ?? [] } + feedItems.prefix(Self.cachedFeedEntries)
        for item in wanted
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

    /// Drops a source's front page and the stories cached from it, such as once signed out of it.
    public func forgetFrontPage(of source: ExternalSource) {
        guard frontPages.removeValue(forKey: source) != nil else { return }
        syncCache()
        try? FileManager.default.removeItem(at: Self.frontPageURL(root: storage.root, source: source))
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
        syncCache()
        resumeDownloads()
        return feed
    }

    public func feed(at url: URL) -> Feed? { feeds.first { $0.url == url } }

    public func unsubscribe(_ feed: Feed) {
        let previous = feeds
        feeds.removeAll { $0.id == feed.id }
        do { try saveFeeds() } catch { feeds = previous; errorMessage = error.localizedDescription }
        syncCache()
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
        syncCache()
        resumeDownloads()
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
            try inbox.drain { item in
                // What can never be saved is dropped rather than retried forever.
                switch item {
                case .link(let input): do { try add(input) } catch ReedError.invalidURL {}
                case .pdf(let file, let name): do { try add(pdfAt: file, name: name) } catch ReedError.unsupportedContent {}
                }
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
        if erase(article) { articles.remove(at: index); removeFromSeries(article) }
    }

    public func series(of article: Article) -> Series? {
        series.first { $0.parts.contains(article.id) }
    }

    /// The series' articles, in reading order.
    public func parts(of series: Series) -> [Article] {
        let byID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })
        let current = self.series.first { $0.id == series.id } ?? series
        return current.parts.compactMap { byID[$0] }
    }

    /// Gathers articles into a new series, taking them out of any other, ordered by the part numbers in
    /// their titles if every one has one, and otherwise by when they were published, then saved.
    @discardableResult public func makeSeries(named name: String, of parts: [Article]) -> Series? {
        guard !parts.isEmpty else { return nil }
        let numbers = parts.map { SeriesTitle.partNumber(in: $0.title) }
        let ordered = if numbers.allSatisfy({ $0 != nil }) {
            zip(parts, numbers).sorted { $0.1! < $1.1! }.map(\.0)
        } else {
            parts.sorted { ($0.publishedAt ?? $0.savedAt, $0.savedAt) < ($1.publishedAt ?? $1.savedAt, $1.savedAt) }
        }
        let new = Series(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parts: ordered.map(\.id))
        updateSeries { all in
            for index in all.indices { all[index].parts.removeAll(where: new.parts.contains) }
            all.removeAll { $0.parts.isEmpty }
            all.append(new)
        }
        return new
    }

    /// Adds an article to a series, after the parts numbered before it, or at the end.
    public func add(_ article: Article, to series: Series) {
        let id = article.id
        updateSeries { all in
            for index in all.indices { all[index].parts.removeAll { $0 == id } }
            guard let target = all.firstIndex(where: { $0.id == series.id }) else { return }
            var position = all[target].parts.endIndex
            let byID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })
            let numbers = all[target].parts.map { byID[$0].flatMap { SeriesTitle.partNumber(in: $0.title) } }
            if let number = SeriesTitle.partNumber(in: article.title), numbers.allSatisfy({ $0 != nil }) {
                position = numbers.firstIndex { $0! > number } ?? position
            }
            all[target].parts.insert(id, at: position)
            all.removeAll { $0.parts.isEmpty }
        }
    }

    /// Puts articles into one series in the order given: the series one of them is in already, or else a new
    /// one. Parts already in that series but not given stay, after them.
    @discardableResult public func gather(_ parts: [Article], named name: String) -> Series? {
        guard !parts.isEmpty else { return nil }
        let ids = parts.map(\.id)
        var gathered = series.first { $0.parts.contains(where: ids.contains) }
            ?? Series(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parts: [])
        gathered.parts = ids + gathered.parts.filter { !ids.contains($0) }
        updateSeries { all in
            for index in all.indices where all[index].id != gathered.id { all[index].parts.removeAll(where: ids.contains) }
            all.removeAll { $0.parts.isEmpty }
            if let index = all.firstIndex(where: { $0.id == gathered.id }) { all[index] = gathered } else { all.append(gathered) }
        }
        return gathered
    }

    /// The chapters of the serial the article is a chapter of, found from the links between them. `found` hears
    /// of them as they're found.
    public func findChapters(around article: Article, found: ([Chapter]) -> Void) async throws -> ChapterSearch {
        guard let url = article.sourceURL else { throw ReedError.invalidURL }
        // Its own, so finding chapters doesn't wait on an article being saved.
        let extractor = ArticleExtractor()
        let finder = ChapterFinder { [downloader] url in
            let page = try await downloader.page(at: url)
            return (page.url, try await extractor.pageLinks(html: page.html, url: page.url))
        }
        return try await finder.chapters(around: url, found: found)
    }

    /// Saves the chapters not saved yet, and gathers them all into one series in the order given.
    @discardableResult public func save(_ chapters: [Chapter], asSeriesNamed name: String) throws -> Series? {
        gather(try chapters.map { try add($0.url.absoluteString) }, named: name)
    }

    /// Takes an article out of its series, which goes once it has no parts left.
    public func removeFromSeries(_ article: Article) {
        guard series(of: article) != nil else { return }
        updateSeries { all in
            for index in all.indices { all[index].parts.removeAll { $0 == article.id } }
            all.removeAll { $0.parts.isEmpty }
        }
    }

    public func moveParts(of series: Series, from offsets: IndexSet, to destination: Int) {
        updateSeries { all in
            guard let index = all.firstIndex(where: { $0.id == series.id }) else { return }
            let parts = all[index].parts
            let moved = offsets.map { parts[$0] }
            var rest = parts.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
            rest.insert(contentsOf: moved, at: destination - offsets.count { $0 < destination })
            all[index].parts = rest
        }
    }

    public func rename(_ series: Series, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        updateSeries { all in
            guard let index = all.firstIndex(where: { $0.id == series.id }) else { return }
            all[index].name = name
        }
    }

    /// Ends a series, keeping its articles.
    public func ungroup(_ series: Series) {
        updateSeries { $0.removeAll { $0.id == series.id } }
    }

    private func updateSeries(_ change: (inout [Series]) -> Void) {
        let previous = series
        change(&series)
        do { try JSONEncoder().encode(series).write(to: Self.seriesURL(root: storage.root), options: .atomic) }
        catch { series = previous; errorMessage = error.localizedDescription }
    }

    static func seriesURL(root: URL) -> URL { root.appendingPathComponent("Series.json") }


    /// Whether the article's metadata is gone; leftover files are reported but don't count against it.
    @discardableResult private func erase(_ article: Article) -> Bool {
        let id = article.id
        container.mainContext.delete(article)
        do { try container.mainContext.save() } catch { errorMessage = error.localizedDescription; return false }
        Task { [searchIndex] in try? await searchIndex.remove(id) }
        do { try storage.removeArticle(id) } catch { errorMessage = error.localizedDescription }
        return true
    }

    /// Favoriting a cached article saves it, so it isn't dropped from the cache.
    public func toggleFavorite(_ article: Article) {
        article.isFavorite.toggle()
        if article.isFavorite && article.isCached { keep(article) } else { save() }
    }
    public func toggleRead(_ article: Article) { article.isRead.toggle(); save() }
    public func setRead(_ read: Bool, for articles: [Article]) {
        for article in articles { article.isRead = read }
        save()
    }

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

    /// The notes written beside the saved article's passages, as `passages(for:)` gives them.
    public func notes(for article: Article, passages: [String]) -> [ArticleNote] {
        ArticleNotes.placed(storedNotes(for: article), in: passages)
    }

    /// Replaces the note beside a passage; empty text removes it. Writing a note keeps a cached article,
    /// so the note isn't evicted with it.
    public func setNote(_ text: String, at passage: Int, for article: Article) {
        guard let passages = passages(for: article), passages.indices.contains(passage) else { return }
        var notes = ArticleNotes.placed(storedNotes(for: article), in: passages).filter { $0.passage != passage }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            notes.append(ArticleNote(passage: passage, anchor: ArticleNotes.anchor(for: passages[passage]), text: text))
            notes.sort { $0.passage < $1.passage }
            keep(article)
        }
        let url = storage.notesURL(article.id)
        do {
            if !notes.isEmpty { try JSONEncoder().encode(notes).write(to: url, options: .atomic) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func storedNotes(for article: Article) -> [ArticleNote] {
        guard let data = try? Data(contentsOf: storage.notesURL(article.id)) else { return [] }
        return (try? JSONDecoder().decode([ArticleNote].self, from: data)) ?? []
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

    /// The article as served or, when that holds little text, as its scripts render it: some pages arrive
    /// as an empty shell and build the article on load.
    private func extract(_ page: DownloadedPage, report: (String) -> Void) async throws -> ExtractedArticle {
        let fetch: (URL) async throws -> String = { [downloader] url in
            String(decoding: try await downloader.resource(at: url), as: UTF8.self)
        }
        var extracted: ExtractedArticle?
        var failure: Error?
        do { extracted = try await extractor.extract(html: page.html, url: page.url, fetch: fetch) }
        catch is CancellationError { throw CancellationError() }
        catch { failure = error }
        if (extracted?.wordCount ?? 0) < 150 {
            report("Rendering \(page.url.host() ?? "the page")…")
            if let html = try? await renderer.html(at: page.url),
               let rendered = try? await extractor.extract(html: html, url: page.url, fetch: fetch),
               rendered.wordCount > (extracted?.wordCount ?? 0) {
                extracted = rendered
            }
            try Task.checkCancellation()
        }
        guard let extracted else { throw failure ?? ReedError.emptyArticle }
        return extracted
    }

    private func readPDF(_ data: Data, url: URL) async throws -> (ExtractedArticle, [String: Data]) {
        guard #available(macOS 26, iOS 26, *) else { throw ReedError.pdfNeedsNewerSystem }
        return try await PDFArticle.extract(data, url: url)
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
            let source = try article.isFile ? nil : ArticleURL.parse(article.originalURL)
            let pageURL: URL
            let extracted: ExtractedArticle
            // Pictures that came with the article rather than needing a download, by file name.
            var pictures: [String: Data] = [:]
            if let source, let video = YouTube.videoID(in: source) {
                report("Fetching the transcript…")
                extracted = try await YouTube.transcript(of: video, using: downloader)
                pageURL = YouTube.watchURL(video)
            } else if let source {
                report("Fetching \(article.domain)…")
                switch try await downloader.document(at: source) {
                case .pdf(let data, let url):
                    report("Reading the PDF…")
                    (extracted, pictures) = try await readPDF(data, url: url)
                    pageURL = url
                case .page(let page):
                    report("Finding the article…")
                    let found = try await extract(page, report: report)
                    if let paperURL = ArticleDownloader.arxivPDF(for: page.url, extracted: found.html) {
                        // The abstract page names the paper, and without an HTML rendering its PDF is the paper.
                        report("Fetching the paper…")
                        let pdf = try await downloader.pdf(at: paperURL)
                        report("Reading the PDF…")
                        let paper: ExtractedArticle
                        (paper, pictures) = try await readPDF(pdf.data, url: pdf.url)
                        extracted = ExtractedArticle(title: found.title, author: found.author ?? paper.author, publishedAt: found.publishedAt ?? paper.publishedAt,
                                                     excerpt: found.excerpt, html: paper.html, wordCount: paper.wordCount, images: paper.images, page: found.page)
                    } else {
                        extracted = found
                    }
                    pageURL = page.url
                }
            } else {
                report("Reading the PDF…")
                guard let url = URL(string: article.originalURL),
                      let data = try? Data(contentsOf: storage.sharedFileURL(article.id)) else { throw ReedError.damagedArticle }
                (extracted, pictures) = try await readPDF(data, url: url)
                pageURL = url
            }
            let directory = try storage.createStagingDirectory()
            staging = directory
            var body = extracted.html
            var missing = 0
            var totalBytes = 0
            for (index, image) in extracted.images.enumerated() {
                try Task.checkCancellation()
                if let data = pictures[image.filename] {
                    try data.write(to: directory.appendingPathComponent(image.filename), options: .atomic)
                    continue
                }
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
                                                domain: Article.domain(of: pageURL) ?? "", minutes: max(1, Int(ceil(Double(extracted.wordCount) / 230))), body: body)
            try document.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            let version = UUID().uuidString
            try storage.commit(staging: directory, id: article.id, version: version)
            staging = nil
            article.title = extracted.title
            article.author = extracted.author
            article.publishedAt = extracted.publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            article.excerpt = extracted.excerpt
            article.resolvedURL = pageURL.absoluteString
            article.wordCount = extracted.wordCount
            article.imageCount = extracted.images.count - missing
            article.missingImageCount = missing
            article.leadsToOtherChapters = ChapterLinks(page: extracted.page, url: pageURL).leadsToOtherChapters
            article.contentVersion = version
            article.downloadedAt = .now
            article.state = missing > 0 ? .partial : .ready
            article.failureMessage = nil
            try container.mainContext.save()
            if !article.isCached { reindex(article) }
        } catch {
            // A failed refresh leaves the copy already saved readable.
            if contentURL(for: article) != nil {
                article.state = article.missingImageCount > 0 ? .partial : .ready
                if !article.isCached { errorMessage = error.localizedDescription }
            } else {
                article.state = .failed
                article.failureMessage = error.localizedDescription
            }
            save()
        }
        if discarded.remove(article.id) != nil { erase(article) }
    }
}

private extension Article {
    func isAt(_ url: URL) -> Bool { originalURL == url.absoluteString || resolvedURL == url.absoluteString }
}
