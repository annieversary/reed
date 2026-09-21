#if DEBUG && os(macOS)
import AppKit
import WebKit
#if SWIFT_PACKAGE
import ReedCore
#endif

// Runs the real macOS app, WebKit, downloader, and persistent store against a local fixture server.
// Only enabled in debug builds; uses an explicitly supplied, isolated library directory.
@MainActor enum SmokeTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(library: Library) async {
        let arguments = ProcessInfo.processInfo.arguments
        func argument(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw Failure(message: name) }
            checks.append(name)
        }
        var failure: String?
        do {
            guard argument("--library-root") != nil else { throw Failure(message: "Smoke test requires an isolated library root") }
            if let base = argument("--smoke-url") {
                let article = try library.add(base + "/article")
                let duplicate = try library.add(base + "/article#section")
                try check(article.id == duplicate.id, "URL fragments do not create duplicate articles")
                let failed = try library.add(base + "/unavailable")
                let unsupported = try library.add(base + "/document.pdf")
                let deadline = Date().addingTimeInterval(90)
                while library.articles.contains(where: { $0.state == .queued || $0.state == .downloading }) && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(article.state == .partial, "Article text survives a missing image (\(article.failureMessage ?? article.state.rawValue))")
                try check(article.imageCount == 1 && article.missingImageCount == 1, "One local image saved; one failed image reported")
                try check(article.title == "The art of paying attention", "Readability extracts the article title")
                try check(article.author == "Reed Studio", "Readability extracts the author")
                try check(article.resolvedURL == base + "/story", "Redirected source URL is retained")
                try check(failed.state == .failed && failed.failureMessage?.contains("503") == true, "HTTP errors are surfaced")
                try check(unsupported.state == .failed, "Non-HTML content is rejected")
                library.toggleFavorite(article)
                library.updateProgress(article, value: 0.4)
                library.save()
            } else {
                try check(library.articles.count == 3, "Library survives a full app restart")
            }
            guard let article = library.articles.first(where: { $0.state.isReadable }), let url = library.contentURL(for: article) else {
                throw Failure(message: "No readable local article")
            }
            try check(article.isFavorite && abs(article.progress - 0.4) < 0.01, "Favorite and reading position persist")
            let html = try String(contentsOf: url, encoding: .utf8)
            try check(!html.contains("<script") && !html.contains("onerror=") && !html.contains("javascript:") && !html.contains("<iframe"), "Active content is removed")
            try check(!html.contains("src=\"http"), "Saved images have no remote references")
            try check(html.contains("Image unavailable"), "Missing images have a readable placeholder")
            let probe = ReaderProbe()
            let result = try await probe.read(url)
            try check(result["text"] as? Bool == true, "WebKit displays the saved article from disk")
            try check(result["images"] as? Bool == true, "WebKit decodes the saved image from disk")
            try check(result["inert"] as? Bool == true, "Publisher scripts never execute")
            if let snapshot = argument("--smoke-snapshot") {
                try await probe.snapshot(to: URL(fileURLWithPath: snapshot))
                // Window restoration and activation finish asynchronously after the app launches.
                NSApplication.shared.activate(ignoringOtherApps: true)
                let windowDeadline = Date().addingTimeInterval(15)
                while !NSApplication.shared.windows.contains(where: { $0.canBecomeMain }) && Date() < windowDeadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                let windows = NSApplication.shared.windows
                guard windows.contains(where: { $0.canBecomeMain }) else {
                    let descriptions = windows.map { "\(type(of: $0)) title=\($0.title) visible=\($0.isVisible) key=\($0.canBecomeKey) frame=\($0.frame)" }.joined(separator: "; ")
                    throw Failure(message: "No main library window: " + descriptions)
                }
                checks.append("Desktop library window is available")
                if let window = NSApplication.shared.windows.first(where: { $0.contentView != nil && $0.canBecomeMain }) {
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: Notification.Name("reed.smokeSelectArticle"), object: article.id)
                    try await Task.sleep(for: .seconds(1))
                    if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            try png.write(to: URL(fileURLWithPath: snapshot).deletingLastPathComponent().appendingPathComponent("library.png"))
                        }
                    }
                }
            }
        } catch { failure = error.localizedDescription }
        if let report = argument("--smoke-report") {
            let payload: [String: Any] = ["passed": failure == nil, "checks": checks, "error": failure ?? ""]
            do { try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: .atomic) }
            catch { NSLog("Smoke report failed: %@", error.localizedDescription) }
        }
        NSApplication.shared.terminate(nil)
    }

    @MainActor final class ReaderProbe: NSObject, WKNavigationDelegate {
        var view: WKWebView!
        var continuation: CheckedContinuation<Void, Error>?
        var timeout: Task<Void, Never>?

        func read(_ url: URL) async throws -> [String: Any] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            view = WKWebView(frame: CGRect(x: 0, y: 0, width: 740, height: 900), configuration: configuration)
            view.navigationDelegate = self
            defer { timeout?.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.finish(.failure(ReedError.extractionTimeout))
                }
                view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
            let result = try await view.callAsyncJavaScript("""
            await Promise.all(Array.from(document.images).map(img => img.complete ? Promise.resolve() : new Promise(resolve => { img.onload=resolve; img.onerror=resolve; })));
            return { text: document.body.textContent.includes('The art of paying attention'),
                     images: document.images.length === 1 && Array.from(document.images).every(img => img.naturalWidth > 0),
                     inert: !window.publisherScriptRan };
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
            return result as? [String: Any] ?? [:]
        }

        func snapshot(to url: URL) async throws {
            let image = try await view.takeSnapshot(configuration: nil)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try png.write(to: url)
        }

        func finish(_ result: Result<Void, Error>) {
            timeout?.cancel()
            let callback = continuation
            continuation = nil
            callback?.resume(with: result)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    }
}
#endif
