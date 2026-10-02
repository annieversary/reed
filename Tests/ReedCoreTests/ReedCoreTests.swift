import Foundation
import SwiftData
import Testing
@testable import ReedCore

@Test func canonicalURLs() throws {
    #expect(try ArticleURL.parse("  EXAMPLE.com/story#heading  ").absoluteString == "https://example.com/story")
    #expect(try ArticleURL.parse("https://example.com:443").absoluteString == "https://example.com/")
    #expect(try ArticleURL.parse("http://example.com:80/a?edition=2").absoluteString == "http://example.com/a?edition=2")
    for input in ["", "not a url", "file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com", "https://"] {
        #expect(throws: (any Error).self) { try ArticleURL.parse(input) }
    }
}

@Test func articlePackagesSurviveStorageRecreation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ArticleStorage(root: root)
    let staging = try storage.createStagingDirectory()
    let id = UUID()
    try "<h1>Offline article</h1>".write(to: staging.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try Data([1, 2, 3]).write(to: staging.appendingPathComponent("image-0"))
    #expect(!FileManager.default.fileExists(atPath: storage.contentURL(id, version: "one").path))
    try storage.commit(staging: staging, id: id, version: "one")
    let reopened = try ArticleStorage(root: root)
    #expect(try String(contentsOf: reopened.contentURL(id, version: "one"), encoding: .utf8) == "<h1>Offline article</h1>")
    #expect(try Data(contentsOf: reopened.articleDirectory(id).appendingPathComponent("one/image-0")) == Data([1, 2, 3]))
    try reopened.removeArticle(id)
    #expect(!FileManager.default.fileExists(atPath: reopened.articleDirectory(id).path))
}

@Test func failedReplacementPreservesExistingArticle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ArticleStorage(root: root)
    let id = UUID()
    let first = try storage.createStagingDirectory()
    try "Original".write(to: first.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try storage.commit(staging: first, id: id, version: "original")
    #expect(throws: (any Error).self) {
        try storage.commit(staging: root.appendingPathComponent("nonexistent"), id: id, version: "replacement")
    }
    #expect(try String(contentsOf: storage.contentURL(id, version: "original"), encoding: .utf8) == "Original")
}

@Test func readerEscapesMetadataAndBlocksNetwork() {
    let html = ArticleHTML.document(title: "<script>alert('x')</script>", author: "<img src=x onerror=x>", domain: "example.com", minutes: 3, body: "<p>Trusted sanitized body</p>")
    #expect(!html.contains("<script>"))
    #expect(html.contains("&lt;script&gt;"))
    #expect(html.contains("default-src 'none'; img-src file:"))
    #expect(!html.contains("https://"))
}

@Test @MainActor func persistedMetadataAndInterruptedDownloads() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ArticleStorage(root: root)
    let configuration = ModelConfiguration(url: root.appendingPathComponent("Library.store"))
    do {
        let container = try ModelContainer(for: Article.self, configurations: configuration)
        let article = Article(url: URL(string: "https://example.com/story")!)
        article.state = .downloading
        article.isFavorite = true
        article.progress = 0.45
        container.mainContext.insert(article)
        try container.mainContext.save()
    }
    let library = try Library(root: storage.root)
    #expect(library.articles.count == 1)
    #expect(library.articles[0].state == .queued)
    #expect(library.articles[0].isFavorite)
    #expect(library.articles[0].progress == 0.45)
}

@Test @MainActor func missingOfflineFilesAreNotReportedAsReady() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try ArticleStorage(root: root)
    do {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store")))
        let article = Article(url: URL(string: "https://example.com/missing")!)
        article.state = .ready
        article.contentVersion = "gone"
        container.mainContext.insert(article)
        try container.mainContext.save()
    }
    let library = try Library(root: root)
    #expect(library.articles[0].state == .failed)
    #expect(library.articles[0].failureMessage == ReedError.damagedArticle.localizedDescription)
}

