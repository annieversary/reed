import Foundation
import ImageIO
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

@Test @MainActor func sharedLinksAreAddedOnceInTheOrderShared() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = ShareInbox(directory: root.appendingPathComponent("Inbox"))
    for link in ["https://reed.invalid/first", "https://reed.invalid/second", "https://reed.invalid/first"] {
        try inbox.deposit(URL(string: link)!)
    }
    // Written by hand, since `deposit` only takes URLs.
    try Data("not a url".utf8).write(to: inbox.directory.appendingPathComponent("9999999999999-bad.link"))
    let library = try Library(root: root.appendingPathComponent("Library"))
    await library.addShared(from: inbox)
    #expect(library.errorMessage == nil)
    #expect(library.articles.map(\.originalURL) == ["https://reed.invalid/second", "https://reed.invalid/first"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path).isEmpty)
    await library.idle()
}

@Test @MainActor func inboxKeepsLinksThatFailToSave() async throws {
    let inbox = ShareInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    try inbox.deposit(URL(string: "https://example.com/a")!)
    await #expect(throws: CocoaError.self) { try await inbox.drain { _ in throw CocoaError(.fileWriteOutOfSpace) } }
    var saved: [ShareInbox.Item] = []
    try await inbox.drain { saved.append($0) }
    #expect(saved == [.link("https://example.com/a")])
}

@Test @MainActor func inboxCarriesOnPastAnItemThatFails() async throws {
    let inbox = ShareInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    try inbox.deposit(URL(string: "https://example.com/a")!)
    try inbox.deposit(URL(string: "https://example.com/b")!)
    var saved: [ShareInbox.Item] = []
    let fail: (ShareInbox.Item) throws -> Void = { item in
        if item == .link("https://example.com/a") { throw CocoaError(.fileReadCorruptFile) }
        saved.append(item)
    }
    await #expect(throws: CocoaError.self) { try await inbox.drain(fail) }
    #expect(saved == [.link("https://example.com/b")])
    // Given up on, it's set aside rather than tried again.
    await #expect(throws: CocoaError.self) { try await inbox.drain(giveUp: { _ in true }, fail) }
    try await inbox.drain { saved.append($0) }
    #expect(saved == [.link("https://example.com/b")])
    #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.directory.appendingPathComponent("Failed").path).count == 1)
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

@Test func narrationReadsBlocksButSkipsCodeAndCaptions() {
    let document = ArticleHTML.document(title: "Ignored <title>", author: "Byline", domain: "example.com", minutes: 4, body: """
        <h2>Fish &amp; chips</h2><p>First line
        continues here.</p><figure><img src="image-0"><figcaption>A caption</figcaption></figure>
        <pre><code>let x = 1</code></pre><ul><li>One</li><li>Two<br>lines</li></ul>
        <p><span class="missing-image">[Image unavailable: chart]</span></p><blockquote><p>Quoted</p></blockquote><p> — </p>
        """)
    #expect(ArticleSpeech.passages(title: "A Title", html: document)
            == ["A Title", "Fish & chips", "First line continues here.", "One", "Two", "lines", "Quoted"])
}

@Test func narrationReadsPicturesByTheirAltText() {
    let body = """
        <p>Before</p><figure><img src="image-0" alt="A red barn &amp; snow"><figcaption>Winter</figcaption></figure>
        <p>Look <img src="image-1" alt="a chart of sales"> here <img src="image-2" alt="😀"> now</p>
        <p><a href="x"><img src="image-4" alt="A map > a list"></a></p><p><img src="image-5" alt="Photo 3"><img src="image-6" alt="cover.JPG"></p>
        <div><img src="image-7" data-alt="ignored" alt="e^{i\\pi}"><br>Caption-like text</div>
        <figure class="equation"><img src="image-3" alt="x^2"></figure><p>After</p>
        """
    #expect(ArticleSpeech.passages(title: "T", html: "<main>\(body)</main>")
            == ["T", "Before", "Image: A red barn & snow", "Look here now", "Image: A map > a list", "Caption-like text", "After"])
}

@Test func narrationResumesAtThePassageItReached() {
    let passages = ["T", "Image: A barn", "First", "Second", "First"]
    #expect(ArticleNotes.passage(near: 2, anchor: "Second", in: passages) == 3)
    #expect(ArticleNotes.passage(near: 3, anchor: "First", in: passages) == 2)
    #expect(ArticleNotes.passage(near: 9, anchor: "Gone", in: passages) == 4)
    #expect(ArticleNotes.passage(near: 1, anchor: nil, in: passages) == 1)
}

