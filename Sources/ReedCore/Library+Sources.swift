import Foundation
import SwiftData

/// Front pages and feeds, and the articles cached ahead from them to read offline.
extension Library {
    /// How many of the newest feed entries are cached.
    static let cachedFeedEntries = 50

    /// Caches each front-page story and recent feed entry that isn't in the library, front pages first and
    /// each in its own order, and drops cached articles that are neither any longer.
    func syncCache() {
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

    /// The feeds at `input`: the address itself if it is a feed, otherwise the feeds the page or its site's home page
    /// links to, then those found where sites commonly keep feeds they don't link to.
    public func findFeeds(at input: String) async throws -> [FeedCandidate] {
        let url = try ArticleURL.parse(input)
        let known = await Self.verify(FeedParser.platformFeeds(for: url).map { ($0, nil) }, droppingQuiet: false, using: downloader)
        if !known.isEmpty { return known }
        guard case .fetched(let data, let finalURL, _, _) = try await downloader.feed(at: url) else { throw ReedError.noFeed }
        if let parsed = await Self.parse(data, from: finalURL) {
            return [FeedCandidate(url: finalURL, title: parsed.title ?? finalURL.host() ?? finalURL.absoluteString)]
        }
        guard let html = Self.text(of: data) else { throw ReedError.noFeed }
        var linked = FeedParser.discover(in: html, base: finalURL)
        var api = FeedParser.wordPressAPI(in: html, base: finalURL)
        if linked.isEmpty, let home = URL(string: "/", relativeTo: finalURL)?.absoluteURL, home != finalURL,
           case .fetched(let homeData, let homeURL, _, _)? = try? await downloader.feed(at: home), let homeHTML = Self.text(of: homeData) {
            linked = FeedParser.discover(in: homeHTML, base: homeURL)
            api = api ?? FeedParser.wordPressAPI(in: homeHTML, base: homeURL)
        }
        var guesses: [(url: URL, label: String?)] = []
        if let api, let types = try? await downloader.json(at: api.appending(path: "wp/v2/types")) {
            guesses += FeedParser.wordPressFeeds(types: types, api: api).map { ($0.url, $0.label) }
        }
        if linked.isEmpty {
            let platform = FeedParser.canonical(in: html, base: finalURL).map(FeedParser.platformFeeds) ?? []
            guesses += (platform + FeedParser.guesses(in: html, for: finalURL)).map { ($0, nil) }
        }
        let linkedURLs = Set(linked.map(\.url))
        let found = linked + (await Self.verify(guesses.filter { !linkedURLs.contains($0.url) }, using: downloader))
        if found.isEmpty { throw ReedError.noFeed }
        return found
    }

    private nonisolated static func text(of data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    /// The guessed feeds that turn out to be feeds, freshest first, leaving out repeats of another's entries and,
    /// unless `droppingQuiet` is false, any gone quiet for a year longer than the freshest, which on many sites is a
    /// placeholder left by their software.
    nonisolated static func verify(_ guesses: [(url: URL, label: String?)], droppingQuiet: Bool = true,
                                   using downloader: ArticleDownloader) async -> [FeedCandidate] {
        let requests = guesses.map { FeedRequest(id: UUID(), url: $0.url, etag: nil, lastModified: nil) }
        let results = await fetch(requests, using: downloader)
        let feeds = zip(requests, guesses).compactMap { request, guess -> (candidate: FeedCandidate, entries: [URL], newest: Date)? in
            guard case .success(let fetched?) = results[request.id], !fetched.feed.entries.isEmpty else { return nil }
            let site = fetched.feed.title ?? guess.url.host() ?? guess.url.absoluteString
            let title = guess.label.map { "\(site) — \($0)" } ?? site
            return (FeedCandidate(url: guess.url, title: title), fetched.feed.entries.map(\.url),
                    fetched.feed.entries.compactMap(\.postedAt).max() ?? .distantPast)
        }
        guard let freshest = feeds.map(\.newest).max() else { return [] }
        var seen = Set<[URL]>()
        return feeds
            .filter { (!droppingQuiet || $0.newest > freshest.addingTimeInterval(-365 * 24 * 60 * 60)) && seen.insert($0.entries).inserted }
            .sorted { $0.newest > $1.newest }
            .map(\.candidate)
    }

    /// Looks once for the feeds of the site `article` came from, so they can be offered while reading it.
    public func lookForSiteFeeds(of article: Article) {
        guard let url = article.sourceURL, YouTube.videoID(in: url) == nil else { return }
        let site = article.domain
        guard siteFeeds[site] == nil, savedFeed(forSite: site) == nil, lookingForSiteFeeds.insert(site).inserted else { return }
        Task {
            defer { lookingForSiteFeeds.remove(site) }
            let found: [FeedCandidate]
            do { found = try await findFeeds(at: url.absoluteString) }
            catch ReedError.noFeed { found = [] }
            // Looked for again with the next article saved from the site.
            catch { return }
            siteFeeds[site] = found
            try? JSONEncoder().encode(siteFeeds).write(to: Self.siteFeedsURL(root: storage.root), options: .atomic)
        }
    }

    static func siteFeedsURL(root: URL) -> URL { root.appendingPathComponent("SiteFeeds.json") }

    /// A subscribed feed of the site `article` came from, if there is one.
    public func savedFeed(for article: Article) -> Feed? { savedFeed(forSite: article.domain) }

    func savedFeed(forSite site: String) -> Feed? {
        let found = Set((siteFeeds[site] ?? []).map(\.url))
        return feeds.first { feed in
            found.contains(feed.url) || [feed.url, feed.siteURL].contains { $0.flatMap(Article.domain(of:)) == site }
        }
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

    struct FeedStore: Codable {
        var feeds: [Feed]
        var visitedAt: Date?
    }

    struct FeedRequest: Sendable {
        let id: UUID, url: URL, etag: String?, lastModified: String?
    }

    struct FetchedFeed: Sendable {
        let feed: ParsedFeed, etag: String?, lastModified: String?
    }

    /// How many feeds are fetched at once. Fetching them all together leaves many on one host queued behind each other
    /// long enough to time out.
    nonisolated static let feedFetches = 6

    /// Each feed's new contents, or nil where it hasn't changed.
    nonisolated static func fetch(_ requests: [FeedRequest], using downloader: ArticleDownloader) async -> [UUID: Result<FetchedFeed?, any Error>] {
        await withTaskGroup(of: (UUID, Result<FetchedFeed?, any Error>).self) { group in
            var waiting = requests[...]
            func fetchNext() {
                guard let request = waiting.popFirst() else { return }
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
            for _ in 0..<feedFetches { fetchNext() }
            var results: [UUID: Result<FetchedFeed?, any Error>] = [:]
            for await (id, result) in group {
                results[id] = result
                fetchNext()
            }
            return results
        }
    }

    nonisolated static func parse(_ data: Data, from url: URL) async -> ParsedFeed? {
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

    func saveFeeds() throws {
        try JSONEncoder().encode(FeedStore(feeds: feeds, visitedAt: feedsVisitedAt)).write(to: Self.feedsURL(root: storage.root), options: .atomic)
    }

    static func feedsURL(root: URL) -> URL { root.appendingPathComponent("Feeds.json") }
}
