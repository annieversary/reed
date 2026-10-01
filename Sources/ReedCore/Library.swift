import Foundation
import Observation
import SwiftData

@MainActor @Observable
public final class Library {
    public private(set) var articles: [Article] = []
    public var errorMessage: String?
    public private(set) var activity: String?
    public let container: ModelContainer
    public let storage: ArticleStorage
    private let downloader: ArticleDownloader
    private let extractor = ArticleExtractor()
    private var worker: Task<Void, Never>?
    private var progressSave: Task<Void, Never>?

    public init(root: URL? = nil, downloader: ArticleDownloader = ArticleDownloader()) throws {
        let root = try root ?? ArticleStorage.defaultRoot()
        storage = try ArticleStorage(root: root)
        self.downloader = downloader
        let configuration = ModelConfiguration(url: root.appendingPathComponent("Library.store"))
        container = try ModelContainer(for: Article.self, configurations: configuration)
        articles = try container.mainContext.fetch(FetchDescriptor<Article>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)]))
        try storage.cleanStaging()
        for article in articles {
            if article.state == .downloading { article.state = .queued }
            if article.state.isReadable && contentURL(for: article) == nil {
                article.state = .failed
                article.failureMessage = ReedError.damagedArticle.localizedDescription
            }
        }
        try container.mainContext.save()
    }

    @discardableResult public func add(_ input: String) throws -> Article {
        let url = try ArticleURL.parse(input)
        if let existing = articles.first(where: { $0.originalURL == url.absoluteString || $0.resolvedURL == url.absoluteString }) {
            return existing
        }
        let article = Article(url: url)
        container.mainContext.insert(article)
        do { try container.mainContext.save() }
        catch { container.mainContext.delete(article); throw error }
        articles.insert(article, at: 0)
        resumeDownloads()
        return article
    }

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
            defer { self.worker = nil; self.activity = nil }
            while let article = self.articles.last(where: { $0.state == .queued }) {
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
        container.mainContext.delete(article)
        do {
            try container.mainContext.save()
            articles.remove(at: index)
            try storage.removeArticle(id)
        } catch { errorMessage = error.localizedDescription }
    }

    public func toggleFavorite(_ article: Article) { article.isFavorite.toggle(); save() }
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

    private func download(_ article: Article) async {
        article.state = .downloading
        save()
        var staging: URL?
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        do {
            activity = "Fetching \(article.domain)…"
            let page = try await downloader.page(at: ArticleURL.parse(article.originalURL))
            activity = "Finding the article…"
            let extracted = try await extractor.extract(html: page.html, url: page.url)
            let directory = try storage.createStagingDirectory()
            staging = directory
            var body = extracted.html
            var missing = 0
            var totalBytes = 0
            for (index, image) in extracted.images.enumerated() {
                try Task.checkCancellation()
                activity = "Saving image \(index + 1) of \(extracted.images.count)…"
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
        } catch {
            article.state = .failed
            article.failureMessage = error.localizedDescription
            save()
        }
    }
}