@Test func describedPicturesGainAltTextOnlyWhereTheyHadNone() async {
    let html = #"<p><img src="image-0" alt=""><img alt="Kept" src="image-1"><img src="image-0"><img class="x" src="image-2"></p>"#
    let described = await ImageDescriptions.applying(["image-0": "A \"quoted\" cat", "image-1": "Replaced", "image-2": "Dog"], to: html)
    #expect(described == #"<p><img src="image-0" alt="A &quot;quoted&quot; cat"><img alt="Kept" src="image-1"><img alt="A &quot;quoted&quot; cat" src="image-0"><img alt="Dog" class="x" src="image-2"></p>"#)
}

@Test func onlyPicturesBigEnoughToMatterAreDescribed() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func png(_ name: String, side: Int) throws {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
    try png("image-0", side: 200)
    try png("image-1", side: 16)
    try png("image-2", side: 200)
    let html = #"<figure class="equation"><img src="image-2"></figure><img src="image-0"><img src="image-1"><img src="image-2" alt="Has one"><img src="image-3"><img src="image-0">"#
    #expect(await ImageDescriptions.undescribed(in: html, directory: directory, limit: 20) == ["image-0"])
    #expect(await ImageDescriptions.undescribed(in: html + #"<img src="image-2">"#, directory: directory, limit: 1) == ["image-0"])
    #expect(await ImageDescriptions.undescribed(in: #"<img title="a > b" src="image-2" alt="">"#, directory: directory, limit: 20) == ["image-2"])
}

@Test func refreshingKeepsDescriptionsOfTheSamePictures() async throws {
    let earlier = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for url in [earlier, directory] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    defer { for url in [earlier, directory] { try? FileManager.default.removeItem(at: url) } }
    try Data([1]).write(to: earlier.appendingPathComponent("image-0"))
    try Data([2]).write(to: earlier.appendingPathComponent("image-1"))
    try Data([2]).write(to: directory.appendingPathComponent("image-0"))
    try Data([3]).write(to: directory.appendingPathComponent("image-1"))
    let html = #"<img src="image-0" alt="A cat"><img src="image-1" alt="A dog &amp; bone">"#
    #expect(await ImageDescriptions.carried(["image-0", "image-1"], in: directory, from: (html, earlier)) == ["image-0": "A dog & bone"])
}

@Test func passagesSplitIntoSentences() {
    #expect(ArticleSpeech.sentences(in: "Dr. Smith arrived at 3.5 p.m. on Friday. Was it late? Not really — ")
            == ["Dr. Smith arrived at 3.5 p.m. on Friday.", "Was it late?", "Not really —"])
    #expect(ArticleSpeech.sentences(in: "A Title") == ["A Title"])
}

@Test func notesFollowTheirPassagesWhenAnArticleChanges() {
    let note = { (passage: Int, text: String) in ArticleNote(passage: passage, anchor: ArticleNotes.anchor(for: text), text: "On \(text)") }
    let notes = [note(1, "Second"), note(2, "Third"), note(3, "Gone")]
    #expect(ArticleNotes.placed(notes, in: ["Title", "Inserted", "Second", "Third"]).map { [String($0.passage), $0.text] }
            == [["2", "On Second"], ["3", "On Third\n\nOn Gone"]])
    // Repeated passages keep the note on the one nearest where it was.
    #expect(ArticleNotes.placed([note(3, "Same")], in: ["Same", "a", "b", "Same", "c"]).map(\.passage) == [3])
    #expect(ArticleNotes.placed(notes, in: []).isEmpty)
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

@Test func saintsAndDollarAmountsAreSaidInWords() {
    #expect(ArticleSpeech.spoken("St. Louis and St Paul, on Main St.") == "Saint Louis and Saint Paul, on Main St.")
    #expect(ArticleSpeech.spoken("Open on Main St. Tomorrow too.") == "Open on Main St. Tomorrow too.")
    #expect(ArticleSpeech.sentences(in: "We went to St. Louis. Then St. Paul's. Open on Main St. Tomorrow too.")
            == ["We went to St. Louis.", "Then St. Paul's.", "Open on Main St.", "Tomorrow too."])
    #expect(ArticleSpeech.spoken("$1M, $2.5bn, $40k and $3 billion, not $5 or a $5 t-shirt.")
            == "1 million dollars, 2.5 billion dollars, 40 thousand dollars and 3 billion dollars, not $5 or a $5 t-shirt.")
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

