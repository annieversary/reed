import SwiftUI
import WebKit

/// Lets the reader's owner ask the page about narration.
@MainActor final class ReaderProxy {
    fileprivate weak var webView: WKWebView?

    /// The first passage at least partly on screen.
    func visiblePassage() async -> Int? {
        let value = try? await webView?.callAsyncJavaScript("return reedNarration.visible()", contentWorld: .defaultClient)
        return (value as? NSNumber)?.intValue
    }

    /// Scrolls back to the passage being read and keeps following it.
    func followNarration() {
        webView?.evaluateJavaScript("reedNarration.follow()", in: nil, in: .defaultClient) { _ in }
    }
}

/// Where the passage being read is, once you've scrolled away from it.
enum NarrationDirection: String {
    case up, down
}

@MainActor struct OfflineWebView {
    let url: URL
    let fontSize: Double
    let progress: Double
    /// The article's text as narration reads it, so passages can be found on the page.
    var passages: [String]?
    /// The passage being read aloud, if this article is being narrated.
    var narrating: Int?
    var proxy: ReaderProxy?
    var onProgress: (Double) -> Void
    var onAddLink: (URL) -> Void
    var onNarrateFrom: (Int) -> Void = { _ in }
    var onNarrationAway: (NarrationDirection?) -> Void = { _ in }

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
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "narrationJump")
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "narrationAway")
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
        proxy?.webView = webView
        return webView
    }

    @MainActor func update(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.parent = self
        guard coordinator.loaded else { return }
        coordinator.applyFont(webView)
        coordinator.applyPassages(webView)
        coordinator.applyNarration(webView)
    }

    /// Matches each passage read aloud to the element holding it, by text and in reading order. While narrating,
    /// the current one is tinted and kept in view; scrolling away stops that and reports which way it went.
    /// Tapping a paragraph asks to read from there.
    private static let narrationScript = #"""
    window.reedNarration = (() => {
        const blocks = 'p,h1,h2,h3,h4,h5,h6,li,dt,dd,blockquote,div,section,article,header,footer,aside,main';
        const squash = text => text.replace(/\s+/g, '');
        const style = document.createElement('style');
        style.textContent = `
            :root { --narrating: color-mix(in srgb, var(--accent) 9%, transparent); }
            @media (prefers-color-scheme: dark) { :root { --narrating: color-mix(in srgb, var(--accent) 15%, transparent); } }
            :where(${blocks}) { transition: background-color .5s, box-shadow .5s; }
            .reed-narrating { background-color: var(--narrating); box-shadow: 0 0 0 .4em var(--narrating); border-radius: .25em; }
            .reed-narration-active .reed-passage { cursor: pointer; }`;
        document.head.appendChild(style);
        const imagesLoaded = Promise.all(Array.from(document.images).map(img => img.complete ? null
            : new Promise(resolve => { img.addEventListener('load', resolve); img.addEventListener('error', resolve); })));

        let elements = [], firstPassage = new Map();
        let current = null, currentIndex = null, following = true, leftView = false, reportedAway = '';

        const locate = passages => {
            const all = Array.from(document.body.querySelectorAll(blocks));
            const texts = new Map(all.map(element => [element, squash(element.textContent)]));
            let cursor = 0;
            return passages.map(text => {
                const target = squash(text);
                const contains = element => texts.get(element).includes(target);
                let at = all.findIndex((element, index) => index >= cursor && contains(element));
                if (at < 0) at = all.findIndex(contains);
                if (at < 0) return null;
                let found = all[at];
                for (let child; (child = Array.from(found.children).find(c => texts.has(c) && contains(c)));) found = child;
                cursor = all.indexOf(found);
                return found;
            });
        };
        const inView = element => {
            const box = element.getBoundingClientRect();
            return box.bottom > 0 && box.top < innerHeight;
        };
        const scrollToCurrent = always => imagesLoaded.then(() => {
            if (!current) return;
            const box = current.getBoundingClientRect();
            if (!always && box.top >= 0 && box.bottom <= innerHeight * 0.75) return;
            window.scrollTo({top: scrollY + box.top - innerHeight * 0.2, behavior: 'smooth'});
        });
        // Tells the app whether the paragraph being read is above or below the screen, or '' when it's in view.
        const reportAway = () => {
            let away = '';
            if (!following && current && !inView(current)) {
                leftView = true;
                away = current.getBoundingClientRect().top < 0 ? 'up' : 'down';
            }
            if (away === reportedAway) return;
            reportedAway = away;
            window.webkit.messageHandlers.narrationAway.postMessage(away);
        };

        for (const type of ['wheel', 'touchmove', 'keydown']) {
            window.addEventListener(type, () => { if (currentIndex !== null) { following = false; leftView = false; } }, {passive: true});
        }
        window.addEventListener('scroll', () => {
            if (following || !current) return;
            // Scrolling back to the paragraph being read picks following up again.
            if (leftView && inView(current)) following = true;
            reportAway();
        }, {passive: true});
        document.addEventListener('click', event => {
            if (currentIndex === null || event.target.closest('a, button') || !getSelection().isCollapsed) return;
            for (let element = event.target; element; element = element.parentElement) {
                if (!firstPassage.has(element)) continue;
                const index = firstPassage.get(element);
                if (index !== currentIndex) window.webkit.messageHandlers.narrationJump.postMessage(index);
                return;
            }
        });

        return {
            setPassages(passages) {
                elements = locate(passages);
                firstPassage = new Map();
                elements.forEach((element, index) => {
                    if (!element || firstPassage.has(element)) return;
                    firstPassage.set(element, index);
                    element.classList.add('reed-passage');
                });
            },
            // The first passage at least partly on screen.
            visible() {
                const index = elements.findIndex(element => element && element.getBoundingClientRect().bottom > 4);
                return index < 0 ? null : index;
            },
            show(index) {
                document.documentElement.classList.add('reed-narration-active');
                currentIndex = index;
                const element = elements[index] ?? null;
                if (element !== current) {
                    current?.classList.remove('reed-narrating');
                    current = element;
                    current?.classList.add('reed-narrating');
                }
                if (following) scrollToCurrent(false);
                reportAway();
            },
            // Back to the paragraph being read, following it again.
            follow() {
                following = true;
                reportAway();
                scrollToCurrent(true);
            },
            clear() {
                document.documentElement.classList.remove('reed-narration-active');
                current?.classList.remove('reed-narrating');
                current = null;
                currentIndex = null;
                following = true;
                reportAway();
            },
        };
    })();
    """#

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: OfflineWebView
        var loaded = false
        var contextLink: URL?
        private var currentFontSize: Double?
        private var sentPassages: [String]?
        private var shownNarration: Int?
        init(parent: OfflineWebView) { self.parent = parent }

        func applyFont(_ webView: WKWebView) {
            guard currentFontSize != parent.fontSize else { return }
            currentFontSize = parent.fontSize
            webView.evaluateJavaScript("document.documentElement.style.setProperty('--font-size', '\(parent.fontSize)px')", in: nil, in: .defaultClient) { _ in }
        }

        func applyPassages(_ webView: WKWebView) {
            guard let passages = parent.passages, passages != sentPassages else { return }
            sentPassages = passages
            shownNarration = nil
            webView.callAsyncJavaScript("reedNarration.setPassages(passages)", arguments: ["passages": passages],
                                        in: nil, in: .defaultClient) { _ in }
        }

        func applyNarration(_ webView: WKWebView) {
            guard sentPassages != nil, shownNarration != parent.narrating else { return }
            shownNarration = parent.narrating
            if let index = parent.narrating {
                webView.callAsyncJavaScript("reedNarration.show(index)", arguments: ["index": index], in: nil, in: .defaultClient) { _ in }
            } else {
                webView.evaluateJavaScript("reedNarration.clear()", in: nil, in: .defaultClient) { _ in }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            applyFont(webView)
            applyPassages(webView)
            // While narrating, the reader follows the narration rather than returning to where it was left.
            guard parent.narrating == nil else { applyNarration(webView); return }
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
            if message.name == "narrationJump" {
                if let index = message.body as? Int { parent.onNarrateFrom(index) }
                return
            }
            if message.name == "narrationAway" {
                parent.onNarrationAway((message.body as? String).flatMap(NarrationDirection.init(rawValue:)))
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
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "narrationJump", contentWorld: .defaultClient)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "narrationAway", contentWorld: .defaultClient)
        nsView.navigationDelegate = nil
    }
}
#else
extension OfflineWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) { update(uiView, coordinator: context.coordinator) }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "readingProgress", contentWorld: .defaultClient)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "narrationJump", contentWorld: .defaultClient)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "narrationAway", contentWorld: .defaultClient)
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }
}
#endif
