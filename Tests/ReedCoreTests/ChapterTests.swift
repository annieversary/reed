import Foundation
import SwiftData
import Testing
@testable import ReedCore

private let book = "https://example.com/book/"

/// A chapter of a serial in the style of an old hand-written site: chapters linked by their numbers, and a contents page.
private func chapter(_ number: Int, of count: Int, contents: Bool = true) -> PageLinks {
    var links = [PageLinks.Link(url: book + "index.html", text: "Top"), PageLinks.Link(url: "https://elsewhere.org/", text: "Chapter \(number + 1)")]
    if number > 1 { links.append(.init(url: book + "ch\(number - 1).html", text: "Chapter \(number - 1)")) }
    if contents { links.append(.init(url: book + "contents.html", text: "Contents")) }
    if number < count { links.append(.init(url: book + "ch\(number + 1).html", text: "Chapter \(number + 1)")) }
    return PageLinks(title: "The Book: Chapter \(number)", links: links)
}

private func contents(_ count: Int, newestFirst: Bool = false) -> PageLinks {
    let chapters = (1...count).map { PageLinks.Link(url: book + "ch\($0).html", text: "Chapter \($0)") }
    return PageLinks(title: "The Book: Contents", links: [.init(url: book + "index.html", text: "Top")]
        + (newestFirst ? chapters.reversed() : chapters) + [.init(url: book + "all.html", text: "entire book")])
}

@MainActor private func finder(_ pages: [String: PageLinks], fetched: @escaping (URL) -> Void = { _ in }) -> ChapterFinder {
    ChapterFinder { url in
        fetched(url)
        guard let page = pages[url.absoluteString] else { throw ReedError.httpStatus(404) }
        return (url, page)
    }
}

@Test func chaptersAreFoundFromTheLinksBetweenThem() {
    let first = ChapterLinks(page: chapter(1, of: 3), url: URL(string: book + "ch1.html")!)
    #expect(first.previous == nil)
    #expect(first.next?.absoluteString == book + "ch2.html")
    #expect(first.contents?.absoluteString == book + "contents.html")
    let middle = ChapterLinks(page: chapter(2, of: 3), url: URL(string: book + "ch2.html")!)
    #expect(middle.previous?.absoluteString == book + "ch1.html")
    #expect(middle.next?.absoluteString == book + "ch3.html")
}

@Test func plainNextLinksOnlyCountOnNumberedPages() {
    let url = URL(string: "https://blog.example.com/a-post")!
    let post = PageLinks(title: "Thoughts on gardening", links: [
        .init(url: "https://blog.example.com/another-post", text: "Older post", rel: "prev"),
        .init(url: "https://blog.example.com/newer-post", text: "Next →", rel: "next")
    ])
    #expect(!ChapterLinks(page: post, url: url).leadsToOtherChapters)
    var serial = post
    serial.links.append(.init(url: "https://blog.example.com/the-storm", text: "→ Next Chapter"))
    #expect(ChapterLinks(page: serial, url: url).next?.absoluteString == "https://blog.example.com/the-storm")
    serial.title = "Thoughts on gardening, part 2"
    #expect(ChapterLinks(page: serial, url: url).previous?.absoluteString == "https://blog.example.com/another-post")
}

@Test @MainActor func contentsPageGivesEveryChapterInOrder() async throws {
    var pages = ["contents.html": contents(4)]
    for number in 1...4 { pages["ch\(number).html"] = chapter(number, of: 4) }
    var fetched: [String] = []
    let search = try await finder(pages.reduce(into: [:]) { $0[book + $1.key] = $1.value }) { fetched.append($0.lastPathComponent) }
        .chapters(around: URL(string: book + "ch3.html")!) { _ in }
    #expect(search.chapters.map(\.url.lastPathComponent) == ["ch1.html", "ch2.html", "ch3.html", "ch4.html"])
    #expect(search.chapters.first?.title == "Chapter 1")
    #expect(search.name == "The Book")
    #expect(fetched == ["ch3.html", "contents.html"])

    pages["contents.html"] = contents(4, newestFirst: true)
    let newestFirst = try await finder(pages.reduce(into: [:]) { $0[book + $1.key] = $1.value }).chapters(around: URL(string: book + "ch3.html")!) { _ in }
    #expect(newestFirst.chapters.map(\.url.lastPathComponent) == ["ch1.html", "ch2.html", "ch3.html", "ch4.html"])
}