@Test @MainActor func deletionRemovesMetadataAndArticleFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ArticleStorage(root: root)
    let id = UUID()
    let staging = try storage.createStagingDirectory()
    try "Saved article".write(to: staging.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try storage.commit(staging: staging, id: id, version: "v1")
    do {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store")))
        let article = Article(url: URL(string: "https://example.com/deleted")!, id: id)
        article.state = .ready
        article.contentVersion = "v1"
        container.mainContext.insert(article)
        try container.mainContext.save()
    }
    let library = try Library(root: root)
    library.delete(library.articles[0])
    #expect(library.errorMessage == nil)
    #expect(library.articles.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: storage.articleDirectory(id).path))
    let reopened = try Library(root: root)
    #expect(reopened.articles.isEmpty)
}

@Test @MainActor func sharedLinksAreAddedOnceInTheOrderShared() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = ShareInbox(directory: root.appendingPathComponent("Inbox"))
    for link in ["https://reed.invalid/first", "https://reed.invalid/second", "https://reed.invalid/first"] {
        try inbox.deposit(URL(string: link)!)
    }
    // Written by hand, since `deposit` only takes URLs.
    try Data("not a url".utf8).write(to: inbox.directory.appendingPathComponent("9999999999999-bad.link"))
    let library = try Library(root: root.appendingPathComponent("Library"))
    library.addShared(from: inbox)
    #expect(library.errorMessage == nil)
    #expect(library.articles.map(\.originalURL) == ["https://reed.invalid/second", "https://reed.invalid/first"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path).isEmpty)
}

@Test func inboxKeepsLinksThatFailToSave() throws {
    let inbox = ShareInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    try inbox.deposit(URL(string: "https://example.com/a")!)
    #expect(throws: CocoaError.self) { try inbox.drain { _ in throw CocoaError(.fileWriteOutOfSpace) } }
    var saved: [String] = []
    try inbox.drain { saved.append($0) }
    #expect(saved == ["https://example.com/a"])
}

@Test func readerDocumentsBecomePlainText() {
    let document = ArticleHTML.document(title: "Ignored <title>", author: nil, domain: "example.com", minutes: 1,
                                        body: "<h2>Café</h2><p>Fish &amp; chips&#39;<br>at&nbsp;noon &#x2014; <em>fresh</em></p>")
    #expect(ArticleText.plain(document) == "Café Fish & chips' at noon — fresh")
}

@Test func formulasReadAsTextOnlyWhenTheyAreSimple() {
    let body = #"<p>With <math alttext="n" display="inline"><mi>n</mi></math> teeth, "#
        + #"<math alttext="p^{2}\leq n" display="inline"><msup><mi>p</mi><mn>2</mn></msup><mo>≤</mo><mi>n</mi></math> holds.</p>"#
    #expect(ArticleText.plain(body) == "With n teeth, holds.")
    let labelled = body.replacing(#"display="inline"><msup>"#, with: #"display="inline" aria-label="p squared is at most n"><msup>"#)
    #expect(ArticleText.plain(labelled) == "With n teeth, p squared is at most n holds.")
}

@Test func narrationReadsBlocksButSkipsCodeAndFigures() {
    let document = ArticleHTML.document(title: "Ignored <title>", author: "Byline", domain: "example.com", minutes: 4, body: """
        <h2>Fish &amp; chips</h2><p>First line
        continues here.</p><figure><img src="image-0"><figcaption>A caption</figcaption></figure>
        <pre><code>let x = 1</code></pre><ul><li>One</li><li>Two<br>lines</li></ul>
        <p><span class="missing-image">[Image unavailable: chart]</span></p><blockquote><p>Quoted</p></blockquote><p> — </p>
        """)
    #expect(ArticleSpeech.passages(title: "A Title", html: document)
            == ["A Title", "Fish & chips", "First line continues here.", "One", "Two", "lines", "Quoted"])
}

@Test func passagesSplitIntoSentences() {
    #expect(ArticleSpeech.sentences(in: "Dr. Smith arrived at 3.5 p.m. on Friday. Was it late? Not really — ")
            == ["Dr. Smith arrived at 3.5 p.m. on Friday.", "Was it late?", "Not really —"])
    #expect(ArticleSpeech.sentences(in: "A Title") == ["A Title"])
}

