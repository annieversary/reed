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
}

@MainActor
public final class ArticleExtractor: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    public override init() { super.init() }

    /// `fetch` loads the same-origin JSON a site rule asks for, such as a README rendered client-side.
    public func extract(html: String, url: URL, fetch: (URL) async throws -> String) async throws -> ExtractedArticle {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ReedExtractionNoNetwork",
            encodedContentRuleList: """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
            """
        )
        if let rules { configuration.userContentController.add(rules) }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        defer { timeout?.cancel(); view.stopLoading(); view.navigationDelegate = nil; webView = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.finishLoading(.failure(ReedError.extractionTimeout))
            }
            view.loadHTMLString("<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\"></head><body></body></html>", baseURL: nil)
        }
        try Task.checkCancellation()
        let script = try ["Readability", "purify.min", "temml.min", "MathMarkup", "SiteRules", "ExtractArticle"].map { try resource($0, extension: "js") }.joined(separator: "\n")
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

    private struct Needs: Decodable { let needs: [String] }

    /// Labels each formula with how to read it aloud. It's a step of its own, with its own time limit, since a
    /// formula-heavy paper takes a few seconds; the article is kept as it was if it fails.
    private func wordFormulas(in html: String, view: WKWebView) async -> String {
        do {
            let script = try ["SpeechRuleEngine", "MathSpeech"].map { try resource($0, extension: "js") }.joined(separator: "\n")
            let maps = ["en": try resource("SpeechRuleEngine-en", extension: "json"), "base": try resource("SpeechRuleEngine-base", extension: "json")]
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

    private func resource(_ name: String, extension ext: String) throws -> String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        timeout?.cancel()
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume(with: result)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading(.success(())) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading(.failure(error)) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoading(.failure(error)) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finishLoading(.failure(ReedError.extractionTimeout)) }
}
