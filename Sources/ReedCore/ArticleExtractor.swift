import Foundation
import WebKit

public struct ExtractedArticle: Codable, Sendable {
    public struct Image: Codable, Sendable {
        public let url: String
        public let filename: String
        public let alt: String
    }
    public let title: String
    public let author: String?
    /// Milliseconds since 1970, as JavaScript reports it.
    public let publishedAt: Double?
    public let excerpt: String
    public internal(set) var html: String
    public let wordCount: Int
    public let images: [Image]
    public let page: PageLinks
}

@MainActor
public final class ArticleExtractor {
    /// Blocks every network request, compiled once.
    private var rules: WKContentRuleList?
    /// A blank page kept between extractions while `keepingPage(during:)` runs.
    private var kept: BlankPage?
    private var keeping = 0

    public init() {}

    /// Runs `body` with one blank page shared by every extraction in it, as converting a whole book does,
    /// rather than bringing up a page for each.
    public func keepingPage<T>(during body: () async throws -> T) async rethrows -> T {
        keeping += 1
        defer {
            keeping -= 1
            if keeping == 0 { kept?.close(); kept = nil }
        }
        return try await body()
    }

    /// `fetch` loads the same-origin JSON a site rule asks for, such as a README rendered client-side.
    public func extract(html: String, url: URL, fetch: (URL) async throws -> String) async throws -> ExtractedArticle {
        try await withWebView { view in
            let script = try BundledResource.extractionScript()
            var resources: [String: String] = [:]
            for _ in 0..<3 {
                let data = Data(try await evaluate(script, arguments: ["html": html, "sourceURL": url.absoluteString, "resources": resources], in: view).utf8)
                guard let needs = try? JSONDecoder().decode(Needs.self, from: data).needs else {
                    var article = try JSONDecoder().decode(ExtractedArticle.self, from: data)
                    if article.html.contains("<math") { article.html = await wordFormulas(in: article.html, view: view) }
                    return article
                }
                for need in needs {
                    try Task.checkCancellation()
                    // A failed fetch leaves the rule to make do without it.
                    var body = ""
                    if let needURL = URL(string: need) { body = (try? await fetch(needURL)) ?? "" }
                    resources[need] = body
                }
            }
            throw ReedError.emptyArticle
        }
    }

    /// A book's chapter from its parts of XHTML files. `links` gives each file's chapter, and each element's where a file
    /// is shared, so links between chapters can point at their saved files. Its images' URLs are their paths in the archive.
    public func chapter(files: [(part: EPUB.Part, html: String)], title: String?, index: Int, links: [String: Int]) async throws -> ExtractedArticle {
        guard let first = files.first else { throw ReedError.unreadableBook }
        return try await withWebView { view in
            let script = try BundledResource.extractionScript()
            let parts = files.map { ["path": $0.part.path, "html": $0.html, "from": $0.part.from ?? NSNull(), "to": $0.part.to ?? NSNull()] as [String: Any] }
            let chapter: [String: Any] = ["files": parts, "title": title ?? NSNull(),
                                          "index": index, "links": links]
            let sourceURL = "epub:///" + (first.part.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? first.part.path)
            let json = try await evaluate(script, arguments: ["html": "", "sourceURL": sourceURL, "resources": [String: String](), "chapter": chapter], in: view)
            var article = try JSONDecoder().decode(ExtractedArticle.self, from: Data(json.utf8))
            if article.html.contains("<math") { article.html = await wordFormulas(in: article.html, view: view) }
            return article
        }
    }

    /// The page's title and links, without extracting its article.
    public func pageLinks(html: String, url: URL) async throws -> PageLinks {
        try await withWebView { view in
            let script = try BundledResource.text("PageLinks", extension: "js") + """

                return JSON.stringify(pageLinks(new DOMParser().parseFromString(html, "text/html"), sourceURL));
                """
            let json = try await evaluate(script, arguments: ["html": html, "sourceURL": url.absoluteString], in: view)
            return try JSONDecoder().decode(PageLinks.self, from: Data(json.utf8))
        }
    }

    /// Runs `body` with a blank page that can't reach the network, for scripts to work on documents in.
    private func withWebView<T>(_ body: (WKWebView) async throws -> T) async throws -> T {
        if let kept, !kept.isGone { return try await body(kept.view) }
        if rules == nil {
            let store = WKContentRuleListStore.default()!
            rules = await withCheckedContinuation { continuation in
                store.lookUpContentRuleList(forIdentifier: Self.rulesIdentifier) { list, _ in continuation.resume(returning: list) }
            }
            if rules == nil {
                rules = try await store.compileContentRuleList(forIdentifier: Self.rulesIdentifier, encodedContentRuleList: """
                    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
                    """)
            }
        }
        let page = BlankPage(rules: rules)
        try await page.load()
        try Task.checkCancellation()
        if keeping > 0 {
            kept?.close()
            kept = page
            return try await body(page.view)
        }
        defer { page.close() }
        return try await body(page.view)
    }

    private static let rulesIdentifier = "ReedExtractionNoNetwork"

    private struct Needs: Decodable { let needs: [String] }

    /// Labels each formula with how to read it aloud. It's a step of its own, with its own time limit, since a
    /// formula-heavy paper takes a few seconds; the article is kept as it was if it fails.
    private func wordFormulas(in html: String, view: WKWebView) async -> String {
        do {
            let script = try ["SpeechRuleEngine", "MathSpeech"].map { try BundledResource.text($0, extension: "js") }.joined(separator: "\n")
            let maps = ["en": try BundledResource.text("SpeechRuleEngine-en", extension: "json"), "base": try BundledResource.text("SpeechRuleEngine-base", extension: "json")]
            return try await evaluate(script, arguments: ["html": html, "mathMaps": maps], in: view)
        } catch {
            return html
        }
    }

    private func evaluate(_ script: String, arguments: [String: Any], in view: WKWebView) async throws -> String {
        // Bound JavaScript processing as well as page loading. Each invocation owns its callback,
        // so a late WebKit completion cannot accidentally finish a subsequent extraction.
        let evaluation = Evaluation()
        return try await withCheckedThrowingContinuation { continuation in
            evaluation.continuation = continuation
            evaluation.timer = Task {
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                evaluation.finish(.failure(ReedError.extractionTimeout))
            }
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    if let json = value as? String { evaluation.finish(.success(json)) }
                    else { evaluation.finish(.failure(ReedError.emptyArticle)) }
                case .failure(let error): evaluation.finish(.failure(error))
                }
            }
        }
    }

    @MainActor private final class Evaluation {
        var continuation: CheckedContinuation<String, Error>?
        var timer: Task<Void, Never>?
        func finish(_ result: Result<String, Error>) {
            timer?.cancel()
            timer = nil
            let callback = continuation
            continuation = nil
            callback?.resume(with: result)
        }
    }

}

/// An empty page whose loading is awaited, and which notices when its web content process goes.
@MainActor private final class BlankPage: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private(set) var isGone = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    init(rules: WKContentRuleList?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let rules { configuration.userContentController.add(rules) }
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }

    func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.finish(.failure(ReedError.extractionTimeout))
            }
            view.loadHTMLString("<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\"></head><body></body></html>", baseURL: nil)
        }
    }

    func close() {
        finish(.failure(CancellationError()))
        view.stopLoading()
        view.navigationDelegate = nil
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isGone = true
        finish(.failure(ReedError.extractionTimeout))
    }
}
