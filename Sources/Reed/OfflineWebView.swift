import SwiftUI
import WebKit

@MainActor struct OfflineWebView {
    let url: URL
    let fontSize: Double
    let progress: Double
    var onProgress: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "readingProgress")
        let script = WKUserScript(source: """
        // Throttled rather than debounced, so progress keeps updating during one long scroll.
        let lastReport = 0, trailing;
        const report = () => {
            lastReport = Date.now();
            const distance = document.documentElement.scrollHeight - window.innerHeight;
            if (distance > 0) window.webkit.messageHandlers.readingProgress.postMessage(window.scrollY / distance);
        };
        window.addEventListener('scroll', () => {
            clearTimeout(trailing);
            if (Date.now() - lastReport >= 150) report();
            else trailing = setTimeout(report, 150);
        }, {passive:true});
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        configuration.userContentController.addUserScript(script)
        // Articles saved with an older template carry their own dark background.
        let darkPaper = WKUserScript(source: """
        const style = document.createElement('style');
        style.textContent = '@media(prefers-color-scheme:dark){:root{--paper:#000}}';
        document.head.appendChild(style);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        configuration.userContentController.addUserScript(darkPaper)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    @MainActor func update(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.parent = self
        guard coordinator.loaded else { return }
        coordinator.applyFont(webView)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: OfflineWebView
        var loaded = false
        private var currentFontSize: Double?
        init(parent: OfflineWebView) { self.parent = parent }

        func applyFont(_ webView: WKWebView) {
            guard currentFontSize != parent.fontSize else { return }
            currentFontSize = parent.fontSize
            webView.evaluateJavaScript("document.documentElement.style.setProperty('--font-size', '\(parent.fontSize)px')", in: nil, in: .defaultClient) { _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            applyFont(webView)
            let fraction = min(max(parent.progress, 0), 1)
            webView.evaluateJavaScript("""
            const restore = () => window.scrollTo(0, \(fraction) * Math.max(0, document.documentElement.scrollHeight - window.innerHeight));
            Promise.all(Array.from(document.images).map(img => img.complete ? Promise.resolve() : new Promise(resolve => { img.onload = resolve; img.onerror = resolve; }))).then(restore);
            """, in: nil, in: .defaultClient) { _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard loaded, let number = message.body as? Double else { return }
            parent.onProgress(number)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated {
                if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    _ = await UIApplication.shared.open(url)
                    #endif
                }
                return .cancel
            } else {
                return url.isFileURL && url.deletingLastPathComponent().standardizedFileURL == parent.url.deletingLastPathComponent().standardizedFileURL ? .allow : .cancel
            }
        }
    }
}

#if os(macOS)
extension OfflineWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) { update(nsView, coordinator: context.coordinator) }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "readingProgress", contentWorld: .defaultClient)
        nsView.navigationDelegate = nil
    }
}
#else
extension OfflineWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) { update(uiView, coordinator: context.coordinator) }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "readingProgress", contentWorld: .defaultClient)
        uiView.navigationDelegate = nil
    }
}
#endif
