import SwiftUI
import WebKit

/// The passage being read aloud, so the reader can show and follow it.
struct NarratedPassage: Equatable {
    let index: Int
    let text: String
}

@MainActor struct OfflineWebView {
    let url: URL
    let fontSize: Double
    let progress: Double
    var narrated: NarratedPassage?
    var onProgress: (Double) -> Void
    var onAddLink: (URL) -> Void

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
        configuration.userContentController.addUserScript(WKUserScript(source: Self.narrationScript, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true, in: .defaultClient))
        #if os(macOS)
        // AppKit's menu hook doesn't say which link was clicked, so the page reports it first.
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "contextLink")
        let contextLink = WKUserScript(source: """
        document.addEventListener('contextmenu', event => {
            const link = event.target.closest && event.target.closest('a[href]');
            window.webkit.messageHandlers.contextLink.postMessage(link ? link.href : '');
        }, true);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        configuration.userContentController.addUserScript(contextLink)
        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        webView.coordinator = coordinator
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = coordinator
        #endif
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
        coordinator.applyNarration(webView)
    }

    /// Finds the element holding each narrated passage by its text, tints it, and scrolls it into view
    /// unless the reader has scrolled recently. Passages arrive in order, so the search resumes after the last match.
    private static let narrationScript = #"""
    window.reedNarration = (() => {
        const blocks = 'p,h1,h2,h3,h4,h5,h6,li,dt,dd,blockquote,div,section,article,header,footer,aside,main';
        const squash = text => text.replace(/\s+/g, '');
        const style = document.createElement('style');
        style.textContent = `
            :root { --narrating: color-mix(in srgb, var(--accent) 9%, transparent); }
            @media (prefers-color-scheme: dark) { :root { --narrating: color-mix(in srgb, var(--accent) 15%, transparent); } }
            :where(${blocks}) { transition: background-color .5s, box-shadow .5s; }
            .reed-narrating { background-color: var(--narrating); box-shadow: 0 0 0 .4em var(--narrating); border-radius: .25em; }`;
        document.head.appendChild(style);
        const imagesLoaded = Promise.all(Array.from(document.images).map(img => img.complete ? null
            : new Promise(resolve => { img.addEventListener('load', resolve); img.addEventListener('error', resolve); })));
        let lastInteraction = 0;
        for (const type of ['wheel', 'touchmove', 'keydown']) {
            window.addEventListener(type, () => { lastInteraction = Date.now(); }, {passive: true});
        }
        const located = new Map();
        let cursor = 0, current = null;
        const locate = (index, text) => {
            if (located.has(index)) return located.get(index);
            const target = squash(text);
            const all = Array.from(document.body.querySelectorAll(blocks));
            const contains = element => squash(element.textContent).includes(target);
            let found = all.slice(cursor).find(contains) ?? all.find(contains);
            if (!found) return null;
            for (let child; (child = Array.from(found.children).find(c => c.matches(blocks) && contains(c)));) found = child;
            cursor = all.indexOf(found);
            located.set(index, found);
            return found;
        };
        return {
            show(index, text) {
                const element = locate(index, text);
                if (element === current) return;
                current?.classList.remove('reed-narrating');
                current = element;
                if (!element) return;
                element.classList.add('reed-narrating');
                imagesLoaded.then(() => {
                    if (element !== current || Date.now() - lastInteraction < 8000) return;
                    const box = element.getBoundingClientRect();
                    if (box.top >= 0 && box.bottom <= innerHeight * 0.75) return;
                    window.scrollTo({top: scrollY + box.top - innerHeight * 0.2, behavior: 'smooth'});
                });
            },
            clear() {
                current?.classList.remove('reed-narrating');
                current = null;
            },
        };
    })();
    """#

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: OfflineWebView
        var loaded = false
        var contextLink: URL?
        private var currentFontSize: Double?
        private var shownNarration: NarratedPassage?
        init(parent: OfflineWebView) { self.parent = parent }

        func applyFont(_ webView: WKWebView) {
            guard currentFontSize != parent.fontSize else { return }
            currentFontSize = parent.fontSize
            webView.evaluateJavaScript("document.documentElement.style.setProperty('--font-size', '\(parent.fontSize)px')", in: nil, in: .defaultClient) { _ in }
        }

        func applyNarration(_ webView: WKWebView) {
            guard shownNarration != parent.narrated else { return }
            shownNarration = parent.narrated
            if let passage = parent.narrated {
                webView.callAsyncJavaScript("reedNarration.show(index, text)", arguments: ["index": passage.index, "text": passage.text],
                                            in: nil, in: .defaultClient) { _ in }
            } else {
                webView.evaluateJavaScript("reedNarration.clear()", in: nil, in: .defaultClient) { _ in }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            applyFont(webView)
            // While narrating, the reader follows the narration rather than returning to where it was left.
            guard parent.narrated == nil else { applyNarration(webView); return }
            let fraction = min(max(parent.progress, 0), 1)
            webView.evaluateJavaScript("""
            const restore = () => window.scrollTo(0, \(fraction) * Math.max(0, document.documentElement.scrollHeight - window.innerHeight));
            Promise.all(Array.from(document.images).map(img => img.complete ? Promise.resolve() : new Promise(resolve => { img.onload = resolve; img.onerror = resolve; }))).then(restore);
            """, in: nil, in: .defaultClient) { _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "contextLink" {
                contextLink = (message.body as? String).flatMap(URL.init(string:)).flatMap { Self.isWeb($0) ? $0 : nil }
                return
            }
            guard loaded, let number = message.body as? Double else { return }
            parent.onProgress(number)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated {
                if Self.isWeb(url) {
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

        static func isWeb(_ url: URL) -> Bool { ["https", "http"].contains(url.scheme?.lowercased() ?? "") }

        #if os(iOS)
        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
            guard let url = elementInfo.linkURL, Self.isWeb(url) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
                let add = UIAction(title: "Add to Reed", image: UIImage(systemName: "plus")) { _ in self?.parent.onAddLink(url) }
                return UIMenu(children: [add] + suggested)
            }
        }
        #endif
    }
}

#if os(macOS)
final class ReaderWebView: WKWebView {
    weak var coordinator: OfflineWebView.Coordinator?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let coordinator, let url = coordinator.contextLink else { return }
        let item = NSMenuItem(title: "Add to Reed", action: #selector(addLink(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func addLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        coordinator?.parent.onAddLink(url)
    }
}

extension OfflineWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) { update(nsView, coordinator: context.coordinator) }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "readingProgress", contentWorld: .defaultClient)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "contextLink", contentWorld: .defaultClient)
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
        uiView.uiDelegate = nil
    }
}
#endif