@Test func pluralInitialismsAreSpokenAsLetters() {
    #expect(ArticleSpeech.spoken("LLMs and APIs, unlike the LLM's GPUs.") == "LLM's and API's, unlike the LLM's GPU's.")
    #expect(ArticleSpeech.spoken("Pass BASICS, IDEAS and Is to MPs") == "Pass BASICS, IDEAS and Is to MP's")
}

@Test func symbolsInNamesAreSpokenAsWords() {
    #expect(ArticleSpeech.spoken("Node.js on news.ycombinator.com, llama.cpp in C++, C# and .NET.")
            == "Node JS on news dot ycombinator dot com, llama dot cpp in C plus plus, C sharp and dot net.")
    #expect(ArticleSpeech.spoken("io_uring in v1.2.3, CockroachDB and SolidJS, e.g. at 3.5 or 192.168.0.1.")
            == "io uring in version 1 dot 2 dot 3, Cockroach DB and Solid JS, e.g. at 3.5 or 192.168.0.1.")
}

@Test func numeronymsAreSaidInFull() {
    #expect(ArticleSpeech.spoken("K8s, a11y and i18n, not b2b or x86.") == "Kubernetes, accessibility and internationalization, not b2b or x86.")
}

@Test func pronunciationsLoad() {
    #expect(ArticleSpeech.pronunciations["JSON"] == "ʤˈAsᵊn")
}

@Test func leadImageIsTheFirstSavedImage() {
    #expect(ArticleHTML.firstImage(in: #"<p>Text</p><figure><IMG alt="a" src="image-2"></figure><img src="image-0">"#) == "image-2")
    #expect(ArticleHTML.firstImage(in: #"<img src="https://example.com/x.png"><img src="../etc/passwd">"#) == nil)
    #expect(ArticleHTML.firstImage(in: "<p>No images</p>") == nil)
}

@Test func searchMatchesBodiesByPrefixIgnoringAccents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func entry(_ title: String, body: String, version: String = "v1") throws -> SearchIndex.Entry {
        let file = root.appendingPathComponent(UUID().uuidString + ".html")
        try ArticleHTML.document(title: title, author: nil, domain: "example.com", minutes: 1, body: "<p>\(body)</p>")
            .write(to: file, atomically: true, encoding: .utf8)
        return SearchIndex.Entry(id: UUID(), version: version, title: title, author: nil, domain: "example.com", content: file)
    }
    let index = try SearchIndex(url: root.appendingPathComponent("Search.sqlite"))
    let reeds = try entry("Rivers", body: "The reeds bent along the riverbank at the café.")
    let reedTitle = try entry("Reeds of the marsh", body: "Nothing about it here.")
    let other = try entry("Mountains", body: "Granite and snow.")
    try await index.sync([reeds, reedTitle, other])

    let found = try await index.search("REED")
    #expect(found.map(\.id) == [reedTitle.id, reeds.id])
    #expect(found[0].snippet == nil)
    #expect(found[1].snippet?.contains("\(SearchIndex.highlightStart)reeds\(SearchIndex.highlightEnd)") == true)
    #expect(try await index.search("cafe river").map(\.id) == [reeds.id])
    #expect(try await index.search("\"unbalanced OR -").isEmpty)
    #expect(try await index.search("   ").isEmpty)

    try await index.sync([other])
    #expect(try await index.search("reed").isEmpty)
    let reopened = try SearchIndex(url: root.appendingPathComponent("Search.sqlite"))
    #expect(try await reopened.search("granite").map(\.id) == [other.id])
}

@Test func damagedSearchIndexIsRebuilt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Search.sqlite")
    try Data(repeating: 7, count: 4096).write(to: url)
    let index = try SearchIndex(url: url)
    try await index.index(SearchIndex.Entry(id: UUID(), version: nil, title: "Queued", author: nil, domain: "example.com", content: nil))
    #expect(try await index.search("example").count == 1)
}

