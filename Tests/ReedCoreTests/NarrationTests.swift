import Foundation
import Testing
import WebKit
@testable import ReedCore

@MainActor private final class LoadedPage: NSObject, WKNavigationDelegate {
    let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var continuation: CheckedContinuation<Void, Error>?

    init(html: String) async throws {
        super.init()
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
}

@Test @MainActor func narrationFindsEachPassageInReadingOrder() async throws {
    let page = try await LoadedPage(html: """
        <html><head></head><body><main><h1>T</h1><p>and more.</p><figure><img alt="A barn"></figure>\
        <p>Look <img alt="a chart"> here now</p><div><img alt="A diagram"><br>and more.</div><p>After</p></main></body></html>
        """)
    _ = try await page.view.callAsyncJavaScript(try BundledResource.text("ReaderNarration", extension: "js") + "\nreturn true;",
                                                contentWorld: .page)
    let found = try await page.view.callAsyncJavaScript("""
        reedNarration.setPassages([["T"], ["and more."], ["Image: A barn"], ["Look here now"], ["Image: A diagram"], ["and more."], ["After"]]);
        return reedNarration.elements.map(element => element && element.tagName + ':' + (element.alt || element.textContent));
        """, contentWorld: .page)
    // The second "and more." follows the diagram, so it's the div's, not the first paragraph's.
    #expect(found as? [String] == ["H1:T", "P:and more.", "IMG:A barn", "P:Look  here now", "IMG:A diagram", "DIV:and more.", "P:After"])
}

@Test @MainActor func narrationTintsSentencesAcrossFootnoteMarkers() async throws {
    let body = ##"<p>Africa<sup>1</sup>, then<sup><a href="#fn:2">2</a></sup> and<a href="#fn3"><sup>3</sup></a> 10<sup>6</sup> cells. Next.</p>"##
    let page = try await LoadedPage(html: "<html><head></head><body><main>\(body)</main></body></html>")
    _ = try await page.view.callAsyncJavaScript(try BundledResource.text("ReaderNarration", extension: "js") + "\nreturn true;",
                                                contentWorld: .page)
    let passages = ArticleSpeech.passages(title: "T", html: "<main>\(body)</main>").dropFirst().map(ArticleSpeech.sentences(in:))
    let tinted = try await page.view.callAsyncJavaScript("""
        reedNarration.setPassages(passages);
        reedNarration.show(0, 0);
        return document.querySelector('.reed-narrating') ? null
            : Array.from(document.querySelectorAll('.reed-sentence')).map(span => span.textContent).join('|');
        """, arguments: ["passages": passages], contentWorld: .page)
    #expect(tinted as? String == "Africa|1|, then|2| and|3| 10|6| cells.")
}

@Test @MainActor func narrationFindsListItemsInsideLists() async throws {
    let page = try await LoadedPage(html: """
        <html><head></head><body><main><p>Intro</p><ul><li>One<ul><li>Sub</li></ul></li><li><p>Two</p></li></ul>\
        <p>After</p></main></body></html>
        """)
    _ = try await page.view.callAsyncJavaScript(try BundledResource.text("ReaderNarration", extension: "js") + "\nreturn true;",
                                                contentWorld: .page)
    let found = try await page.view.callAsyncJavaScript("""
        reedNarration.setPassages([["Intro"], ["One"], ["Sub"], ["Two"], ["After"]]);
        return reedNarration.elements.map(element => element && element.tagName + ':' + element.textContent);
        """, contentWorld: .page)
    #expect(found as? [String] == ["P:Intro", "LI:OneSub", "LI:Sub", "P:Two", "P:After"])
}
