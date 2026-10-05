import SwiftUI
import WebKit
#if SWIFT_PACKAGE
import ReedCore
#endif

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

/// The sentence being read aloud, and the passage it's in.
struct NarrationPosition: Equatable {
    var passage: Int
    var sentence: Int
}

/// A card at the end of the page, such as the way on to what's next in the list.
struct EndCard: Equatable {
    /// Sent back when the card is tapped.
    var id: String
    var kicker: String
    var source: String
    var title: String
    var detail: String
}

/// Where the passage being read is, once you've scrolled away from it.
enum NarrationDirection: String {
    case up, down
}

@MainActor struct OfflineWebView {
    let url: URL
    let fontSize: Double
    let progress: Double
    /// An element to open at, by ID, rather than where reading was left.
    var anchor: String?
    /// The article's text as narration reads it, sentence by sentence within each passage, so it can be found on the page.
    var passages: [[String]]?
    /// What's being read aloud, if this article is being narrated.
    var narrating: NarrationPosition?
    var proxy: ReaderProxy?
    /// The notes beside the article's passages, once loaded.
    var notes: [ArticleNote]?
    var notesOpen = false
    var cards: [EndCard] = []
    var onProgress: (Double) -> Void
    var onAddLink: (URL) -> Void
    var onNarrateFrom: (Int) -> Void = { _ in }
    var onNarrationAway: (NarrationDirection?) -> Void = { _ in }
    var onNotesOpen: (Bool) -> Void = { _ in }
    var onNoteChange: (Int, String) -> Void = { _, _ in }
    /// Another saved document beside this one, such as a book's next chapter, by file name and element ID.
    var onOpenSibling: (String, String?) -> Void = { _, _ in }
    var onOpenCard: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "readingProgress")
        configuration.userContentController.addUserScript(Self.userScript(Self.script("ReaderProgress")))
        // Articles saved with an older template carry their own background.
        configuration.userContentController.addUserScript(Self.userScript("""
        const style = document.createElement('style');
        style.textContent = ':root{--paper:#fff}@media(prefers-color-scheme:dark){:root{--paper:#000}}';
        document.head.appendChild(style);
        """))
        // While narrating, the reader follows the narration rather than returning to where it was left.
        if let anchor {
            configuration.userContentController.addUserScript(Self.userScript(Self.anchorScript(anchor)))
        } else if narrating == nil, progress > 0 {
            configuration.userContentController.addUserScript(Self.userScript("reedProgress.restore(\(min(max(progress, 0), 1)));"))
        }
        configuration.userContentController.addUserScript(Self.userScript(Self.script("ReaderNarration")))
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "narrationJump")
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "narrationAway")
        configuration.userContentController.addUserScript(Self.userScript(Self.script("ReaderNotes")))
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "notesOpen")
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "noteChanged")
        configuration.userContentController.addUserScript(Self.userScript(Self.script("ReaderCards")))
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "openCard")
        #if os(macOS)
        // AppKit's menu hook doesn't say which link was clicked, so the page reports it first.
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "contextLink")
        configuration.userContentController.addUserScript(Self.userScript("""
        document.addEventListener('contextmenu', event => {
            const link = event.target.closest && event.target.closest('a[href]');
            window.webkit.messageHandlers.contextLink.postMessage(link ? link.href : '');
        }, true);
        """))
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
        coordinator.applyNotesOpen(webView)
        coordinator.applyCards(webView)
        #if os(iOS)
        // Swiping back from the screen's edge closes the margin, rather than leaving the article.
        if coordinator.backSwipeDisabled != notesOpen { coordinator.setBackSwipe(enabled: !notesOpen, from: webView) }
        #endif
    }

    /// The page's own scripts are off, so Reed's run in a world of their own once the document has loaded.
    private static func userScript(_ source: String) -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
    }

    /// A script bundled with ReedCore. They ship with the app, so a missing one is a build mistake.
    private static func script(_ name: String) -> String {
        do { return try BundledResource.text(name, extension: "js") } catch {
            assertionFailure("Missing \(name).js")
            return ""
        }
    }

    /// Returns to where reading left off before the text fades in, so it doesn't appear at the top first.
    private static func anchorScript(_ anchor: String) -> String {
        let id = (try? String(data: JSONEncoder().encode(anchor), encoding: .utf8)) ?? "\"\""
        return "document.getElementById(\(id))?.scrollIntoView();"
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: OfflineWebView
        var loaded = false
        var contextLink: URL?
        private var currentFontSize: Double?
        private var sentPassages: [[String]]?
        private var shownNarration: NarrationPosition?
        private var sentNotes = false
        private var shownNotesOpen = false
        private var shownCards: [EndCard]?
        init(parent: OfflineWebView) { self.parent = parent }

        func applyFont(_ webView: WKWebView) {
            guard currentFontSize != parent.fontSize else { return }
            currentFontSize = parent.fontSize
            webView.evaluateJavaScript("document.documentElement.style.setProperty('--font-size', '\(parent.fontSize)px')", in: nil, in: .defaultClient) { _ in }
        }

        func applyPassages(_ webView: WKWebView) {
            guard let passages = parent.passages, let notes = parent.notes, passages != sentPassages || !sentNotes else { return }
            sentPassages = passages
            sentNotes = true
            shownNarration = nil
            let written = notes.map { ["passage": $0.passage, "text": $0.text] as [String: Any] }
            webView.callAsyncJavaScript("reedNarration.setPassages(passages); reedNotes.setNotes(notes)",
                                        arguments: ["passages": passages, "notes": written], in: nil, in: .defaultClient) { _ in }
        }

        func applyNotesOpen(_ webView: WKWebView) {
            guard sentNotes, shownNotesOpen != parent.notesOpen else { return }
            shownNotesOpen = parent.notesOpen
            webView.evaluateJavaScript("reedNotes.setOpen(\(parent.notesOpen))", in: nil, in: .defaultClient) { _ in }
        }

        func applyCards(_ webView: WKWebView) {
            guard shownCards != parent.cards else { return }
            shownCards = parent.cards
            let cards = parent.cards.map { ["id": $0.id, "kicker": $0.kicker, "source": $0.source, "title": $0.title, "detail": $0.detail] }
            webView.callAsyncJavaScript("reedCards.set(cards)", arguments: ["cards": cards], in: nil, in: .defaultClient) { _ in }
        }

        func applyNarration(_ webView: WKWebView) {
            guard sentPassages != nil, shownNarration != parent.narrating else { return }
            shownNarration = parent.narrating
            if let position = parent.narrating {
                webView.callAsyncJavaScript("reedNarration.show(index, sentence)", arguments: ["index": position.passage, "sentence": position.sentence],
                                            in: nil, in: .defaultClient) { _ in }
            } else {
                webView.evaluateJavaScript("reedNarration.clear()", in: nil, in: .defaultClient) { _ in }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            applyFont(webView)
            applyPassages(webView)
            applyNotesOpen(webView)
            applyCards(webView)
            if parent.narrating != nil { applyNarration(webView) }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "contextLink" {
                contextLink = (message.body as? String).flatMap(URL.init(string:)).flatMap { Self.isWeb($0) ? $0 : nil }
                return
            }
            if message.name == "openCard" {
                if let id = message.body as? String { parent.onOpenCard(id) }
                return
            }
            if message.name == "narrationJump" {
                if let index = message.body as? Int { parent.onNarrateFrom(index) }
                return
            }
            if message.name == "notesOpen" {
                guard let open = message.body as? Bool else { return }
                shownNotesOpen = open
                parent.onNotesOpen(open)
                return
            }
            if message.name == "noteChanged" {
                guard let body = message.body as? [String: Any], let passage = body["passage"] as? Int, let text = body["text"] as? String else { return }
                parent.onNoteChange(passage, text)
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
                if url.fragment != nil, url.isFileURL, url.standardizedFileURL.path == parent.url.standardizedFileURL.path { return .allow }
                if url.isFileURL, url.deletingLastPathComponent().standardizedFileURL == parent.url.deletingLastPathComponent().standardizedFileURL {
                    parent.onOpenSibling(url.lastPathComponent, url.fragment)
                    return .cancel
                }
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

        #if os(iOS)
        private(set) var backSwipeDisabled = false

        func setBackSwipe(enabled: Bool, from view: UIView) {
            var responder: UIResponder? = view
            while let next = responder, !(next is UIViewController) { responder = next.next }
            guard let navigation = (responder as? UIViewController)?.navigationController else { return }
            backSwipeDisabled = !enabled
            navigation.interactivePopGestureRecognizer?.isEnabled = enabled
            if #available(iOS 26, *) { navigation.interactiveContentPopGestureRecognizer?.isEnabled = enabled }
        }
        #endif

        static func isWeb(_ url: URL) -> Bool { ["https", "http"].contains(url.scheme?.lowercased() ?? "") }

        #if os(iOS)
        func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
            guard let url = elementInfo.linkURL, Self.isWeb(url) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
                let save = UIAction(title: "Save", image: UIImage(systemName: "tray.and.arrow.down")) { _ in self?.parent.onAddLink(url) }
                return UIMenu(children: [save] + suggested)
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
        let item = NSMenuItem(title: "Save", action: #selector(addLink(_:)), keyEquivalent: "")
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
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "notesOpen", contentWorld: .defaultClient)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "noteChanged", contentWorld: .defaultClient)
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
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "notesOpen", contentWorld: .defaultClient)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "noteChanged", contentWorld: .defaultClient)
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        if coordinator.backSwipeDisabled { coordinator.setBackSwipe(enabled: true, from: uiView) }
    }
}
#endif
