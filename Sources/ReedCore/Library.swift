import Foundation
import Observation
import SwiftData

@MainActor @Observable
public final class Library {
    public internal(set) var articles: [Article] = []
    /// Front-page stories and recent feed entries downloaded ahead to read offline, kept outside the
    /// library until saved.
    public internal(set) var cached: [Article] = []
    /// Cached articles kept even once they are no longer wanted, such as the one being read.
    public var retained: Set<UUID> = []
    public var errorMessage: String?
    public internal(set) var activity: String?
    /// Image progress of the article being saved, such as "Saving image 2 of 5…".
    public internal(set) var imageActivity: String?
    /// The front page last fetched from each source, kept between launches.
    public internal(set) var frontPages: [ExternalSource: FrontPage] = [:]
    /// Subscribed feeds, in the order they were added.
    public internal(set) var feeds: [Feed] = [] { didSet { feedItems = Self.river(of: feeds) } }
    /// Entries from every feed, newest first, each link only once.
    public internal(set) var feedItems: [SourceItem] = []
    /// When the feeds were last looked at, so what has arrived since can be told apart.
    public internal(set) var feedsVisitedAt: Date?
    public internal(set) var refreshingFeeds = false
    /// Books added from EPUB files, most recently added first.
    public internal(set) var books: [Book] = []
    /// Saved articles grouped into series, in the order they were made.
    public internal(set) var series: [Series] = []
    /// Advances whenever the search index changes, so searches can be rerun.
    public internal(set) var searchRevision = 0
    public let container: ModelContainer
    public let storage: ArticleStorage
    let downloader: ArticleDownloader
    let extractor = ArticleExtractor()
    let renderer = PageRenderer()
    let searchIndex: SearchIndex
    var worker: Task<Void, Never>?
    var progressSave: Task<Void, Never>?
    /// Articles removed while downloading, deleted once their download settles.
    var discarded: Set<UUID> = []
    /// How many times each shared item has failed to be added, by its file name in the inbox.
    @ObservationIgnored var inboxFailures: [String: Int] = [:]
    struct PassageKey: Hashable { let content: URL, title: String }
    @ObservationIgnored var speechCache: [PassageKey: Speech] = [:]
    @ObservationIgnored var addingShared = false
    /// Something more was shared while the inbox was being emptied.
    @ObservationIgnored var inboxChanged = false
    static let inboxAttempts = 3

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
        if let store = Self.restore(FeedStore.self, from: Self.feedsURL(root: root)) {
            feeds = store.feeds
            feedItems = Self.river(of: feeds)
            feedsVisitedAt = store.visitedAt
        }
        if let stored = Self.restore([Series].self, from: Self.seriesURL(root: root)) {
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

    /// What was saved at `url`, or nil if nothing was. A file that can't be read is moved aside to
    /// `<name>.unreadable` rather than left to be overwritten by the next save.
    static func restore<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
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

    public func delete(_ article: Article) {
        let id = article.id
        guard let index = articles.firstIndex(where: { $0.id == id }) else { return }
        // One downloading goes from the library now, and is erased once its download settles, leaving nothing behind.
        if article.state == .downloading {
            discarded.insert(id)
            articles.remove(at: index)
            removeFromSeries(article)
        } else if erase(article) {
            articles.remove(at: index)
            removeFromSeries(article)
        }
    }

    /// Whether the article's metadata is gone; leftover files are reported but don't count against it.
    @discardableResult func erase(_ article: Article) -> Bool {
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

    public func open(_ article: Article) {
        guard article.openedAt == nil else { return }
        article.openedAt = .now
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

    /// The first image saved with the article, or a chapter's book cover, if any.
    public func leadImage(for readable: any Readable) async -> URL? {
        if let chapter = readable as? BookChapter { return chapter.book.flatMap(cover(of:)) }
        guard let url = contentURL(for: readable) else { return nil }
        return await Self.firstImage(of: url)
    }

    nonisolated static func firstImage(of document: URL) async -> URL? {
        guard let html = try? String(contentsOf: document, encoding: .utf8), let source = ArticleHTML.firstImage(in: html) else { return nil }
        let image = document.deletingLastPathComponent().appendingPathComponent(source)
        return FileManager.default.fileExists(atPath: image.path) ? image : nil
    }

    public func search(_ text: String) async -> [SearchIndex.Match] {
        (try? await searchIndex.search(text)) ?? []
    }

    // Index failures aren't surfaced: the index is brought up to date again at every launch.
    func reindex(_ article: Article) {
        let entry = searchEntry(for: article)
        Task { [weak self, searchIndex] in
            try? await searchIndex.index(entry)
            self?.searchRevision += 1
        }
    }

    func searchEntry(for article: Article) -> SearchIndex.Entry {
        SearchIndex.Entry(id: article.id, version: article.contentVersion, title: article.title, author: article.author,
                          domain: article.domain, content: contentURL(for: article))
    }
}

extension Article {
    func isAt(_ address: String) -> Bool { originalURL == address || resolvedURL == address }

    /// The addresses it's known by.
    var addresses: [String] { [originalURL] + (resolvedURL.map { [$0] } ?? []) }
}
