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
    /// Books added from EPUB files, most recently added first.
    public private(set) var books: [Book] = []
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
    /// How many times each shared item has failed to be added, by its file name in the inbox.
    @ObservationIgnored private var inboxFailures: [String: Int] = [:]
    private struct PassageKey: Hashable { let content: URL, title: String }
    @ObservationIgnored private var passageCache: [PassageKey: [String]] = [:]
    @ObservationIgnored private var sentenceCache: [PassageKey: [[String]]] = [:]
    @ObservationIgnored private var addingShared = false
    /// Something more was shared while the inbox was being emptied.
    @ObservationIgnored private var inboxChanged = false
    private static let inboxAttempts = 3

    public init(root: URL? = nil, downloader: ArticleDownloader = ArticleDownloader()) throws {
        let root = try root ?? ArticleStorage.defaultRoot()
        storage = try ArticleStorage(root: root)
        self.downloader = downloader
        let configuration = ModelConfiguration(url: root.appendingPathComponent("Library.store"))
        container = try ModelContainer(for: Article.self, Book.self, BookChapter.self, configurations: configuration)
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
        books = try container.mainContext.fetch(FetchDescriptor<Book>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))
        for book in books {
            if book.state == .downloading { book.state = .queued }
            // Converted again from the EPUB kept with it.
            if book.state.isReadable && !hasContent(book) { book.state = .queued }
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

    /// `discussion` is where the link was found being discussed, if it was.
    @discardableResult public func add(_ input: String, discussion: URL? = nil) throws -> Article {
        let url = try ArticleURL.parse(input)
        if let existing = article(at: url) { note(discussion, of: existing); save(); return existing }
        if let cached = cachedArticle(at: url) { note(discussion, of: cached); keep(cached); return cached }
        let article = Article(url: url)
        note(discussion, of: article)
        container.mainContext.insert(article)
        do { try container.mainContext.save() }
        catch { container.mainContext.delete(article); throw error }
        articles.insert(article, at: 0)
        reindex(article)
        resumeDownloads()
        return article
    }

    /// Saves the PDF at `file`, shared as a file rather than a link. Reed keeps a copy to read it from.
    @discardableResult public func add(pdfAt file: URL, name: String) async throws -> Article {
        let staging = try storage.createStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let imported = try await Self.importFile(file, into: staging)
        guard imported.head.starts(with: Data("%PDF".utf8)) else { throw ReedError.unsupportedContent }
        let digest = imported.digest
        if let existing = articles.first(where: { $0.isFile && URL(string: $0.originalURL)?.pathComponents.dropFirst().first == digest }) {
            return existing
        }
        let article = Article(url: Article.fileURL(digest: digest, name: name))
        article.title = (name as NSString).deletingPathExtension
        let copy = storage.sharedFileURL(article.id)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: imported.copy, to: copy)
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
        let address = url.absoluteString
        return articles.first { $0.isAt(address) }
    }

    public func cachedArticle(at url: URL) -> Article? {
        let address = url.absoluteString
        return cached.first { $0.isAt(address) }
    }

    /// The copy of `url` to read: the saved one, else the cached one, cached now if need be.
    public func readable(at url: URL, discussion: URL? = nil) -> Article? {
        if let saved = article(at: url) { note(discussion, of: saved); save(); return saved }
        let article: Article
        if let existing = cachedArticle(at: url) {
            article = existing
            note(discussion, of: article)
            if article.state == .failed { article.state = .queued }
            save()
        } else {
            article = Article(url: url)
            note(discussion, of: article)
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

    /// Adds where the article is discussed, unsaved, if it isn't known already.
    private func note(_ discussion: URL?, of article: Article) {
        guard let discussion, let site = DiscussionSite(url: discussion), !article.discussionSites.contains(site) else { return }
        article.discussionURLs = (article.discussionURLs ?? []) + [site.url.absoluteString]
    }

    /// Asks other sites whether they discuss the article. This tells them its address, so it's only done when asked for.
    public func findDiscussions(of article: Article) async {
        guard let url = article.sourceURL else { return }
        let found = await DiscussionSite.discussions(of: url, using: downloader)
        for site in found { note(site.url, of: article) }
        save()
    }

    /// The comments last fetched from `site`, if any.
    public func discussion(_ site: DiscussionSite, of article: Article) -> Discussion? {
        guard let data = try? Data(contentsOf: storage.discussionURL(article.id, site: site)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Discussion.self, from: data)
    }

    /// Fetches the comments from `site` again, keeping them to read offline.
    public func refreshDiscussion(_ site: DiscussionSite, of article: Article) async throws -> Discussion {
        let discussion = try await site.discussion(using: downloader)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = storage.discussionURL(article.id, site: site)
        // Failing to keep a copy only costs reading them offline.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(discussion).write(to: url, options: .atomic)
        return discussion
    }

    /// Moves a cached article into the library, without downloading it again.
    public func keep(_ article: Article) {
        guard article.isCached else { return }
        discarded.remove(article.id)
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
        // Looked up by address once, rather than searching every article for each item.
        func byAddress(_ articles: [Article]) -> [String: Article] {
            Dictionary(articles.flatMap { article in article.addresses.map { ($0, article) } }) { first, _ in first }
        }
        let saved = byAddress(articles), cachedByAddress = byAddress(cached)
        var keptAddresses = Set<String>()
        for item in wanted {
            let address = item.url.absoluteString
            if let saved = saved[address] { note(item.discussionURL, of: saved); continue }
            guard !keptAddresses.contains(address) else { continue }
            if let existing = cachedByAddress[address] {
                // Earlier failures are often just being offline.
                if existing.state == .failed { existing.state = .queued; existing.failureMessage = nil }
                note(item.discussionURL, of: existing)
                kept.append(existing)
                keptAddresses.formUnion(existing.addresses)
            } else {
                let article = Article(url: item.url)
                note(item.discussionURL, of: article)
                article.isCached = true
                container.mainContext.insert(article)
                kept.append(article)
                keptAddresses.formUnion(article.addresses)
            }
        }
        let keptIDs = Set(kept.map(\.id))
        for article in cached where !keptIDs.contains(article.id) {
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
        try Task.checkCancellation()
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

    /// Adds what's waiting in the inbox. Called again while it's at work, it goes round once more when done.
    public func addShared(from inbox: ShareInbox) async {
        guard !addingShared else { inboxChanged = true; return }
        addingShared = true
        defer { addingShared = false }
        repeat {
            inboxChanged = false
            await drain(inbox)
        } while inboxChanged
    }

    private func drain(_ inbox: ShareInbox) async {
        do {
            // An item that keeps failing is set aside, so it doesn't report the same error every time Reed is opened.
            try await inbox.drain(giveUp: { file in
                inboxFailures[file.lastPathComponent, default: 0] += 1
                return inboxFailures[file.lastPathComponent]! >= Self.inboxAttempts
            }) { item in
                // What can never be saved is dropped rather than retried forever.
                switch item {
                case .link(let input): do { try add(input) } catch ReedError.invalidURL {}
                case .pdf(let file, let name): do { try await add(pdfAt: file, name: name) } catch ReedError.unsupportedContent {}
                case .book(let file, let name):
                    // Said why, since it was chosen to read, then dropped like the rest.
                    do { try await add(bookAt: file, name: name) }
                    catch ReedError.unreadableBook { errorMessage = ReedError.unreadableBook.localizedDescription }
                    catch ReedError.protectedBook { errorMessage = ReedError.protectedBook.localizedDescription }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Waits until nothing is queued to download or convert.
    func idle() async {
        while let worker { await worker.value }
    }

    public func resumeDownloads() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.activity = nil; self.imageActivity = nil }
            while !Task.isCancelled {
                if let article = self.articles.last(where: { $0.state == .queued }) ?? self.cached.first(where: { $0.state == .queued }) {
                    await self.download(article)
                } else if let book = self.books.last(where: { $0.state == .queued }) {
                    await self.convert(book)
                } else { break }
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
    public func setRead(_ read: Bool, for articles: [Article]) {
        for article in articles { article.isRead = read }
        save()
    }

    public func toggleRead(_ readable: any Readable) { readable.isRead.toggle(); save() }

    public func updateProgress(_ readable: any Readable, value: Double) {
        guard value.isFinite else { return }
        readable.progress = min(max(value, 0), 1)
        if value >= 0.95 { readable.isRead = true }
        progressSave?.cancel()
        progressSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self?.save()
        }
    }

    public func save() {
        do { try container.mainContext.save() } catch { errorMessage = error.localizedDescription }
    }

    public func contentURL(for readable: any Readable) -> URL? {
        guard let version = readable.contentVersion else { return nil }
        let url = storage.contentURL(readable.location, version: version)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The saved text to read aloud, or nil if it isn't saved.
    public func passages(for readable: any Readable) -> [String]? {
        guard let url = contentURL(for: readable) else { return nil }
        // A saved version never changes, so its passages are kept while it's being read, noted and listened to.
        let key = PassageKey(content: url, title: readable.title)
        if let known = passageCache[key] { return known }
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let passages = ArticleSpeech.passages(title: readable.title, html: html)
        if passageCache.count >= 4 { passageCache.removeAll() }
        passageCache[key] = passages
        return passages
    }

    /// Each passage's sentences, as narration follows them.
    public func sentences(for readable: any Readable) -> [[String]]? {
        guard let url = contentURL(for: readable) else { return nil }
        let key = PassageKey(content: url, title: readable.title)
        if let known = sentenceCache[key] { return known }
        guard let passages = passages(for: readable) else { return nil }
        let sentences = passages.map(ArticleSpeech.sentences(in:))
        if sentenceCache.count >= 4 { sentenceCache.removeAll() }
        sentenceCache[key] = sentences
        return sentences
    }

    /// The notes written beside the saved passages, as `passages(for:)` gives them.
    public func notes(for readable: any Readable, passages: [String]) -> [ArticleNote] {
        ArticleNotes.placed(storedNotes(for: readable), in: passages)
    }

    /// Replaces the note beside a passage; empty text removes it. Writing a note keeps a cached article,
    /// so the note isn't evicted with it.
    public func setNote(_ text: String, at passage: Int, for readable: any Readable) {
        guard let passages = passages(for: readable), passages.indices.contains(passage) else { return }
        var notes = ArticleNotes.placed(storedNotes(for: readable), in: passages).filter { $0.passage != passage }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            notes.append(ArticleNote(passage: passage, anchor: ArticleNotes.anchor(for: passages[passage]), text: text))
            notes.sort { $0.passage < $1.passage }
            if let article = readable as? Article { keep(article) }
        }
        let url = storage.notesURL(readable.location)
        do {
            if !notes.isEmpty {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(notes).write(to: url, options: .atomic)
            }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func storedNotes(for readable: any Readable) -> [ArticleNote] {
        guard let data = try? Data(contentsOf: storage.notesURL(readable.location)) else { return [] }
        return (try? JSONDecoder().decode([ArticleNote].self, from: data)) ?? []
    }

    /// The first image saved with the article, or a chapter's book cover, if any.
    public func leadImage(for readable: any Readable) -> URL? {
        if let chapter = readable as? BookChapter { return chapter.book.flatMap(cover(of:)) }
        guard let url = contentURL(for: readable), let html = try? String(contentsOf: url, encoding: .utf8),
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
                      let data = await Self.read(storage.sharedFileURL(article.id)) else { throw ReedError.damagedArticle }
                (extracted, pictures) = try await readPDF(data, url: url)
                pageURL = url
            }
            let directory = try storage.createStagingDirectory()
            staging = directory
            var missing: [ExtractedArticle.Image] = []
            var totalBytes = 0
            for (index, image) in extracted.images.enumerated() {
                try Task.checkCancellation()
                if let data = pictures[image.filename] {
                    try await Self.write(data, to: directory.appendingPathComponent(image.filename))
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
                    try await Self.write(data, to: directory.appendingPathComponent(image.filename))
                    totalBytes += data.count
                } catch is CancellationError { throw CancellationError() }
                catch { missing.append(image) }
            }
            let body = await Self.replacing(missing, in: extracted.html)
            let document = ArticleHTML.document(title: extracted.title, author: extracted.author,
                                                domain: Article.domain(of: pageURL) ?? "", minutes: max(1, Int(ceil(Double(extracted.wordCount) / 230))), body: body)
            try await Self.write(Data(document.utf8), to: directory.appendingPathComponent("index.html"))
            let version = UUID().uuidString
            try storage.commit(staging: directory, id: article.id, version: version)
            staging = nil
            article.title = extracted.title
            article.author = extracted.author
            article.publishedAt = extracted.publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            article.excerpt = extracted.excerpt
            article.resolvedURL = pageURL.absoluteString
            article.wordCount = extracted.wordCount
            article.imageCount = extracted.images.count - missing.count
            article.missingImageCount = missing.count
            article.leadsToOtherChapters = ChapterLinks(page: extracted.page, url: pageURL).leadsToOtherChapters
            let previous = article.contentVersion
            article.contentVersion = version
            article.downloadedAt = .now
            article.state = missing.isEmpty ? .ready : .partial
            article.failureMessage = nil
            try container.mainContext.save()
            if let previous { try? storage.removeArticleVersion(article.id, version: previous) }
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

    // MARK: Books

    /// Adds the EPUB at `file`. Reed keeps a copy to convert the book from; adding the same file again finds the copy kept.
    @discardableResult public func add(bookAt file: URL, name: String) async throws -> Book {
        let staging = try storage.createStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let imported = try await Self.importFile(file, into: staging)
        if let existing = books.first(where: { $0.fileHash == imported.digest }) { return existing }
        let epub = try await Self.openBook(at: imported.copy)
        // Added while this one was being read.
        if let existing = books.first(where: { $0.fileHash == imported.digest }) { return existing }
        let book = Book(fileHash: imported.digest, title: epub.title ?? (name as NSString).deletingPathExtension)
        book.author = epub.author
        let copy = storage.bookFileURL(book.id)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: imported.copy, to: copy)
        container.mainContext.insert(book)
        do { try container.mainContext.save() }
        catch { container.mainContext.delete(book); try? storage.removeBook(book.id); throw error }
        books.insert(book, at: 0)
        resumeDownloads()
        return book
    }

    public func retry(_ book: Book) {
        guard book.state != .downloading && book.state != .queued else { return }
        book.state = .queued
        book.failureMessage = nil
        save()
        resumeDownloads()
    }

    public func delete(_ book: Book) {
        guard book.state != .downloading, let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        let id = book.id
        container.mainContext.delete(book)
        do { try container.mainContext.save() } catch { errorMessage = error.localizedDescription; return }
        books.remove(at: index)
        do { try storage.removeBook(id) } catch { errorMessage = error.localizedDescription }
    }

    public func toggleFavorite(_ book: Book) { book.isFavorite.toggle(); save() }

    /// Remembers the chapter being read, so the book opens there next time.
    public func open(_ chapter: BookChapter) {
        guard let book = chapter.book else { return }
        book.currentChapter = chapter.index
        book.openedAt = .now
        save()
    }

    /// What follows `readable` in its book, if it's a chapter that isn't the last.
    public func next(after readable: any Readable) -> (any Readable)? {
        guard let chapter = readable as? BookChapter else { return nil }
        return chapter.book?.orderedChapters.first { $0.index > chapter.index }
    }

    public func cover(of book: Book) -> URL? {
        guard let version = book.contentVersion, let file = book.coverFile else { return nil }
        let url = storage.bookDirectory(book.id).appendingPathComponent(version, isDirectory: true).appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func hasContent(_ book: Book) -> Bool {
        guard let version = book.contentVersion else { return false }
        return FileManager.default.fileExists(atPath: storage.bookDirectory(book.id).appendingPathComponent(version).path)
    }

    /// Converts the book's EPUB into a reader document per chapter, sharing its images, and replaces any earlier version.
    private func convert(_ book: Book) async {
        book.state = .downloading
        save()
        var staging: URL?
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        do {
            activity = "Opening \(book.title)…"
            let epub = try await Self.openBook(at: storage.bookFileURL(book.id))
            let directory = try storage.createStagingDirectory()
            staging = directory
            var chapters = epub.chapters
            func links() throws -> [String: Int] { try epub.links(for: chapters) }
            func extract(_ index: Int, links: [String: Int]) async throws -> ExtractedArticle {
                activity = "Converting chapter \(index + 1) of \(chapters.count)…"
                let files = try chapters[index].parts.compactMap { part in
                    try epub.file(part.path).map { (part: part, html: String(decoding: $0, as: UTF8.self)) }
                }
                return try await extractor.chapter(files: files, title: chapters[index].title, index: index, links: links)
            }
            var extracted: [ExtractedArticle] = []
            // Pages before the table of contents' first entry are kept only if they have something to read, unlike a cover.
            if chapters.count > 1, chapters[0].title == nil {
                let opening = try await extract(0, links: try links())
                if opening.wordCount < 20 { chapters.removeFirst() } else { extracted.append(opening) }
            }
            let links = try links()
            for index in extracted.count..<chapters.count {
                try Task.checkCancellation()
                extracted.append(try await extract(index, links: links))
            }
            guard extracted.contains(where: { $0.wordCount > 0 }) else { throw ReedError.unreadableBook }
            activity = "Saving \(book.title)…"
            var images = extracted.flatMap { $0.images.map { (path: $0.url, filename: $0.filename) } }
            let cover = epub.cover.map { (path: $0, filename: BookFiles.imageName(for: $0)) }
            if let cover { images.append(cover) }
            let (saved, missing) = await Self.unpack(images, from: epub, to: directory)
            for (index, chapter) in extracted.enumerated() {
                let after = extracted.indices.contains(index + 1) ? BookFiles.nextChapterCard(index: index + 1, title: extracted[index + 1].title) : ""
                let document = ArticleHTML.document(title: chapter.title, author: nil, domain: book.title,
                                                    minutes: max(1, Int(ceil(Double(chapter.wordCount) / 230))), body: chapter.html, after: after)
                try await Self.write(Data(document.utf8), to: directory.appendingPathComponent(BookFiles.chapter(index)))
            }
            let coverFile = cover.flatMap { saved.contains($0.filename) ? $0.filename : nil }
            let version = UUID().uuidString
            try storage.commitBook(staging: directory, id: book.id, version: version)
            staging = nil
            let previous = book.contentVersion
            // Converting again keeps how far each chapter was read, and its notes, though chapters may have moved.
            // Chapters saved before they knew where they start are known by title, in the same place if it's still there.
            let byStart = Dictionary(book.chapters.compactMap { old in old.start.map { ($0, old) } }) { first, _ in first }
            let legacy = book.chapters.filter { $0.start == nil }
            let byIndex = Dictionary(legacy.map { ($0.index, $0) }) { first, _ in first }
            let byTitle = Dictionary(legacy.map { ($0.title, $0) }) { first, _ in first }
            var moved: [Int: Int] = [:]
            for chapter in book.chapters { container.mainContext.delete(chapter) }
            book.chapters = extracted.enumerated().map { index, chapter in
                let start = chapters[index].parts.first.map { $0.path + "#" + ($0.from ?? "") }
                let new = BookChapter(index: index, title: chapter.title, start: start, wordCount: chapter.wordCount)
                if let old = start.flatMap({ byStart[$0] }) ?? byIndex[index].flatMap({ $0.title == chapter.title ? $0 : nil }) ?? byTitle[chapter.title] {
                    new.isRead = old.isRead
                    new.progress = old.progress
                    moved[old.index] = index
                }
                return new
            }
            book.currentChapter = book.currentChapter.flatMap { moved[$0] }
            book.title = epub.title ?? book.title
            book.author = epub.author
            book.coverFile = coverFile
            book.contentVersion = version
            book.state = missing > 0 ? .partial : .ready
            book.failureMessage = nil
            try container.mainContext.save()
            moveNotes(of: book, as: moved)
            if let previous { try? storage.removeBookVersion(book.id, version: previous) }
        } catch {
            book.state = hasContent(book) ? .ready : .failed
            book.failureMessage = hasContent(book) ? nil : error.localizedDescription
            if hasContent(book), !(error is CancellationError) { errorMessage = error.localizedDescription }
            save()
        }
    }
}

extension Library {
    /// Renumbers a book's notes after converting it again moved its chapters, from each old index to the new.
    /// Notes of a chapter that's gone are set aside in `Notes/Unplaced` rather than left beside another chapter.
    private func moveNotes(of book: Book, as moved: [Int: Int]) {
        let directory = storage.bookDirectory(book.id).appendingPathComponent("Notes", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let notes = files.compactMap { file in
            Int(file.deletingPathExtension().lastPathComponent).flatMap { index in try? (index, Data(contentsOf: file)) }
        }
        let unplaced = directory.appendingPathComponent("Unplaced", isDirectory: true)
        for (index, _) in notes { try? FileManager.default.removeItem(at: storage.notesURL(.chapter(book: book.id, index: index))) }
        for (index, data) in notes {
            if let new = moved[index] {
                try? data.write(to: storage.notesURL(.chapter(book: book.id, index: new)), options: .atomic)
            } else {
                try? FileManager.default.createDirectory(at: unplaced, withIntermediateDirectories: true)
                try? data.write(to: unplaced.appendingPathComponent("\(index)-\(UUID().uuidString).json"), options: .atomic)
            }
        }
    }
}

/// A file being added, copied into staging and hashed away from the main actor.
private struct ImportedFile: Sendable {
    let copy: URL
    let digest: String
    /// Its first bytes, to tell what it is.
    let head: Data
}

extension Library {
    /// Copies `file` into `staging` and hashes the copy, a chunk at a time, so a large file needn't be read whole.
    fileprivate nonisolated static func importFile(_ file: URL, into staging: URL) async throws -> ImportedFile {
        let copy = staging.appendingPathComponent("Import", isDirectory: false)
        try FileManager.default.copyItem(at: file, to: copy)
        let handle = try FileHandle(forReadingFrom: copy)
        defer { try? handle.close() }
        var hash = SHA256()
        var head = Data()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            if head.isEmpty { head = chunk.prefix(16) }
            hash.update(data: chunk)
        }
        return ImportedFile(copy: copy, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), head: head)
    }

    nonisolated static func read(_ url: URL) async -> Data? { try? Data(contentsOf: url) }

    nonisolated static func write(_ data: Data, to url: URL) async throws { try data.write(to: url, options: .atomic) }

    /// `html` with each of `images` replaced by a note that it's unavailable, keeping its alt text, so the reader
    /// never makes a remote or broken image request.
    nonisolated static func replacing(_ images: [ExtractedArticle.Image], in html: String) async -> String {
        guard !images.isEmpty else { return html }
        let notes = Dictionary(images.map { image in
            (image.filename, "<span class=\"missing-image\">[Image unavailable\(image.alt.isEmpty ? "" : ": " + ArticleHTML.escape(image.alt))]</span>")
        }) { first, _ in first }
        let names = images.map { NSRegularExpression.escapedPattern(for: $0.filename) }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*\\bsrc=\"(" + names + ")\"[^>]*>") else { return html }
        var result = "", last = html.startIndex
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let whole = Range(match.range, in: html), let name = Range(match.range(at: 1), in: html) else { continue }
            result += html[last..<whole.lowerBound] + (notes[String(html[name])] ?? "")
            last = whole.upperBound
        }
        return result + html[last...]
    }

    /// Writes each image from the book into `directory` once, returning the files written and how many couldn't be.
    nonisolated static func unpack(_ images: [(path: String, filename: String)], from epub: EPUB,
                                   to directory: URL) async -> (saved: Set<String>, missing: Int) {
        var saved = Set<String>(), tried = Set<String>()
        for image in images where tried.insert(image.filename).inserted {
            guard let data = try? epub.file(image.path),
                  (try? data.write(to: directory.appendingPathComponent(image.filename), options: .atomic)) != nil else { continue }
            saved.insert(image.filename)
        }
        return (saved, tried.count - saved.count)
    }

    /// The EPUB at `url`, read away from the main actor.
    nonisolated static func openBook(at url: URL) async throws -> EPUB {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw ReedError.damagedArticle }
        return try EPUB(data: data)
    }
}

private extension Article {
    func isAt(_ address: String) -> Bool { originalURL == address || resolvedURL == address }

    /// The addresses it's known by.
    var addresses: [String] { [originalURL] + (resolvedURL.map { [$0] } ?? []) }
}
