import Foundation
import Testing
@testable import ReedCore

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: "epub"))
}

@Test func epubChaptersFollowTheTableOfContents() throws {
    let book = try EPUB(data: Data(contentsOf: fixture("book-epub3")))
    #expect(book.title == "The Mill on the River" && book.author == "Ada Example")
    #expect(book.cover == "OEBPS/Images/cover.png")
    // The cover comes before the first entry; the entry pointing into chapter one stays with it, and its second file follows.
    #expect(book.chapters == [
        EPUB.Chapter(title: nil, parts: [EPUB.Part("OEBPS/Text/cover.xhtml")]),
        EPUB.Chapter(title: "Chapter One: The Mill", parts: [EPUB.Part("OEBPS/Text/one.xhtml"), EPUB.Part("OEBPS/Text/one b.xhtml")]),
        EPUB.Chapter(title: "Chapter Two", parts: [EPUB.Part("OEBPS/Text/two.xhtml")]),
    ])
}

@Test func chaptersSharingAFileAreSplitAtTheirElements() {
    let contents = [EPUB.Entry(title: "Title", path: "a"), EPUB.Entry(title: "One", path: "a", fragment: "one"),
                    EPUB.Entry(title: "Section", path: "a", fragment: "s", isSection: true), EPUB.Entry(title: "Two", path: "a", fragment: "two"),
                    EPUB.Entry(title: "Three", path: "b")]
    #expect(EPUB.chapters(spine: ["a", "b"], contents: contents) == [
        EPUB.Chapter(title: "Title", parts: [EPUB.Part("a", to: "one")]),
        EPUB.Chapter(title: "One", parts: [EPUB.Part("a", from: "one", to: "two")]),
        EPUB.Chapter(title: "Two", parts: [EPUB.Part("a", from: "two")]),
        EPUB.Chapter(title: "Three", parts: [EPUB.Part("b")]),
    ])
}

@Test func chaptersSharingAFileFollowItsOrder() {
    let contents = [EPUB.Entry(title: "Two", path: "a", fragment: "two"), EPUB.Entry(title: "One", path: "a", fragment: "one")]
    #expect(EPUB.chapters(spine: ["a"], contents: contents, ids: ["a": ["top", "one", "two"]]) == [
        EPUB.Chapter(title: nil, parts: [EPUB.Part("a", to: "one")]),
        EPUB.Chapter(title: "One", parts: [EPUB.Part("a", from: "one", to: "two")]),
        EPUB.Chapter(title: "Two", parts: [EPUB.Part("a", from: "two")]),
    ])
}

@Test func epub2BooksUseTheirNCX() throws {
    let book = try EPUB(data: Data(contentsOf: fixture("book-epub2")))
    #expect(book.title == "An Old Book" && book.author == "B. Writer" && book.cover == "OEBPS/cover.png")
    #expect(book.chapters.map(\.title) == ["Part the First", "Part the Second"])
}

@Test func lockedAndDamagedBooksAreRefused() throws {
    #expect(throws: ReedError.self) { try EPUB(data: Data(contentsOf: fixture("book-protected"))) }
    #expect(throws: ReedError.self) { try EPUB(data: Data("not a zip".utf8)) }
}

@Test func bookPathsResolveLikeLinks() {
    #expect(EPUB.resolve("../Images/a%20b.png#x", from: "OEBPS/Text/one.xhtml") == "OEBPS/Images/a b.png")
    #expect(EPUB.resolve("chapter.xhtml", from: "content.opf") == "chapter.xhtml")
    #expect(EPUB.chapters(spine: ["a", "b"], contents: []) == [EPUB.Chapter(title: nil, parts: [EPUB.Part("a")]), EPUB.Chapter(title: nil, parts: [EPUB.Part("b")])])
}

