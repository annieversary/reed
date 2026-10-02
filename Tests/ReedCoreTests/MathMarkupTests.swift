import Foundation
import Testing
@testable import ReedCore

private let filler = "<p>Sprockets turn into gears under mild conditions, quickly and quietly, for anyone who needs gears.</p>"

@MainActor private func extract(_ body: String, head: String = "") async throws -> ExtractedArticle {
    try await ArticleExtractor().extract(html: "<html><head>\(head)</head><body><article>\(filler)\(body)\(filler)</article></body></html>",
                                         url: URL(string: "https://example.org/gears")!, fetch: { _ in "" })
}

private func formulas(in html: String) -> [(tex: String, label: String)] {
    html.matches(of: #/<math\b[^>]*\balttext="([^"]*)"[^>]*\baria-label="([^"]*)"/#).map { (String($0.output.1), String($0.output.2)) }
}

@Test @MainActor func katexKeepsItsMathMLAndDropsItsLayout() async throws {
    let katex = """
    <span class="katex"><span class="katex-mathml"><math xmlns="http://www.w3.org/1998/Math/MathML"><semantics><mrow><msup><mi>x</mi><mn>2</mn></msup></mrow>\
    <annotation encoding="application/x-tex">x^2</annotation></semantics></math></span><span class="katex-html" aria-hidden="true"><span class="base">x2</span></span></span>
    """
    let article = try await extract("<p>Every gear has \(katex) teeth, give or take a few, as the sprockets settle.</p><span class=\"katex-display\">\(katex)</span>",
                                    head: #"<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex/dist/katex.min.css">"#)
    #expect(formulas(in: article.html).map(\.tex) == ["x^2", "x^2"])
    #expect(formulas(in: article.html).first?.label == "x squared")
    #expect(article.html.contains(#"display="block""#))
    #expect(!article.html.contains("x2"))
    #expect(!article.html.contains("annotation"))
}

@Test @MainActor func mathJaxTeXIsConverted() async throws {
    let article = try await extract("""
        <p>Every gear has \\(n^2\\) teeth, which costs $5 and $10 at most, as the sprockets settle into place.</p>
        <p>$$\\sum_{i=1}^{n} i$$</p><script type="math/tex; mode=display">\\frac{1}{2}</script><pre>\\(not math\\)</pre>
        """, head: #"<script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>"#)
    #expect(formulas(in: article.html).map(\.tex) == ["n^2", "\\sum_{i=1}^{n} i", "\\frac{1}{2}"])
    #expect(formulas(in: article.html).map(\.label).first == "n squared")
    #expect(article.html.contains("costs $5 and $10"))
    #expect(article.html.contains("\\(not math\\)"))
}

@Test @MainActor func loneDollarsAreDelimitersOnlyWhereThePageSaysSo() async throws {
    let body = "<p>Every gear has $ n$ teeth, and a box of them costs $5, as the sprockets settle into place.</p>"
    let configured = try await extract(body, head: #"<script>MathJax={tex:{inlineMath:[["\\(","\\)"],["$","$"]]}}</script>"#)
    #expect(formulas(in: configured.html).map(\.tex) == ["n"])
    #expect(configured.html.contains("costs $5"))
    let unconfigured = try await extract(body, head: #"<script src="/mathjax/tex-chtml.js"></script>"#)
    #expect(formulas(in: unconfigured.html).isEmpty)
}

@Test @MainActor func pagesWithoutMathRenderingKeepTheirDollars() async throws {
    let article = try await extract(#"<p>The kit costs $5 and \(maybe\) $10, as the sprockets settle into place.</p>"#)
    #expect(!article.html.contains("<math"))
    #expect(article.html.contains(#"costs $5 and \(maybe\) $10"#))
}

@Test @MainActor func renderedMathJaxAndWikipediaKeepTheirMathML() async throws {
    let mathJax = #"<mjx-container class="MathJax" jax="CHTML" display="true"><mjx-math aria-hidden="true">x2</mjx-math><mjx-assistive-mml display="block"><math display="block"><msup><mi>x</mi><mn>2</mn></msup></math></mjx-assistive-mml></mjx-container>"#
    let wikipedia = #"<span class="mwe-math-element"><span class="mwe-math-mathml-inline mwe-math-mathml-a11y"><math alttext="{\displaystyle y^{3}}"><semantics><msup><mi>y</mi><mn>3</mn></msup><annotation encoding="application/x-tex">{\displaystyle y^{3}}</annotation></semantics></math></span><img src="https://wikimedia.org/api/rest_v1/media/math/render/svg/abc" class="mwe-math-fallback-image-inline" alt="{\displaystyle y^{3}}"></span>"#
    let article = try await extract("<p>Every gear has \(wikipedia) teeth, give or take a few, as the sprockets settle.</p>\(mathJax)")
    #expect(article.html.matches(of: #/aria-label="([^"]*)"/#).map { String($0.output.1) } == ["y cubed", "x squared"])
    #expect(article.images.isEmpty)
    #expect(!article.html.contains("x2"))
}