@Test func substackFeedKeepsPostsAndThoseSharedInNotes() throws {
    let page = try ExternalSource.substackPage(from: Data("""
    {"items":[
     {"type":"post","context":{"type":"post_restack","users":[{"name":"Maia Mindel"}]},"publication":{"name":"The New Critic"},
      "post":{"id":1,"title":"Safe at SlutCon","subtitle":"A subtitle","canonical_url":"https://www.thenewcritic.com/p/safe-at-slutcon",
              "post_date":"2026-10-01T12:00:00.000Z","audience":"everyone","wordcount":3161,"reaction_count":373,"comment_count":78,
              "publishedBylines":[{"name":"overlocked"}]}},
     {"type":"comment","context":{"type":"note","users":[{"name":"Jack Lewars"}]},"post":null,
      "comment":{"name":"Jack Lewars","body":"Changed my mind. ","attachments":[{"type":"image"},
        {"type":"post","publication":{"name":"Works in Progress"},
         "post":{"id":2,"title":"Just bury your trash","canonical_url":"https://www.worksinprogress.news/p/just-bury-your-trash",
                 "publishedBylines":[{"name":"Alex Chalmers"},{"name":"Works in Progress"}]}}]}},
     {"type":"post","context":{"type":"from_archives"},"publication":{"name":"Astral Codex Ten"},
      "post":{"id":3,"title":"Why Does Ozempic Cure All Diseases?","subtitle":"...","canonical_url":"https://www.astralcodexten.com/p/ozempic",
              "audience":"only_paid","publishedBylines":[{"name":"Scott Alexander"}]}},
     {"type":"comment","context":{"type":"note"},"comment":{"name":"Someone","body":"Just a note","attachments":[]}},
     {"type":"chat","context":{"type":"chat_recommended"}},
     {"type":"post","post":{"id":"not a number"}}
    ],"nextCursor":"abc+/="}
    """.utf8))
    #expect(page.nextCursor == "abc+/=")
    #expect(page.items.map(\.id) == ["1", "2", "3"])
    let restack = page.items[0]
    #expect(restack.site == "The New Critic" && restack.author == "overlocked" && restack.excerpt == "A subtitle")
    #expect(restack.reason == .restacked(by: "Maia Mindel") && restack.paid == nil && restack.wordCount == 3161)
    #expect(restack.points == 373 && restack.comments == 78)
    #expect(restack.discussionURL?.absoluteString == "https://www.thenewcritic.com/p/safe-at-slutcon/comments")
    #expect(restack.postedAt == Date(timeIntervalSince1970: 1_790_856_000))
    let shared = page.items[1]
    #expect(shared.reason == .note(author: "Jack Lewars", text: "Changed my mind."))
    #expect(shared.author == "Alex Chalmers" && shared.site == "Works in Progress")
    let archived = page.items[2]
    #expect(archived.reason == .fromArchives && archived.paid == true && archived.excerpt == nil)
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


@Test func seriesTitlesGivePartNumbersAndAName() {
    #expect(SeriesTitle.partNumber(in: "Making our own executable packer (Part 12)") == 12)
    #expect(SeriesTitle.partNumber(in: "Rust ownership, pt. 3: borrowing") == 3)
    #expect(SeriesTitle.partNumber(in: "The compiler, part IV") == 4)
    #expect(SeriesTitle.partNumber(in: "Part two: the parser") == 2)
    #expect(SeriesTitle.partNumber(in: "Notes on lenses (3/7)") == 3)
    #expect(SeriesTitle.partNumber(in: "Weeknotes #41") == 41)
    #expect(SeriesTitle.partNumber(in: "Part of the plan") == nil)
    #expect(SeriesTitle.partNumber(in: "Why 2024 was strange") == nil)
    #expect(SeriesTitle.name(for: ["Writing a GC, part 1: marking", "Writing a GC, part 2: sweeping"]) == "Writing a GC")
    #expect(SeriesTitle.name(for: ["Scanning — Crafting Interpreters", "Parsing — Crafting Interpreters"]) == "Crafting Interpreters")
    #expect(SeriesTitle.name(for: ["Lenses (Part 1)"]) == "Lenses")
    #expect(SeriesTitle.name(for: ["Apples", "Oranges"]) == "")
}

@Test @MainActor func seriesKeepTheirPartsInOrderAcrossLaunches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try ArticleStorage(root: root)
    do {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store")))
        for (index, title) in ["Packer, part 3", "Packer, part 1", "Packer, part 4", "Unrelated"].enumerated() {
            let article = Article(url: URL(string: "https://example.com/\(index)")!)
            article.title = title
            // Failed, so the library doesn't try to download them.
            article.state = .failed
            container.mainContext.insert(article)
        }
        try container.mainContext.save()
    }
    let library = try Library(root: root)
    func titled(_ title: String) -> Article { library.articles.first { $0.title == title }! }
    let series = try #require(library.makeSeries(named: "Packer", of: [titled("Packer, part 3"), titled("Packer, part 1")]))
    library.add(titled("Packer, part 4"), to: series)
    #expect(library.parts(of: series).map(\.title) == ["Packer, part 1", "Packer, part 3", "Packer, part 4"])
    library.moveParts(of: series, from: [2], to: 0)
    library.rename(series, to: "Executable packer")
    library.delete(titled("Packer, part 3"))
    let reopened = try Library(root: root)
    #expect(reopened.series.map(\.name) == ["Executable packer"])
    #expect(reopened.parts(of: reopened.series[0]).map(\.title) == ["Packer, part 4", "Packer, part 1"])
    reopened.removeFromLibrary(reopened.articles.first { $0.title == "Packer, part 4" }!)
    reopened.removeFromSeries(reopened.articles.first { $0.title == "Packer, part 1" }!)
    #expect(reopened.series.isEmpty)
}

