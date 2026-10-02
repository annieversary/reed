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

private let arxivAbstract = """
<html><head><meta name="citation_title" content="Gears from Sprockets"></head><body>
<div class="authors"><span class="descriptor">Authors:</span><a href="/a/one">Ada One</a>, <a href="/a/two">Bo Two</a></div>
<blockquote class="abstract mathjax"><span class="descriptor">Abstract:</span>We show sprockets become gears under mild conditions, quickly and quietly.</blockquote>
<a href="https://arxiv.org/html/2401.00001v2" id="latexml-download-link">HTML (experimental)</a>
<ul>\(languages)</ul></body></html>
"""

@Test @MainActor func arxivPaperKeepsAuthorsAbstractAndPaper() async throws {
    let paper = """
    <html><body><nav class="ltx_page_navbar"><ol><li>Contents</li></ol></nav><div class="ltx_page_content"><article class="ltx_document">
    <h1 class="ltx_title ltx_title_document">Gears from Sprockets</h1><div class="ltx_authors">Ada One, Bo Two</div>
    <div class="ltx_abstract"><h6>Abstract</h6><p>We show sprockets become gears.</p></div>
    <section class="ltx_section"><h2 class="ltx_title">1 Introduction</h2>
    <p class="ltx_p">Every sprocket with <math alttext="n" display="inline"><mi>n</mi></math> teeth meshes once its pitch satisfies
    <math alttext="p^{2}\\leq n" display="inline"><semantics><mrow><msup><mi>p</mi><mn>2</mn></msup><mo>≤</mo><mi>n</mi></mrow>\
    <annotation encoding="application/x-tex">p^{2}\\leq n</annotation></semantics></math>, as the figure below shows for several sprockets of different sizes.</p>
    <figure class="ltx_figure"><img src="2401.00001v2/x1.png" alt="A gear"><figcaption>A gear meshing with a sprocket.</figcaption></figure>
    <figure class="ltx_figure"><object type="image/svg+xml" data="2401.00001v2/x2.svg"></object><figcaption>Teeth per sprocket, plotted.</figcaption></figure>
    <figure class="ltx_table"><table class="ltx_tabular ltx_guessed_headers"><tr><th>Teeth</th></tr><tr><td>14336</td></tr></table></figure>
    <table class="ltx_equation ltx_eqn_table"><tr><td class="ltx_eqn_cell"></td><td class="ltx_eqn_cell"><math alttext="p=n" display="block"><mi>p</mi><mo>=</mo><mi>n</mi></math></td>\
    <td class="ltx_eqn_cell ltx_eqn_eqno"><span>(1)</span></td></tr></table>
    <p class="ltx_p">We measured many sprockets over many weeks and found the result holds for every one of them without exception.</p>
    </section></article></div></body></html>
    """
    var fetched: [URL] = []
    let article = try await extract(arxivAbstract, url: "https://arxiv.org/abs/2401.00001") { url in
        fetched.append(url)
        return paper
    }
    #expect(fetched.map(\.absoluteString) == ["https://arxiv.org/html/2401.00001v2"])
    #expect(article.title == "Gears from Sprockets")
    #expect(article.excerpt.hasPrefix("We show sprockets become gears under mild conditions"))
    #expect(article.html.hasPrefix("<p>Authors: Ada One, Bo Two</p><h2>Abstract</h2><p>We show sprockets"))
    #expect(article.html.contains("<h2>Paper</h2>"))
    #expect(article.html.contains(#"Every sprocket with <math alttext="n" display="inline" aria-label="n"><mi>n</mi></math> teeth"#))
    #expect(article.html.contains(#"aria-label="p squared is less than or equal to n""#))
    #expect(article.html.contains("<mrow><msup><mi>p</mi><mn>2</mn></msup><mo>≤</mo><mi>n</mi></mrow></math>"))
    #expect(!article.html.contains("annotation"))
    #expect(article.html.contains("14336"))
    #expect(article.html.contains(#"<p> <math alttext="p=n" display="inline" displaystyle="true" aria-label="p equals n"><mi>p</mi><mo>=</mo><mi>n</mi></math> <span>(1)</span> </p>"#))
    #expect(article.images.map(\.url) == ["https://arxiv.org/html/2401.00001v2/x1.png", "https://arxiv.org/html/2401.00001v2/x2.svg"])
    #expect(article.images.map(\.filename) == ["image-0", "image-1.svg"])
    #expect(!article.html.contains("Contents"))
    #expect(!article.html.contains("We show sprockets become gears.</p>"))
    #expect(!article.html.contains("Language"))
}

@Test @MainActor func arxivPaperWithoutHTMLKeepsAuthorsAndAbstract() async throws {
    let html = arxivAbstract.replacingOccurrences(of: "id=\"latexml-download-link\"", with: "")
    let article = try await extract(html, url: "https://arxiv.org/abs/2401.00001") { _ in Issue.record("nothing to fetch"); return "" }
    #expect(article.html.hasPrefix("<p>Authors: Ada One, Bo Two</p><h2>Abstract</h2>"))
    #expect(!article.html.contains("Paper"))
}

@Test func arxivRenderingsReadFromTheAbstractPage() {
    let page = { ArticleDownloader.readablePage(for: URL(string: $0)!).absoluteString }
    #expect(page("https://arxiv.org/pdf/2401.00001v2") == "https://arxiv.org/abs/2401.00001v2")
    #expect(page("https://arxiv.org/pdf/hep-th/9901001.pdf") == "https://arxiv.org/abs/hep-th/9901001")
    #expect(page("https://arxiv.org/html/2401.00001v2/#S1") == "https://arxiv.org/abs/2401.00001v2")
    #expect(page("https://example.org/pdf/1") == "https://example.org/pdf/1")
}

@Test @MainActor func formulasAreWordedForNarration() async throws {
    let formulas = [
        "<mrow><mi>a</mi><mo>⋅</mo><msub><mi>E</mi><mi>i</mi></msub></mrow><mo>\u{200B}</mo><mrow><mo>(</mo><mi>x</mi><mo>)</mo></mrow>",
        "<mi mathvariant=\"normal\">ℓ</mi><mo>∈</mo><msup><mi>ℝ</mi><mi>n</mi></msup>",
        "<msup><mi>W</mi><mo>⊤</mo></msup><mi>x</mi>",
        "<mn>2</mn><mo>\u{2062}</mo><mrow><mo>(</mo><mi>x</mi><mo>+</mo><mn>1</mn><mo>)</mo></mrow>"
    ]
    let paragraphs = formulas.map { "<p>Sprockets turn into gears whenever <math alttext=\"f\"><mrow>\($0)</mrow></math> holds for them, quickly and quietly.</p>" }
    let article = try await extract("<html><body><article>\(paragraphs.joined())</article></body></html>", url: "https://example.org/gears")
    let labels = article.html.matches(of: #/aria-label="([^"]*)"/#).map { String($0.output.1) }
    #expect(labels == ["a times E sub i of x", "ell is a member of R to the n", "W transpose x", "2 times open paren x plus 1 close paren"])
}
