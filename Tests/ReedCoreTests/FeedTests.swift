import Foundation
import Testing
@testable import ReedCore

private let base = URL(string: "https://example.com/feed.xml")!

@Test func rssItemsKeepTheirLinksAuthorsAndDates() throws {
    let feed = try #require(FeedParser.parse(Data("""
    <?xml version="1.0"?>
    <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:atom="http://www.w3.org/2005/Atom">
    <channel>
      <title>Example &amp; Co</title>
      <link>https://example.com/</link>
      <atom:link href="https://example.com/feed.xml" rel="self" type="application/rss+xml"/>
      <item>
        <title>First post</title>
        <link>/posts/first</link>
        <guid isPermaLink="false">post-1</guid>
        <pubDate>Thu, 01 Oct 2026 09:30:00 +0000</pubDate>
        <dc:creator>Ada</dc:creator>
        <description><![CDATA[<p>Some <b>bold</b> words &amp; more.</p>]]></description>
      </item>
      <item>
        <link>https://example.com/posts/untitled</link>
        <pubDate>Tue, 30 Sep 2026 08:00:00 GMT</pubDate>
        <author>ada@example.com (Ada Lovelace)</author>
        <description>A note without a title</description>
      </item>
      <item><title>No link, no guid</title></item>
    </channel>
    </rss>
    """.utf8), from: base))
    #expect(feed.title == "Example & Co")
    #expect(feed.siteURL?.absoluteString == "https://example.com/")
    #expect(feed.entries.count == 2)
    #expect(feed.entries[0].url.absoluteString == "https://example.com/posts/first")
    #expect(feed.entries[0].id == "post-1")
    #expect(feed.entries[0].author == "Ada")
    #expect(feed.entries[0].excerpt == "Some bold words & more.")
    #expect(feed.entries[0].postedAt == Date(timeIntervalSince1970: 1_790_847_000))
    #expect(feed.entries[1].title == "A note without a title")
    #expect(feed.entries[1].author == "Ada Lovelace")
    #expect(feed.entries[1].postedAt == Date(timeIntervalSince1970: 1_790_755_200))
}

@Test func atomEntriesUseTheirAlternateLink() throws {
    let feed = try #require(FeedParser.parse(Data("""
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title type="html">A &lt;em&gt;blog&lt;/em&gt;</title>
      <link rel="self" href="https://example.com/atom.xml"/>
      <link href="https://example.com/"/>
      <author><name>Grace</name></author>
      <entry>
        <title>Hello</title>
        <id>tag:example.com,2026:1</id>
        <link rel="replies" href="https://example.com/hello#comments"/>
        <link rel="alternate" type="text/html" href="https://example.com/hello"/>
        <published>2026-10-01T09:30:00.250+02:00</published>
        <updated>2026-10-02T00:00:00Z</updated>
        <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Nested</p><p>markup</p></div></content>
      </entry>
      <entry>
        <title>Second</title>
        <id>https://example.com/second</id>
        <updated>2026-09-01T00:00:00Z</updated>
        <author><name>Someone Else</name></author>
      </entry>
    </feed>
    """.utf8), from: base))
    #expect(feed.title == "A blog")
    #expect(feed.siteURL?.absoluteString == "https://example.com/")
    #expect(feed.entries.map(\.url.absoluteString) == ["https://example.com/hello", "https://example.com/second"])
    #expect(feed.entries[0].author == "Grace")
    #expect(feed.entries[0].excerpt == "Nested markup")
    #expect(feed.entries[0].postedAt == Date(timeIntervalSince1970: 1_790_839_800.25))
    #expect(feed.entries[1].author == "Someone Else")
}

@Test func rdfAndJSONFeedsAreRead() throws {
    let rdf = try #require(FeedParser.parse(Data("""
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel><title>Old school</title><link>https://example.org/</link></channel>
      <item><title>One</title><link>https://example.org/1</link><dc:date>2026-10-01T00:00:00Z</dc:date></item>
    </rdf:RDF>
    """.utf8), from: base))
    #expect(rdf.title == "Old school")
    #expect(rdf.entries.first?.postedAt == Date(timeIntervalSince1970: 1_790_812_800))

    let json = try #require(FeedParser.parse(Data("""
    {"version":"https://jsonfeed.org/version/1.1","title":"JSON","home_page_url":"https://example.net/",
     "items":[{"id":"1","url":"https://example.net/1","title":"Item","date_published":"2026-10-01T00:00:00Z","authors":[{"name":"Lin"}],"content_html":"<p>Hi</p>"}]}
    """.utf8), from: base))
    #expect(json.title == "JSON")
    #expect(json.entries.first?.author == "Lin")
    #expect(json.entries.first?.excerpt == "Hi")

    #expect(FeedParser.parse(Data("<html><head><title>Not a feed</title></head></html>".utf8), from: base) == nil)
    #expect(FeedParser.parse(Data(#"{"name":"not a feed"}"#.utf8), from: base) == nil)
}

@Test func feedDatesAsWritten() {
    #expect(FeedParser.date("Thu, 1 Oct 2026 09:30:00 +0000") == Date(timeIntervalSince1970: 1_790_847_000))
    #expect(FeedParser.date("Thu, 01 Oct 2026 05:30:00 EDT") == Date(timeIntervalSince1970: 1_790_847_000))
    #expect(FeedParser.date("Mon, 01 Oct 2026 09:30:00 +0000") == Date(timeIntervalSince1970: 1_790_847_000))
    #expect(FeedParser.date("Mié, 01 Oct 2026 09:30 +0000") == Date(timeIntervalSince1970: 1_790_847_000))
    #expect(FeedParser.date("2026-10-01T09:30:00Z") == Date(timeIntervalSince1970: 1_790_847_000))
    #expect(FeedParser.date("2026-10-01") == Date(timeIntervalSince1970: 1_790_812_800))
    #expect(FeedParser.date("sometime soon") == nil)
}

@Test func pagesOfferTheirFeeds() {
    let found = FeedParser.discover(in: """
    <html><head>
      <link rel="stylesheet" href="/style.css">
      <link rel="alternate" type="application/rss+xml" title="Posts &amp; notes" href="/feed.xml">
      <link type='application/atom+xml' href='https://example.com/atom.xml' rel='alternate'>
      <link rel="alternate" type="application/rss+xml" href="/feed.xml">
      <link rel="alternate" hreflang="fr" href="/fr/">
    </head></html>
    """, base: URL(string: "https://example.com/blog/")!)
    #expect(found.map(\.url.absoluteString) == ["https://example.com/feed.xml", "https://example.com/atom.xml"])
    #expect(found[0].title == "Posts & notes")
    #expect(found[1].title == "example.com")
}

@Test func theRiverIsNewestFirstWithEachLinkOnce() {
    let parsed = { (urls: [(String, TimeInterval)]) in
        ParsedFeed(title: nil, siteURL: nil, entries: urls.map { .init(title: $0.0, url: URL(string: "https://example.com/" + $0.0)!, postedAt: Date(timeIntervalSince1970: $0.1)) })
    }
    let a = Feed(url: base, parsed: parsed([("a", 1), ("shared", 5)]), fetchedAt: .now, etag: nil, lastModified: nil)
    let b = Feed(url: base, parsed: parsed([("b", 3), ("shared", 4)]), fetchedAt: .now, etag: nil, lastModified: nil)
    let river = Library.river(of: [a, b])
    #expect(river.map(\.title) == ["shared", "b", "a"])
    #expect(river[0].feedID == a.id)
}

@MainActor @Test func subscriptionsRefreshAndSurviveRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubFeedServer.self]
    let library = try Library(root: root, downloader: ArticleDownloader(session: URLSession(configuration: configuration)))
    StubFeedServer.respond = { request in
        switch request.url?.path() {
        case "/":
            return (200, ["Content-Type": "text/html"], #"<link rel="alternate" type="application/atom+xml" href="/atom.xml">"#)
        case "/atom.xml":
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" { return (304, [:], "") }
            return (200, ["Content-Type": "application/atom+xml", "ETag": "\"v1\""], """
            <feed xmlns="http://www.w3.org/2005/Atom"><title>Stub</title>
            <entry><title>Only</title><link href="/only"/><updated>2026-10-01T00:00:00Z</updated></entry></feed>
            """)
        default:
            return (500, [:], "")
        }
    }
    defer { StubFeedServer.respond = nil }

    let candidates = try await library.findFeeds(at: "https://stub.test/")
    #expect(candidates.map(\.url.absoluteString) == ["https://stub.test/atom.xml"])
    let feed = try await library.subscribe(to: candidates[0].url)
    #expect(feed.title == "Stub")
    #expect(library.feedItems.map(\.url.absoluteString) == ["https://stub.test/only"])

    // Unchanged feeds keep their entries.
    await library.refreshFeeds()
    #expect(library.feeds[0].failure == nil)
    #expect(library.feedItems.count == 1)

    // A failing feed keeps its entries and says why.
    StubFeedServer.respond = { _ in (500, [:], "") }
    await library.refreshFeeds()
    #expect(library.feeds[0].failure != nil)
    #expect(library.feedItems.count == 1)

    #expect(library.visitFeeds() == nil)
    let reopened = try Library(root: root)
    #expect(reopened.feeds.map(\.title) == ["Stub"])
    #expect(reopened.feedItems.count == 1)
    #expect(reopened.feedsVisitedAt != nil)
    reopened.unsubscribe(reopened.feeds[0])
    #expect(try Library(root: root).feeds.isEmpty)

    await #expect(throws: ReedError.self) { try await library.findFeeds(at: "https://stub.test/missing") }
}

private final class StubFeedServer: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) -> (Int, [String: String], String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, body) = Self.respond?(request) ?? (500, [:], "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