@Test @MainActor func booksAreConvertedAChapterAtATime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(root: root)
    let book = try await library.add(bookAt: fixture("book-epub3"), name: "book-epub3.epub")
    #expect(try await library.add(bookAt: fixture("book-epub3"), name: "again.epub") === book)
    #expect(library.books.count == 1 && library.articles.isEmpty)

    let deadline = Date().addingTimeInterval(60)
    while book.state != .ready && book.state != .failed && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(book.state == .ready, "\(book.failureMessage ?? "")")
    // The cover page has nothing to read, so the book starts at chapter one.
    let chapters = book.orderedChapters
    #expect(chapters.map(\.title) == ["Chapter One: The Mill", "Chapter Two"])
    #expect(library.cover(of: book) != nil)

    let one = try String(contentsOf: try #require(library.contentURL(for: chapters[0])), encoding: .utf8)
    #expect(one.contains("The Mill on the River"))
    #expect(one.components(separatedBy: "Chapter One").count == 3, "the title and header once each, not the heading too")
    #expect(one.contains("href=\"1.html#end\"") && one.contains("href=\"#willows\""))
    #expect(one.contains("src=\"book-OEBPS_Images_plate.png\"") && one.contains("https://example.com/mill"))
    #expect(one.contains("class=\"next-chapter\" href=\"1.html\""))
    let two = try String(contentsOf: try #require(library.contentURL(for: chapters[1])), encoding: .utf8)
    #expect(!two.contains("next-chapter\""))

    // The card isn't read aloud.
    let passages = try #require(library.passages(for: chapters[0]))
    #expect(!passages.contains { $0.contains("NEXT CHAPTER") })
    library.setNote("A good mill", at: 1, for: chapters[0])
    #expect(library.notes(for: chapters[0], passages: passages).map(\.text) == ["A good mill"])
    #expect(library.notes(for: chapters[1], passages: try #require(library.passages(for: chapters[1]))).isEmpty)

    // Converting again moves notes with their chapters, and sets aside those of chapters that are gone.
    library.setNote("A good river", at: 1, for: chapters[1])
    library.moveNotes(of: book, as: [0: 1])
    let notes = library.storage.bookDirectory(book.id).appendingPathComponent("Notes")
    #expect(try String(contentsOf: notes.appendingPathComponent("1.json"), encoding: .utf8).contains("A good mill"))
    #expect(!FileManager.default.fileExists(atPath: notes.appendingPathComponent("0.json").path))
    let unplaced = try FileManager.default.contentsOfDirectory(at: notes.appendingPathComponent("Unplaced"), includingPropertiesForKeys: nil)
    #expect(try unplaced.map { try String(contentsOf: $0, encoding: .utf8) }.joined().contains("A good river"))

    #expect(library.next(after: chapters[0]) === chapters[1] && library.next(after: chapters[1]) == nil)
    library.updateProgress(chapters[0], value: 1)
    library.open(chapters[1])
    #expect(book.upNext === chapters[1] && book.progress > 0.4 && book.progress < 0.8)

    let directory = library.storage.bookDirectory(book.id)
    library.delete(book)
    #expect(library.books.isEmpty && !FileManager.default.fileExists(atPath: directory.path))
}

@Test @MainActor func sharedBooksAreAddedFromTheInbox() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = ShareInbox(directory: root.appendingPathComponent("Inbox"))
    try inbox.deposit(bookAt: fixture("book-epub2"), name: "Old Book")
    try inbox.deposit(bookAt: fixture("book-protected"))
    let library = try Library(root: root.appendingPathComponent("Library"))
    await library.addShared(from: inbox)
    #expect(library.books.map(\.title) == ["An Old Book"])
    #expect(library.errorMessage == ReedError.protectedBook.localizedDescription)
    #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path).isEmpty)
    await library.idle()
}

@Test @MainActor func convertingAgainKeepsProgressByWhereEachChapterStarts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(root: root)
    let book = try await library.add(bookAt: fixture("book-epub3"), name: "book-epub3.epub")
    await library.idle()
    #expect(book.state == .ready, "\(book.failureMessage ?? "")")
    let chapters = book.orderedChapters
    #expect(chapters.allSatisfy { $0.start != nil })

    // Renumbered and renamed, so only its start finds it.
    chapters[1].index = 7
    chapters[1].title = "Renamed"
    chapters[1].progress = 0.4
    book.currentChapter = 7
    // Saved before chapters knew their start, so it's found by its place and title.
    chapters[0].start = nil
    chapters[0].isRead = true
    library.retry(book)
    await library.idle()

    #expect(book.state == .ready, "\(book.failureMessage ?? "")")
    let converted = book.orderedChapters
    #expect(converted.map(\.title) == ["Chapter One: The Mill", "Chapter Two"])
    #expect(converted.map(\.isRead) == [true, false] && converted.map(\.progress) == [0, 0.4])
    #expect(book.currentChapter == 1)
}
