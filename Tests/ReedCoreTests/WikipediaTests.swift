import Foundation
import Testing
@testable import ReedCore

private func page(_ title: String, views: Int? = nil, rank: Int? = nil) -> String {
    let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    return """
    {"titles":{"normalized":"\(title)"},"content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/\(path)"}},
     "extract":"About \(title).","views":\(views.map(String.init) ?? "null"),"rank":\(rank.map(String.init) ?? "null")}
    """
}

@Test func wikipediaListsTheFeaturedArticleThenTheNewsThenTheMostRead() throws {
    let data = Data("""
    {"tfa":\(page("Mario Party: Star Rush")),
     "news":[{"story":"<!--Oct 03--><b id=\\"a\\"><a rel=\\"mw:WikiLink\\" href=\\"./2026_Spanish_general_election\\">A snap election</a></b> is announced after <a href=\\"./Housing\\">protests</a>, &amp; more.",
              "links":[\(page("Housing")),\(page("2026 Spanish general election"))]}],
     "mostread":{"articles":[\(page("Steve Gleason", views: 515772, rank: 4)),\(page("Housing", views: 9, rank: 9)),\(page("Christa Pike", views: 1000, rank: 2))]}}
    """.utf8)
    let items = try ExternalSource.wikipediaPage(from: data)
    #expect(items.map(\.title) == ["Mario Party: Star Rush", "2026 Spanish general election", "Christa Pike", "Steve Gleason", "Housing"])
    #expect(items[0].reason == .featured && items[0].excerpt == "About Mario Party: Star Rush.")
    #expect(items[0].url.absoluteString == "https://en.wikipedia.org/wiki/Mario_Party:_Star_Rush")
    #expect(items[1].reason == .inTheNews && items[1].excerpt == "A snap election is announced after protests, & more.")
    #expect(items[3].reason == nil && items[3].points == 515772)
}

@Test func wikimediaHostsAreKnown() {
    #expect(ArticleDownloader.isWikimedia("en.wikipedia.org") && ArticleDownloader.isWikimedia("upload.wikimedia.org"))
    #expect(!ArticleDownloader.isWikimedia("notwikipedia.org"))
}

@Test @MainActor func wikipediaArticlesAreReadFromParsoid() async throws {
    let html = """
    <html><head><link rel="canonical" href="https://en.wikipedia.org/wiki/AC/DC"></head>
    <body class="mediawiki ns-0"><div id="content"><p>The skin's own copy of the article, which isn't used.</p></div></body></html>
    """
    let prose = "AC/DC are an Australian rock band formed in Sydney in 1973 by Scottish-born brothers Malcolm and Angus Young."
    let parsoid = """
    <html><head><title>AC/DC</title><base href="//en.wikipedia.org/wiki/"/></head><body>
    <section data-mw-section-id="0"><div class="shortdescription" style="display:none">Hard rock group</div>
    <div role="note" class="hatnote">For other uses, see AC/DC (disambiguation).</div>
    <table class="infobox"><tr><td class="infobox-image"><img src="//upload.wikimedia.org/a/250px-Band.jpg" srcset="//upload.wikimedia.org/a/500px-Band.jpg 2x" width="250" alt="The band"/>
    <div class="infobox-caption">Live in 2015</div></td></tr><tr><th>Origin</th><td>Sydney</td></tr></table>
    <p>\(prose)<sup class="mw-ref reference" typeof="mw:Extension/ref"><a href="./AC/DC#cite_note-1">[1]</a></sup>
    <span class="flagicon"><span typeof="mw:File"><img src="//upload.wikimedia.org/flag.png" width="23"/></span></span>
    <a rel="mw:WikiLink" href="./Malcolm_Young">Malcolm</a><sup class="noprint Inline-Template">[citation needed]</sup></p></section>
    <section data-mw-section-id="1"><h2 id="History">History</h2><p>\(prose)</p></section>
    <section data-mw-section-id="2"><h2 id="References">References</h2><div class="mw-references-wrap"><ol typeof="mw:Extension/references"><li>A source</li></ol></div></section>
    <section data-mw-section-id="3"><h2 id="Enlaces_externos">Enlaces externos</h2><ul><li><a rel="mw:ExtLink" href="https://acdc.com">Official website</a></li></ul></section>
    <div role="navigation" class="navbox">Band members</div>
    </body></html>
    """
    var fetched: [URL] = []
    let article = try await ArticleExtractor().extract(html: html, url: URL(string: "https://en.wikipedia.org/wiki/AC/DC")!) { url in
        fetched.append(url)
        return parsoid
    }
    #expect(fetched.map(\.absoluteString) == ["https://en.wikipedia.org/w/rest.php/v1/page/AC%2FDC/html"])
    #expect(article.title == "AC/DC")
    #expect(article.html.contains("<h2 id=\"History\">History</h2>"))
    #expect(article.html.contains("href=\"https://en.wikipedia.org/wiki/Malcolm_Young\""))
    #expect(article.html.contains("<figcaption>Live in 2015</figcaption>"))
    #expect(article.images.map(\.url) == ["https://upload.wikimedia.org/a/500px-Band.jpg"])
    for gone in ["skin's own", "Hard rock group", "disambiguation", "Origin", "[1]", "citation needed", "References", "A source", "Official website", "Band members"] {
        #expect(!article.html.contains(gone), "\(gone)")
    }
}