@Test func hackerNewsDiscussionsKeepHNsRankingAndDropEmptyDeletions() throws {
    let url = try #require(URL(string: "https://news.ycombinator.com/item?id=8863"))
    #expect(DiscussionSite(url: url) == .hackerNews(id: 8863))
    let thread = Data("""
    {"id":8863,"author":"dhouston","points":104,"text":null,"children":[
     {"id":1,"author":"early","created_at_i":1175714575,"text":"First posted","children":[]},
     {"id":2,"author":null,"text":null,"children":[
       {"id":3,"author":"reply","created_at_i":1175714600,"text":"One<p>Two","children":[]}]},
     {"id":4,"author":null,"text":null,"children":[]},
     {"id":5,"author":"best","created_at_i":1175714700,"text":"Ranked first","children":[]}]}
    """.utf8)
    let discussion = try DiscussionSite.hackerNewsDiscussion(from: thread, ranking: Data(#"{"kids":[5,2,1]}"#.utf8), url: url)
    #expect(discussion.comments.map(\.id) == ["5", "2", "1"])
    #expect(discussion.count == 4)
    #expect(discussion.comments[1].author == nil && discussion.comments[1].replies.map(\.html) == ["<p>One<p>Two"])
    #expect(try DiscussionSite.hackerNewsDiscussion(from: thread, ranking: nil, url: url).comments.map(\.id) == ["1", "2", "5"])
    let html = discussion.html(site: .hackerNews(id: 8863), title: "My <YC> app")
    #expect(html.contains("My &lt;YC&gt; app") && html.contains("104 points · 4 comments") && html.contains("<i>deleted</i>"))
}

@Test func discussionSitesAreKnownByTheirThreadLinks() {
    #expect(DiscussionSite(url: URL(string: "https://lobste.rs/s/2svplr/gleam_doesn_t_compile")!) == .lobsters(id: "2svplr"))
    #expect(DiscussionSite(url: URL(string: "https://www.astralcodexten.com/p/open-thread-454/comments")!) == .substack(host: "www.astralcodexten.com", slug: "open-thread-454"))
    #expect(DiscussionSite(url: URL(string: "https://example.com/p/a-post")!) == nil)
    #expect(DiscussionSite.substack(host: "a.substack.com", slug: "b").url.absoluteString == "https://a.substack.com/p/b/comments")
}

@Test func lobstersThreadsAreRebuiltFromTheirDepths() throws {
    let url = URL(string: "https://lobste.rs/s/abc")!
    let discussion = try DiscussionSite.lobstersDiscussion(from: Data("""
    {"score":38,"comments":[
     {"short_id":"a","depth":0,"comment":"<p>Top</p>","commenting_user":"one","created_at":"2026-10-05T14:19:31.042-05:00"},
     {"short_id":"b","depth":1,"comment":"<p>Reply</p>","commenting_user":"two"},
     {"short_id":"c","depth":2,"comment":"<p>Deeper</p>","commenting_user":"three"},
     {"short_id":"d","depth":1,"comment":"","is_deleted":true,"commenting_user":"four"},
     {"short_id":"e","depth":0,"comment":"","is_moderated":true,"commenting_user":"five"},
     {"short_id":"f","depth":1,"comment":"<p>Kept</p>","commenting_user":"six"},
     {"short_id":"g","depth":0,"comment":"<p>Last</p>","commenting_user":"seven"}]}
    """.utf8), url: url)
    #expect(discussion.comments.map(\.id) == ["a", "e", "g"])
    #expect(discussion.comments[0].replies.map(\.id) == ["b"] && discussion.comments[0].replies[0].replies.map(\.id) == ["c"])
    #expect(discussion.comments[1].author == nil && discussion.comments[1].replies.map(\.html) == ["<p>Kept</p>"])
    #expect(discussion.count == 6 && discussion.points == 38)
}

@Test func substackCommentsBecomeParagraphsWithLinks() throws {
    let discussion = try DiscussionSite.substackDiscussion(from: Data("""
    {"comments":[
     {"id":1,"name":"Ann","body":"See https://example.com/a?b=1&c=2.\\n\\nSecond <line>\\nthird","date":"2026-10-05T15:45:48.408Z","children":[
       {"id":2,"name":"Bo","body":null,"deleted":true,"children":[]}]},
     {"id":3,"name":null,"body":null,"deleted":true,"children":[{"id":4,"name":"Cy","body":"Hi","children":[]}]}]}
    """.utf8), points: 12, url: URL(string: "https://a.substack.com/p/b/comments")!)
    #expect(discussion.comments.map(\.id) == ["1", "3"] && discussion.comments[0].replies.isEmpty)
    #expect(discussion.comments[0].html == #"<p>See <a href="https://example.com/a?b=1&amp;c=2">https://example.com/a?b=1&amp;c=2</a>.</p><p>Second &lt;line&gt;<br>third</p>"#)
    #expect(discussion.comments[1].author == nil && discussion.count == 3)
    #expect(discussion.html(site: .substack(host: "a.substack.com", slug: "b"), title: "T").contains("12 likes · 3 comments"))
}

@Test func discussionLookupsPickTheMostDiscussedExactMatch() throws {
    let article = URL(string: "https://www.example.com/post/")!
    let hits = Data("""
    {"hits":[{"objectID":"1","url":"https://example.com/post","num_comments":5},
             {"objectID":"2","url":"http://example.com/post","num_comments":40},
             {"objectID":"3","url":"https://example.com/post/more","num_comments":900},
             {"objectID":"4","url":"https://example.com/post","num_comments":0}]}
    """.utf8)
    #expect(try DiscussionSite.hackerNewsMatch(for: article, in: hits) == .hackerNews(id: 2))
    #expect(try DiscussionSite.hackerNewsMatch(for: article, in: Data(#"{"hits":[]}"#.utf8)) == nil)
    #expect(try DiscussionSite.lobstersMatch(in: Data(#"[{"short_id":"x","comment_count":0},{"short_id":"y","comment_count":3}]"#.utf8)) == .lobsters(id: "y"))
    #expect(try DiscussionSite.lobstersMatch(in: Data("[]".utf8)) == nil)
}

@Test func missingImagesBecomePlaceholdersKeepingTheirAltText() async {
    let images = [ExtractedArticle.Image(url: "https://example.com/a.png", filename: "image-0.png", alt: "A <b> & \"c\""),
                  ExtractedArticle.Image(url: "https://example.com/b.png", filename: "image-1.png", alt: "")]
    let html = #"<p><img alt="x" src="image-0.png"> and <img src="image-1.png" class="wide"> and <img src="image-2.png" alt="kept"></p>"#
    #expect(await Library.replacing(images, in: html) == """
        <p><span class="missing-image">[Image unavailable: A &lt;b&gt; &amp; &quot;c&quot;]</span> and \
        <span class="missing-image">[Image unavailable]</span> and <img src="image-2.png" alt="kept"></p>
        """)
    #expect(await Library.replacing([], in: html) == html)
}
