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
        guard let html = try await view.evaluateJavaScript(Self.snapshot) as? String else {
            throw ReedError.emptyArticle
        }
        return html
    }

    /// The document, with drawings given their size on the page and the colours and type their stylesheets set,
    /// since extraction keeps neither stylesheets nor classes. Only what differs from what an element would
    /// inherit is written.
    private static let snapshot = """
    const inherited = ["fill", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "stroke-dasharray",
                       "font-size", "font-family", "font-weight", "text-anchor"];
    const initial = { "opacity": "1", "stop-color": "rgb(0, 0, 0)", "stop-opacity": "1" };
    for (const node of document.querySelectorAll("svg, svg *")) {
        const style = getComputedStyle(node);
        const parent = node.localName === "svg" && !node.parentElement?.closest("svg") ? null : getComputedStyle(node.parentElement);
        for (const property of inherited) {
            const value = style.getPropertyValue(property);
            if (parent && value === parent.getPropertyValue(property)) node.removeAttribute(property);
            else node.setAttribute(property, value);
        }
        for (const [property, value] of Object.entries(initial)) {
            const current = style.getPropertyValue(property);
            if (current === value) node.removeAttribute(property);
            else node.setAttribute(property, current);
        }
    }
    // Drawings sized by the page's layout keep that size, instead of filling the reader's column.
    for (const svg of document.querySelectorAll("svg:not([width])")) {
        const width = Math.round(svg.getBoundingClientRect().width);
        if (width > 0 && !svg.parentElement?.closest("svg")) svg.setAttribute("width", width);
    }
    // Items set apart by the layout, like a chart's key, would otherwise run together.
    for (const node of document.body.querySelectorAll("*")) {
        if (!/flex|grid/.test(getComputedStyle(node).display)) continue;
        for (const child of Array.from(node.children).slice(1)) {
            if (!/\\s$/.test(child.previousSibling?.textContent ?? " ")) child.before(" ");
        }
    }
    document.documentElement.outerHTML
    """

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