@Test func hackerNewsStoriesLinkToTheirDiscussionWhenTheyHaveNoURL() throws {
    let link = try #require(try ExternalSource.hackerNewsItem(from: Data("""
    {"by":"dhouston","descendants":71,"id":8863,"score":104,"time":1175714200,"title":"My YC app","type":"story","url":"http://www.getdropbox.com/u/2/screencast.html"}
    """.utf8)))
    #expect(link.url.absoluteString == "http://www.getdropbox.com/u/2/screencast.html")
    #expect(link.domain == "getdropbox.com")
    #expect(link.points == 104 && link.comments == 71 && link.author == "dhouston")
    let ask = try #require(try ExternalSource.hackerNewsItem(from: Data(#"{"id":121003,"title":"Ask HN: Anything?","type":"story","text":"..."}"#.utf8)))
    #expect(ask.url.absoluteString == "https://news.ycombinator.com/item?id=121003")
    #expect(try ExternalSource.hackerNewsItem(from: Data(#"{"id":1,"dead":true,"title":"Gone"}"#.utf8)) == nil)
}

@Test func lobstersStoriesKeepTheirOrder() throws {
    let items = try ExternalSource.lobstersItems(from: Data("""
    [{"short_id":"qgd17n","created_at":"2026-10-01T03:47:50.120-05:00","title":"First","url":"https://www.oliverdunk.com/2026/09/30/iana-reply","score":99,"comment_count":38,"submitter_user":"videah","comments_url":"https://lobste.rs/s/qgd17n/first"},
     {"short_id":"abc123","created_at":"2026-10-01T01:00:00.000-05:00","title":"Text post","url":"","score":5,"comment_count":2,"submitter_user":"someone","comments_url":"https://lobste.rs/s/abc123/text_post"}]
    """.utf8))
    #expect(items.map(\.id) == ["qgd17n", "abc123"])
    #expect(items[0].domain == "oliverdunk.com")
    #expect(items[0].postedAt == Date(timeIntervalSince1970: 1_790_844_470.12))
    #expect(items[1].url.absoluteString == "https://lobste.rs/s/abc123/text_post")
}

@MainActor @Test func frontPagesAreKeptBetweenLaunches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let item = SourceItem(id: "1", title: "A story", url: URL(string: "https://example.com/a")!,
                          discussionURL: URL(string: "https://lobste.rs/s/1")!, author: nil, points: 3, comments: nil, postedAt: nil)
    let url = Library.frontPageURL(root: root, source: .lobsters)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(FrontPage(items: [item], fetchedAt: Date(timeIntervalSince1970: 100))).write(to: url)
    let library = try Library(root: root)
    #expect(library.frontPages[.lobsters]?.items == [item])
    #expect(library.frontPages[.lobsters]?.fetchedAt == Date(timeIntervalSince1970: 100))
    #expect(library.frontPages[.hackerNews] == nil)
}

@MainActor @Test func frontPageStoriesAreCachedOutsideTheLibraryUntilSaved() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func story(_ id: String) -> SourceItem {
        SourceItem(id: id, title: id, url: URL(string: "https://example.com/\(id)")!, discussionURL: nil,
                   author: nil, points: nil, comments: nil, postedAt: nil)
    }
    func writeFrontPage(_ items: [SourceItem]) throws {
        let url = Library.frontPageURL(root: root, source: .lobsters)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(FrontPage(items: items, fetchedAt: .now)).write(to: url)
    }
    try writeFrontPage([story("a"), story("b"), story("c")])
    let library = try Library(root: root)
    #expect(library.articles.isEmpty)
    #expect(library.cached.map(\.originalURL) == ["https://example.com/a", "https://example.com/b", "https://example.com/c"])
    let cached = try #require(library.cachedArticle(at: story("a").url))
    #expect(library.readable(at: story("a").url)?.id == cached.id)
    #expect(try library.add(story("a").url.absoluteString).id == cached.id)
    #expect(library.articles.map(\.id) == [cached.id])
    #expect(!cached.isCached)
    library.removeFromLibrary(cached)
    #expect(library.articles.isEmpty)
    #expect(library.cachedArticle(at: story("a").url)?.id == cached.id)
    library.keep(cached)

    try writeFrontPage([story("c"), story("d")])
    let reopened = try Library(root: root)
    #expect(reopened.articles.map(\.originalURL) == ["https://example.com/a"])
    #expect(reopened.cached.map(\.originalURL) == ["https://example.com/c", "https://example.com/d"])
}

