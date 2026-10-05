import Foundation
import SwiftData

/// EPUB books, converted into a saved document per chapter.
extension Library {
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

    func hasContent(_ book: Book) -> Bool {
        guard let version = book.contentVersion else { return false }
        return FileManager.default.fileExists(atPath: storage.bookDirectory(book.id).appendingPathComponent(version).path)
    }

    /// Converts the book's EPUB into a reader document per chapter, sharing its images, and replaces any earlier version.
    func convert(_ book: Book) async {
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
                                                    minutes: Article.readingMinutes(words: chapter.wordCount), body: chapter.html, after: after)
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

    /// Renumbers a book's notes after converting it again moved its chapters, from each old index to the new.
    /// Notes of a chapter that's gone are set aside in `Notes/Unplaced` rather than left beside another chapter.
    func moveNotes(of book: Book, as moved: [Int: Int]) {
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
