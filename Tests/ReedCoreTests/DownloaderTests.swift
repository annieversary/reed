import Foundation
import Synchronization
import Testing
@testable import ReedCore

@Test func pagesAreReadInTheEncodingTheyName() throws {
    let japanese = "<p>吾輩は猫である</p>"
    let shiftJIS = try #require(japanese.data(using: .shiftJIS))
    #expect(ArticleDownloader.text(of: shiftJIS, declared: "Shift_JIS") == japanese)

    let page = #"<html><head><meta charset="euc-kr"><title>"# + "한국어</title></head></html>"
    let eucKR = try #require(page.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))))
    #expect(ArticleDownloader.metaCharset(in: eucKR) == "euc-kr")
    #expect(ArticleDownloader.text(of: eucKR, declared: nil) == page)

    let older = Data(#"<meta http-equiv="Content-Type" content="text/html; charset=windows-1251">"#.utf8)
    #expect(ArticleDownloader.metaCharset(in: older) == "windows-1251")
    #expect(ArticleDownloader.metaCharset(in: Data(#"<meta charset="utf-16">"#.utf8)) == "utf-8")

    // Pages labelled Latin-1 use Windows-1252's quotes, as browsers assume.
    #expect(ArticleDownloader.text(of: Data([0x93, 0x68, 0x69, 0x94]), declared: "iso-8859-1") == "\u{201C}hi\u{201D}")
    #expect(ArticleDownloader.text(of: Data("plain".utf8), declared: "no-such-charset") == "plain")
}

@Test func searchesFindTheBestMatchesUpToTheLimit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let index = try SearchIndex(url: root.appendingPathComponent("Search.sqlite"))
    let best = UUID()
    try await index.sync([SearchIndex.Entry(id: best, version: "1", title: "Otters otters otters", author: nil, domain: "example.com", content: nil)]
        + (0..<SearchIndex.matchLimit + 20).map { SearchIndex.Entry(id: UUID(), version: "1", title: "Otter \($0)", author: nil, domain: "example.com", content: nil) })
    let found = try await index.search("otter")
    #expect(found.count == SearchIndex.matchLimit)
    #expect(found.first?.id == best)

    let cancelled = Task { try await index.search("otter") }
    cancelled.cancel()
    #expect(try await cancelled.value.isEmpty)
}

@Test func feedsAreFetchedAFewAtATime() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CountingFeedServer.self]
    let downloader = ArticleDownloader(session: URLSession(configuration: configuration))
    let requests = (0..<20).map { Library.FeedRequest(id: UUID(), url: URL(string: "https://feeds.test/\($0).xml")!, etag: nil, lastModified: nil) }
    let results = await Library.fetch(requests, using: downloader)
    #expect(results.count == 20)
    #expect(CountingFeedServer.load.withLock { $0.most } <= Library.feedFetches)
}

private final class CountingFeedServer: URLProtocol {
    static let load = Mutex((now: 0, most: 0))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.load.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [self] in
            Self.load.withLock { $0.now -= 1 }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/atom+xml"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"<feed xmlns="http://www.w3.org/2005/Atom"><title>F</title></feed>"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
