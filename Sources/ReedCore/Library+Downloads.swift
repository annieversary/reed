import Foundation
import Network
import SwiftData

/// How far saving an article or book has got: the step it's on and, while counting through images or chapters, the share of that step done.
public struct SaveProgress: Equatable, Sendable {
    public let id: UUID
    public let step: String
    /// From 0 to 1; nil while the step can't tell how long it will take.
    public let fraction: Double?
}

/// Saving articles: fetching, extracting and storing each in turn, with its images.
extension Library {
    /// What's waiting to be saved, in the order it will be: articles first, then books, oldest of each first.
    public var waiting: (articles: [Article], books: [Book]) {
        (articles.filter { $0.state == .queued }.reversed(), books.filter { $0.state == .queued }.reversed())
    }

    /// Waits until nothing is queued to download or convert.
    public func idle() async {
        while let worker { await worker.value }
    }

    public func resumeDownloads() {
        guard worker == nil else { return }
        retryWake?.cancel()
        retryWake = nil
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                self.worker = nil; self.saving = nil; self.imageActivity = nil
                // Paused, so nothing's started again until it's resumed.
                if !Task.isCancelled { self.wakeForRetry() }
            }
            while !Task.isCancelled {
                let now = Date.now
                func due(_ article: Article) -> Bool {
                    switch article.saveState {
                    case .queued: true
                    case .waiting(let until, _, _): until <= now
                    default: false
                    }
                }
                if let article = self.articles.last(where: due) {
                    await self.download(article)
                } else if let book = self.books.last(where: { $0.state == .queued }) {
                    await self.convert(book)
                } else if let article = self.cached.first(where: due) {
                    await self.download(article)
                } else if self.describesImages, let article = (self.articles + self.cached).first(where: { $0.imagesUndescribed }) {
                    await self.describeImages(of: article)
                } else if self.describesImages, let book = self.books.first(where: { $0.imagesUndescribed }) {
                    await self.describeImages(of: book)
                } else { break }
            }
        }
    }

    /// Starts the worker again when the soonest save waiting to be retried is due.
    func wakeForRetry() {
        retryWake?.cancel()
        retryWake = nil
        let retries = (articles + cached).compactMap { if case .waiting(let until, _, _) = $0.saveState { until } else { nil } }
        guard let next = retries.min() else { return }
        retryWake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0))) } catch { return }
            self?.resumeDownloads()
        }
    }

    /// Tries the saves waiting to be retried now, such as once the network is back.
    public func retryWaiting() {
        for article in articles + cached {
            if case .waiting(_, let failures, _) = article.saveState { article.saveState = .queued(failures: failures) }
        }
        resumeDownloads()
    }

    /// Whether anything is queued, being saved, or waiting to be retried.
    public var hasPendingSaves: Bool {
        (articles + cached).contains {
            switch $0.saveState {
            case .queued, .downloading, .waiting: true
            case .saved, .failed: false
            }
        } || books.contains { $0.state == .queued || $0.state == .downloading }
    }

    /// Adds what's shared and saves everything queued or waiting, returning once nothing more is due,
    /// for when the system gives Reed time to save in the background.
    public func saveAll(from inbox: ShareInbox?) async {
        if let inbox { await addShared(from: inbox) }
        retryWaiting()
        await idle()
        save()
    }

    /// Stops saving, putting back in the queue what was being saved, to carry on with `resumeDownloads()`.
    public func pauseDownloads() {
        worker?.cancel()
        retryWake?.cancel()
        retryWake = nil
    }

    /// Retries waiting saves whenever the network comes back.
    public func watchNetwork() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if connected && self.connected == false { self.retryWaiting() }
                self.connected = connected
            }
        }
        monitor.start(queue: DispatchQueue(label: "town.versary.reed.network"))
        networkMonitor = monitor
    }

    public func retry(_ article: Article) {
        switch article.saveState {
        case .queued, .downloading: return
        case .waiting, .saved, .failed: article.saveState = .queued(failures: 0)
        }
        save()
        resumeDownloads()
    }

    /// The article as served or, when that holds little text, as its scripts render it: some pages arrive
    /// as an empty shell and build the article on load.
    func extract(_ page: DownloadedPage, report: (String) -> Void) async throws -> ExtractedArticle {
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

    func readPDF(_ data: Data, url: URL) async throws -> (ExtractedArticle, [String: Data]) {
        guard #available(macOS 26, iOS 26, *) else { throw ReedError.pdfNeedsNewerSystem }
        return try await PDFArticle.extract(data, url: url)
    }

    func download(_ article: Article) async {
        var failures = article.saveState.failures
        article.saveState = .downloading(failures: failures)
        save()
        var staging: URL?
        // Caching happens quietly; only saving to the library is reported.
        func report(_ message: String, fraction: Double? = nil) {
            if article.membership.isSaved { saving = SaveProgress(id: article.id, step: message, fraction: fraction) }
        }
        defer {
            saving = nil
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
                    let found = try await extract(page) { report($0) }
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
            var earlier: (html: String, directory: URL)?
            if let version = article.contentVersion {
                let url = storage.contentURL(article.id, version: version)
                earlier = await Self.read(url).map { (String(decoding: $0, as: UTF8.self), url.deletingLastPathComponent()) }
            }
            // A first save can be read while its images are fetched; a refresh keeps the copy already saved until it's done.
            if contentURL(for: article) == nil {
                try? await savePreview(of: article, extracted, pageURL: pageURL, pictures: pictures)
            }
            let directory = try storage.createStagingDirectory()
            staging = directory
            var missing = try await saveImages(extracted.images, pictures: pictures, into: directory) { done in
                let count = extracted.images.count
                let message = "Saving image \(min(done + 1, count)) of \(count)…"
                imageActivity = message
                report(message, fraction: Double(done) / Double(count))
            }
            missing = try await savingLazyImages(missing, of: extracted.images, pageURL: pageURL, into: directory) { message in
                imageActivity = message
                report(message)
            }
            var body = await Self.replacing(missing, in: extracted.html)
            let (descriptions, deferred) = try await describeImages(in: body, directory: directory, limit: 20,
                                                                    from: Self.describing(extracted.title), previous: earlier) { message, fraction in
                imageActivity = message
                report(message, fraction: fraction)
            }
            body = await ImageDescriptions.applying(descriptions, to: body)
            try await Self.write(Data(Self.document(extracted, pageURL: pageURL, body: body).utf8), to: directory.appendingPathComponent("index.html"))
            let version = UUID().uuidString
            try storage.commit(staging: directory, id: article.id, version: version)
            staging = nil
            describe(article, as: extracted, at: pageURL)
            article.imageCount = extracted.images.count - missing.count
            article.missingImageCount = missing.count
            let previous = article.contentVersion
            article.contentVersion = version
            article.downloadedAt = .now
            article.imagesUndescribed = deferred
            article.saveState = .saved
            try container.mainContext.save()
            if let previous { retire(previous, of: .article(article.id), heldBy: [article.id]) }
            if article.membership.isSaved {
                reindex(article)
                lookForSiteFeeds(of: article)
            }
        } catch where Task.isCancelled {
            article.saveState = .queued(failures: failures)
            save()
        } catch {
            // A failed refresh leaves the copy already saved readable.
            if contentURL(for: article) != nil {
                article.saveState = .saved
                if article.membership.isSaved { errorMessage = error.localizedDescription }
            } else if let wait = SaveRetry.wait(after: error, failures: &failures) {
                article.saveState = .waiting(until: .now + wait, failures: failures, reason: SaveRetry.message(for: error))
            } else {
                article.saveState = .failed(reason: error.localizedDescription)
            }
            save()
        }
        if article.membership == .discarded, !pendingDeletes.contains(article.id) { erase(article) }
    }

    /// How many images are fetched at once.
    static let imageFetches = 4

    /// Writes `images` into `directory`, those in `pictures` as they are and the rest fetched a few at a time, and returns
    /// those it couldn't. Fetching stops at 40 images or 64MB, and a host that doesn't answer isn't asked for the rest of its images.
    /// `report` is told how many are done as each one is.
    func saveImages(_ images: [ExtractedArticle.Image], pictures: [String: Data], into directory: URL,
                    report: (Int) -> Void) async throws -> [ExtractedArticle.Image] {
        let budget = 64 * 1024 * 1024
        var next = 0, running = 0, done = 0, totalBytes = 0
        var failed = Set<Int>(), unresponsive = Set<String>()
        report(0)
        try await withThrowingTaskGroup(of: (index: Int, result: Result<Data, Error>).self) { group in
            while true {
                try Task.checkCancellation()
                while running < Self.imageFetches, next < images.count {
                    let index = next, image = images[index]
                    next += 1
                    if let data = pictures[image.filename] {
                        try await Self.write(data, to: directory.appendingPathComponent(image.filename))
                        done += 1
                        continue
                    }
                    guard index < 40, totalBytes < budget, let url = URL(string: image.url),
                          !unresponsive.contains(url.host() ?? "") else {
                        failed.insert(index)
                        done += 1
                        continue
                    }
                    running += 1
                    group.addTask { [downloader] in
                        do { return (index, .success(try await downloader.image(at: url))) }
                        catch is CancellationError { throw CancellationError() }
                        catch { return (index, .failure(error)) }
                    }
                }
                guard let fetched = try await group.next() else { break }
                running -= 1
                done += 1
                switch fetched.result {
                case .success(let data) where totalBytes + data.count <= budget:
                    try await Self.write(data, to: directory.appendingPathComponent(images[fetched.index].filename))
                    totalBytes += data.count
                case .failure(let error as URLError) where [.timedOut, .cannotConnectToHost].contains(error.code):
                    if let host = URL(string: images[fetched.index].url)?.host() { unresponsive.insert(host) }
                    failed.insert(fetched.index)
                default:
                    failed.insert(fetched.index)
                }
                report(done)
            }
        }
        return images.indices.filter(failed.contains).map { images[$0] }
    }

    /// Fetches those of `missing` the page named lazily, and that `saveImages` tried, again from wherever the page's own
    /// scripts point them, which needn't be beside the page. Returns the images still missing.
    func savingLazyImages(_ missing: [ExtractedArticle.Image], of images: [ExtractedArticle.Image], pageURL: URL, into directory: URL,
                          report: (String) -> Void) async throws -> [ExtractedArticle.Image] {
        let tried = Set(images.prefix(40).map(\.filename))
        let lazy = missing.filter { $0.lazy && tried.contains($0.filename) }
        guard !lazy.isEmpty else { return missing }
        report("Rendering \(pageURL.host() ?? "the page")…")
        let sources = (try? await renderer.lazyImageSources(at: pageURL)) ?? [:]
        try Task.checkCancellation()
        let moved = lazy.compactMap { image in
            sources[image.url].map { ExtractedArticle.Image(url: $0, filename: image.filename, alt: image.alt) }
        }
        guard !moved.isEmpty else { return missing }
        let failed = Set(try await saveImages(moved, pictures: [:], into: directory) { done in
            report("Saving image \(min(done + 1, moved.count)) of \(moved.count)…")
        }.map(\.filename))
        let saved = Set(moved.map(\.filename)).subtracting(failed)
        return missing.filter { !saved.contains($0.filename) }
    }

    /// Saves the article's text, with any pictures that came with it, as its content until the full copy replaces it.
    /// The images still to fetch count as missing, so the copy reads as partial if saving stops short.
    func savePreview(of article: Article, _ extracted: ExtractedArticle, pageURL: URL, pictures: [String: Data]) async throws {
        let directory = try storage.createStagingDirectory()
        let pending = extracted.images.filter { pictures[$0.filename] == nil }
        let version = UUID().uuidString
        do {
            for image in extracted.images {
                if let data = pictures[image.filename] { try await Self.write(data, to: directory.appendingPathComponent(image.filename)) }
            }
            let body = await Self.replacing(pending, in: extracted.html, note: "Saving image")
            try await Self.write(Data(Self.document(extracted, pageURL: pageURL, body: body).utf8), to: directory.appendingPathComponent("index.html"))
            try storage.commit(staging: directory, id: article.id, version: version)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        describe(article, as: extracted, at: pageURL)
        article.imageCount = extracted.images.count - pending.count
        article.missingImageCount = pending.count
        article.contentVersion = version
        try container.mainContext.save()
    }

    func describe(_ article: Article, as extracted: ExtractedArticle, at pageURL: URL) {
        article.title = extracted.title
        article.author = extracted.author
        article.publishedAt = extracted.publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        article.excerpt = extracted.excerpt
        article.resolvedURL = pageURL.absoluteString
        article.wordCount = extracted.wordCount
        article.leadsToOtherChapters = ChapterLinks(page: extracted.page, url: pageURL).leadsToOtherChapters
    }

    nonisolated static func document(_ extracted: ExtractedArticle, pageURL: URL, body: String) -> String {
        ArticleHTML.document(title: extracted.title, author: extracted.author, domain: Article.domain(of: pageURL) ?? "",
                             minutes: Article.readingMinutes(words: extracted.wordCount), body: body)
    }

    /// Alt text for the pictures in `html` saved in `directory` that have none, by file name: as `previous` described them,
    /// or else from the on-device model.
    /// Alt text for the pictures in `html` that have none, by file name, and whether some were left to describe later
    /// as `describesImages` is off.
    func describeImages(in html: String, directory: URL, limit: Int, from source: String, previous: (html: String, directory: URL)?,
                        report: (String, Double) -> Void) async throws -> (descriptions: [String: String], deferred: Bool) {
        guard ImageDescriptions.available || previous != nil else { return ([:], false) }
        let undescribed = await ImageDescriptions.undescribed(in: html, directory: directory, limit: limit)
        var descriptions: [String: String] = [:]
        if let previous { descriptions = await ImageDescriptions.carried(undescribed, in: directory, from: previous) }
        guard ImageDescriptions.available else { return (descriptions, false) }
        let remaining = undescribed.filter { descriptions[$0] == nil }
        for (index, name) in remaining.enumerated() {
            try Task.checkCancellation()
            guard describesImages else { return (descriptions, true) }
            report("Describing image \(index + 1) of \(remaining.count)…", Double(index) / Double(remaining.count))
            descriptions[name] = await ImageDescriptions.describe(directory.appendingPathComponent(name), from: source)
        }
        return (descriptions, false)
    }

    nonisolated static func describing(_ title: String) -> String { "an article titled \"\(title)\"" }

    /// Describes the pictures of an article saved while Reed was in the background, as a new version.
    func describeImages(of article: Article) async {
        guard let version = article.contentVersion else { article.imagesUndescribed = false; return }
        let id = article.id
        let saved = storage.contentURL(id, version: version).deletingLastPathComponent()
        let described = await redescribing(saved, files: ["index.html"], limit: 20, from: Self.describing(article.title)) {
            try storage.commit(staging: $0, id: id, version: $1)
        }
        guard let described else {
            // Unreadable, so not worth trying again; or paused, to carry on later.
            if !Task.isCancelled { article.imagesUndescribed = false; save() }
            return
        }
        guard let new = described.version else { article.imagesUndescribed = described.deferred; save(); return }
        // Saved again meanwhile, which describes it anew.
        guard article.contentVersion == version else { try? storage.removeArticleVersion(id, version: new); return }
        article.contentVersion = new
        article.imagesUndescribed = described.deferred
        save()
        retire(version, of: .article(id), heldBy: [id])
    }

    /// Describes the pictures of a book converted while Reed was in the background, as a new version.
    func describeImages(of book: Book) async {
        guard let version = book.contentVersion else { book.imagesUndescribed = false; return }
        let id = book.id
        let saved = storage.bookDirectory(id).appendingPathComponent(version, isDirectory: true)
        let described = await redescribing(saved, files: book.chapters.map { BookFiles.chapter($0.index) }, limit: 60,
                                           from: "the book \"\(book.title)\"") {
            try storage.commitBook(staging: $0, id: id, version: $1)
        }
        guard let described else {
            if !Task.isCancelled { book.imagesUndescribed = false; save() }
            return
        }
        guard let new = described.version else { book.imagesUndescribed = described.deferred; save(); return }
        guard book.contentVersion == version else { try? storage.removeBookVersion(id, version: new); return }
        book.contentVersion = new
        book.imagesUndescribed = described.deferred
        save()
        retire(version, of: .book(id), heldBy: Set(book.chapters.map(\.id)).union([id]))
    }

    /// Copies a saved version with alt text written into `files` for its undescribed pictures, committing it with `commit`
    /// as a new version, unless none were described. Nil if it can't be read, or saving was paused.
    private func redescribing(_ saved: URL, files: [String], limit: Int, from source: String,
                              commit: (URL, String) throws -> Void) async -> (version: String?, deferred: Bool)? {
        do {
            let staging = try storage.createStagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            try await Self.copyContents(of: saved, to: staging)
            var pages: [String: String] = [:]
            for file in files {
                guard let data = await Self.read(staging.appendingPathComponent(file)) else { throw ReedError.damagedArticle }
                pages[file] = String(decoding: data, as: UTF8.self)
            }
            let (descriptions, deferred) = try await describeImages(in: files.compactMap { pages[$0] }.joined(), directory: staging,
                                                                    limit: limit, from: source, previous: nil) { _, _ in }
            guard !descriptions.isEmpty else { return (nil, deferred) }
            for (file, html) in pages {
                try await Self.write(Data(await ImageDescriptions.applying(descriptions, to: html).utf8), to: staging.appendingPathComponent(file))
            }
            let version = UUID().uuidString
            try commit(staging, version)
            return (version, deferred)
        } catch {
            return nil
        }
    }

    nonisolated static func copyContents(of directory: URL, to destination: URL) async throws {
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }

    nonisolated static func read(_ url: URL) async -> Data? { try? Data(contentsOf: url) }

    nonisolated static func write(_ data: Data, to url: URL) async throws { try data.write(to: url, options: .atomic) }

    /// `html` with each of `images` replaced by a note, such as that it's unavailable, keeping its alt text, so the reader
    /// never makes a remote or broken image request.
    nonisolated static func replacing(_ images: [ExtractedArticle.Image], in html: String, note: String = "Image unavailable") async -> String {
        guard !images.isEmpty else { return html }
        let notes = Dictionary(images.map { image in
            (image.filename, "<span class=\"missing-image\">[\(note)\(image.alt.isEmpty ? "" : ": " + ArticleHTML.escape(image.alt))]</span>")
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
}

/// When to try a save again after it fails in a way that may pass: offline, or the site slow or busy.
enum SaveRetry {
    /// How long to wait after each failure in a row, the last failure being given up on.
    static let backoff: [TimeInterval] = [30, 2 * 60, 10 * 60, 30 * 60]
    /// Being offline says nothing about the site, so it's waited out without counting as a failure,
    /// and the network coming back or Reed being opened tries again sooner.
    static let offlineWait: TimeInterval = 5 * 60

    /// How long to wait before trying again after `error`, counting it in `failures`; nil to give up.
    static func wait(after error: Error, failures: inout Int) -> TimeInterval? {
        if isOffline(error) { return offlineWait }
        guard mayPass(error) else { return nil }
        failures += 1
        return failures <= backoff.count ? backoff[failures - 1] : nil
    }

    static func message(for error: Error) -> String {
        if isOffline(error) { return "Waiting for a connection to save." }
        if case ReedError.httpStatus(let code) = error { return "The site is busy (HTTP \(code)), so Reed will try again shortly." }
        return "The site didn't answer, so Reed will try again shortly."
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive].contains(error.code)
    }

    static func mayPass(_ error: Error) -> Bool {
        switch error {
        case let error as URLError: [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
        case ReedError.httpStatus(let code): [408, 425, 429, 500, 502, 503, 504].contains(code)
        default: false
        }
    }
}
