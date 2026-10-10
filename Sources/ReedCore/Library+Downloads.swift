import Foundation
import SwiftData

/// Saving articles: fetching, extracting and storing each in turn, with its images.
extension Library {
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
                if let article = self.articles.last(where: { $0.state == .queued }) {
                    await self.download(article)
                } else if let book = self.books.last(where: { $0.state == .queued }) {
                    await self.convert(book)
                } else if let article = self.cached.first(where: { $0.state == .queued }) {
                    await self.download(article)
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
            var body = await Self.replacing(missing, in: extracted.html)
            let descriptions = try await describeImages(in: body, directory: directory, limit: 20, from: "an article titled \"\(extracted.title)\"",
                                                        previous: earlier) { message in
                imageActivity = message
                report(message)
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
            article.state = missing.isEmpty ? .ready : .partial
            article.failureMessage = nil
            try container.mainContext.save()
            if let previous { try? storage.removeArticleVersion(article.id, version: previous) }
            if !article.isCached, !discarded.contains(article.id) { reindex(article) }
        } catch {
            // A failed refresh leaves the copy already saved readable.
            if contentURL(for: article) != nil {
                article.state = article.missingImageCount > 0 ? .partial : .ready
                if !article.isCached, !discarded.contains(article.id) { errorMessage = error.localizedDescription }
            } else {
                article.state = .failed
                article.failureMessage = error.localizedDescription
            }
            save()
        }
        if discarded.remove(article.id) != nil { erase(article) }
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
    func describeImages(in html: String, directory: URL, limit: Int, from source: String, previous: (html: String, directory: URL)?,
                        report: (String) -> Void) async throws -> [String: String] {
        guard ImageDescriptions.available || previous != nil else { return [:] }
        let undescribed = await ImageDescriptions.undescribed(in: html, directory: directory, limit: limit)
        var descriptions: [String: String] = [:]
        if let previous { descriptions = await ImageDescriptions.carried(undescribed, in: directory, from: previous) }
        guard ImageDescriptions.available else { return descriptions }
        let remaining = undescribed.filter { descriptions[$0] == nil }
        for (index, name) in remaining.enumerated() {
            try Task.checkCancellation()
            report("Describing image \(index + 1) of \(remaining.count)…")
            descriptions[name] = await ImageDescriptions.describe(directory.appendingPathComponent(name), from: source)
        }
        return descriptions
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
