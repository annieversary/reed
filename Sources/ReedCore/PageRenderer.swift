import Foundation
import WebKit

/// Runs a page's own scripts in a throwaway browser and returns the document they build, for pages that
/// arrive as an empty shell and fill in their article on load. Nothing is stored between pages, and images,
/// media and other windows aren't loaded.
@MainActor
public final class PageRenderer: NSObject, WKNavigationDelegate {
    private var loaded = false
    private var failure: Error?

    public override init() { super.init() }

    public func html(at url: URL) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ReedRenderingNoMedia",
            encodedContentRuleList: """
            [{"trigger":{"url-filter":".*","resource-type":["image","media","font","popup","ping"]},"action":{"type":"block"}}]
            """
        )
        if let rules { configuration.userContentController.add(rules) }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        view.customUserAgent = ArticleDownloader.userAgent
        view.navigationDelegate = self
        loaded = false
        failure = nil
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.load(URLRequest(url: url))
        // Done once the text has stopped growing for a second, or at the deadline with whatever is there.
        let deadline = ContinuousClock.now + .seconds(20)
        var length = -1
        var steady = 0
        while ContinuousClock.now < deadline && steady < 2 {
            try await Task.sleep(for: .milliseconds(500))
            if let failure { throw failure }
            guard loaded else { continue }
            let current = (try? await view.evaluateJavaScript("document.body ? document.body.innerText.length : 0")) as? Int ?? 0
            steady = current > 0 && current == length ? steady + 1 : 0
            length = current
        }
        guard let html = try await view.evaluateJavaScript("document.documentElement.outerHTML") as? String else {
            throw ReedError.emptyArticle
        }
        return html
    }

    // Only the page itself loads: no frames, new windows, or navigating elsewhere once it has loaded.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !loaded, navigationAction.targetFrame?.isMainFrame == true,
              let scheme = navigationAction.request.url?.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return .cancel }
        return .allow
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if !loaded { failure = error } }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if !loaded { failure = error } }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = ReedError.extractionTimeout }
}
