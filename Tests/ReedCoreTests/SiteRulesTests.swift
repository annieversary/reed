import Foundation
import Testing
@testable import ReedCore

private let languages = (1...8).map { "<li>Language \($0)</li>" }.joined()
private let readme = "<h1>Widget<a class=\"anchor\" href=\"#widget\">#</a></h1><p>Widget turns sprockets into gears, quickly and quietly, for anyone who needs gears.</p>"

@MainActor private func extract(_ html: String, url: String, fetch: (URL) async throws -> String = { _ in "" }) async throws -> ExtractedArticle {
    try await ArticleExtractor().extract(html: html, url: URL(string: url)!, fetch: fetch)
}

@Test @MainActor func githubRepositoryKeepsDescriptionAndReadme() async throws {
    let html = """
    <html><body><ul class="languages">\(languages)</ul>
    <p class="SidebarAbout-module__description__x">Gears from sprockets</p>
    <article class="markdown-body">\(readme)</article></body></html>
    """
    let article = try await extract(html, url: "https://github.com/someone/widget")
    #expect(article.title == "someone/widget")
    #expect(article.excerpt == "Gears from sprockets")
    #expect(article.html.hasPrefix("<p>Gears from sprockets</p>"))
    #expect(article.html.contains("Widget turns sprockets"))
    #expect(!article.html.contains("Language"))
    #expect(!article.html.contains("#widget"))
}

@Test @MainActor func gitlabProjectFetchesItsReadme() async throws {
    let html = """
    <html><head><meta property="og:site_name" content="GitLab"><meta property="og:title" content="Someone / widget · GitLab"></head>
    <body><script>gl.startup_calls = {"/someone/widget/-/blob/main/README.md?format=json\\u0026viewer=rich":{}};</script>
    <div class="home-panel"><div itemprop="description"><div class="read-more-content"><p>Gears from sprockets</p></div><button>Read more</button></div></div>
    <ul>\(languages)</ul></body></html>
    """
    var fetched: [URL] = []
    let article = try await extract(html, url: "https://gitlab.example.org/someone/widget") { url in
        fetched.append(url)
        let body = try JSONSerialization.data(withJSONObject: ["html": "<div class=\"blob-viewer\"><div class=\"file-content\">\(readme)</div></div>"])
        return String(decoding: body, as: UTF8.self)
    }
    #expect(fetched.map(\.absoluteString) == ["https://gitlab.example.org/someone/widget/-/blob/main/README.md?format=json&viewer=rich"])
    #expect(article.title == "Someone / widget")
    #expect(article.excerpt == "Gears from sprockets")
    #expect(article.html.contains("Widget turns sprockets"))
    #expect(!article.html.contains("Read more"))
    #expect(!article.html.contains("Language"))
}

@Test @MainActor func tangledRepositoryKeepsDescriptionAndReadme() async throws {
    let html = """
    <html><head><meta property="og:site_name" content="Tangled"><meta property="og:title" content="someone.org/widget">
    <meta property="og:description" content="Gears from sprockets"><meta name="forge:summary" content="https://tangled.org/someone.org/widget"></head>
    <body><ul>\(languages)</ul><section class="prose"><article>\(readme)</article></section></body></html>
    """
    let article = try await extract(html, url: "https://tangled.org/@someone.org/widget")
    #expect(article.title == "someone.org/widget")
    #expect(article.html.hasPrefix("<p>Gears from sprockets</p>"))
    #expect(article.html.contains("Widget turns sprockets"))
    #expect(!article.html.contains("Language"))
}

@Test @MainActor func otherPagesStillUseReadability() async throws {
    let html = try String(contentsOf: Bundle.module.url(forResource: "Fixtures/article", withExtension: "html")!, encoding: .utf8)
    let article = try await extract(html, url: "https://github.com/someone/widget/issues/1")
    #expect(article.wordCount > 50)
}