@Test @MainActor func chaptersAreFollowedBothWaysWithoutAContentsPage() async throws {
    var pages: [String: PageLinks] = [:]
    for number in 1...5 { pages[book + "ch\(number).html"] = chapter(number, of: 5, contents: false) }
    // A chapter leading back to one already found doesn't go round again.
    pages[book + "ch5.html"]!.links.append(.init(url: book + "ch1.html", text: "Chapter 6"))
    var reports: [Int] = []
    let search = try await finder(pages).chapters(around: URL(string: book + "ch3.html")!) { reports.append($0.count) }
    #expect(search.chapters.map(\.url.lastPathComponent) == ["ch1.html", "ch2.html", "ch3.html", "ch4.html", "ch5.html"])
    #expect(search.chapters.map(\.title).last == "The Book: Chapter 5")
    #expect(search.name == "The Book")
    #expect(reports == [1, 2, 3, 4, 5])

    // A chapter that won't load ends the search there.
    pages[book + "ch4.html"] = nil
    let partial = try await finder(pages).chapters(around: URL(string: book + "ch2.html")!) { _ in }
    #expect(partial.chapters.map(\.url.lastPathComponent) == ["ch1.html", "ch2.html", "ch3.html"])
}

@Test @MainActor func extractionKeepsTheLinksBetweenChapters() async throws {
    let paragraph = "<p>" + String(repeating: "Caroline typed quickly as she discussed the day's business with the Supreme Being. ", count: 4) + "</p>"
    let html = """
    <html><head><title>The Book: Chapter 1</title></head><body>\(paragraph)\(paragraph)
    <a href="contents.html">Contents</a> <a href="ch2.html#top"><img src="arrow.gif" alt="Chapter 2"></a></body></html>
    """
    let url = URL(string: book + "ch1.html")!
    let article = try await ArticleExtractor().extract(html: html, url: url, fetch: { _ in "" })
    let links = ChapterLinks(page: article.page, url: url)
    #expect(links.next?.absoluteString == book + "ch2.html")
    #expect(links.contents?.absoluteString == book + "contents.html")
    #expect(try await ArticleExtractor().pageLinks(html: html, url: url) == article.page)
}

@Test @MainActor func gatheredChaptersKeepTheOrderTheyWereFoundIn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try ArticleStorage(root: root)
    do {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store")))
        for title in ["Prologue", "The storm", "Aftermath", "Unrelated"] {
            let article = Article(url: URL(string: "https://example.com/" + title.lowercased().replacingOccurrences(of: " ", with: "-"))!)
            article.title = title
            // Failed, so the library doesn't try to download them.
            article.state = .failed
            container.mainContext.insert(article)
        }
        try container.mainContext.save()
    }
    let library = try Library(root: root)
    func titled(_ title: String) -> Article { library.articles.first { $0.title == title }! }
    let first = try #require(library.gather([titled("The storm"), titled("Prologue")], named: "Storms"))
    #expect(library.parts(of: first).map(\.title) == ["The storm", "Prologue"])
    // Gathering again extends the series one of them is already in, in the new order.
    let again = try #require(library.gather([titled("Prologue"), titled("The storm"), titled("Aftermath")], named: "Ignored"))
    #expect(again.id == first.id)
    #expect(library.series.map(\.name) == ["Storms"])
    #expect(library.parts(of: again).map(\.title) == ["Prologue", "The storm", "Aftermath"])
}
