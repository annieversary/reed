import Foundation
import Testing
@testable import ReedCore

private let filler = "<p>Sprockets turn into gears under mild conditions, quickly and quietly, for anyone who needs gears.</p>"

@Test @MainActor func inlineDrawingsAndChartKeysAreKeptAndIconsDropped() async throws {
    let body = """
    <p>Here's how the gears mesh, drawn to scale for the curious and the careful alike.</p>
    <figure><svg viewBox="0 0 100 50" role="img" aria-label="Two gears" onload="alert(1)">
    <defs><linearGradient id="shade"><stop offset="0" stop-color="var(--gear, #d97706)"/></linearGradient></defs>
    <circle cx="25" cy="25" r="20" fill="url(#shade)" stroke="var(--edge)" class="gear"/>
    <use href="#tooth"/><use href="https://tracker.example/sprite.svg#tooth"/>
    <image href="/teeth.png" width="10" height="10"/>
    <script>alert(1)</script><foreignObject><p>Hidden</p></foreignObject>
    <text x="50" y="45" font-size="6">Sprocket</text></svg><figcaption>Meshing gears.</figcaption></figure>
    <p>A <svg width="16" height="16" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg> icon, and another
    <svg width="12" height="12" viewBox="0 0 10 10" aria-hidden="true"><path d="M0 0h10v10H0z" stroke="currentColor" fill="#6b7280"/></svg> beside it.</p>
    <p><span><svg width="30" height="12" aria-hidden="true"><line x1="0" x2="30" y1="6" y2="6" stroke="rgb(217, 119, 6)"/></svg>Spotlight</span>, the key to a chart.</p>
    """
    let article = try await ArticleExtractor().extract(
        html: "<html><body><article>\(filler)\(body)\(filler)</article></body></html>",
        url: URL(string: "https://example.org/gears")!, fetch: { _ in "" })
    let html = article.html
    #expect(html.components(separatedBy: "<svg").count == 3)
    #expect(html.contains(#"<svg width="30" height="12""#))
    #expect(html.contains(#"viewBox="0 0 100 50""#))
    #expect(html.contains(#"aria-label="Two gears""#))
    #expect(html.contains(##"stop-color="#d97706""##))
    #expect(html.contains(##"fill="url(#shade)""##))
    #expect(!html.contains("var("))
    #expect(html.contains(##"<use href="#tooth">"##))
    #expect(!html.contains("tracker.example"))
    #expect(!html.contains("<script") && !html.contains("onload") && !html.contains("foreignObject") && !html.contains("class="))
    #expect(html.contains("Sprocket</text>"))
    #expect(article.images.map(\.url) == ["https://example.org/teeth.png"])
    #expect(html.contains(#"<image href="image-0""#))
    #expect(!ArticleSpeech.passages(title: "Gears", html: "<main>\(html)</main>").contains { $0.contains("Sprocket") && !$0.contains("Sprockets") })
}
