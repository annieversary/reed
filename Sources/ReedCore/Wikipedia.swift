import Foundation

extension ExternalSource {
    /// How many of the day's most read articles are listed, after the featured article and those in the news.
    static let wikipediaMostReadCount = 25

    /// The day's featured articles from the Wikipedia in the reader's language, or the English one if theirs has none.
    static func wikipediaItems(using downloader: ArticleDownloader) async throws -> [SourceItem] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.dateComponents([.year, .month, .day], from: .now)
        let path = String(format: "%04d/%02d/%02d", day.year!, day.month!, day.day!)
        var failure: Error?
        let language = wikipediaLanguage
        for language in language == "en" ? ["en"] : [language, "en"] {
            do {
                let url = URL(string: "https://\(language).wikipedia.org/api/rest_v1/feed/featured/\(path)")!
                let items = try wikipediaPage(from: await downloader.json(at: url))
                if !items.isEmpty { return items }
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        throw failure ?? ReedError.unsupportedContent
    }

    /// The reader's preferred language, as Wikipedia names its editions.
    private static var wikipediaLanguage: String {
        let code = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        return code == "nb" ? "no" : code
    }

    /// The featured article, then the articles in the news, then the most read, each listed once.
    static func wikipediaPage(from data: Data) throws -> [SourceItem] {
        struct Page: Decodable {
            struct Titles: Decodable { let normalized: String }
            struct URLs: Decodable { struct Links: Decodable { let page: String }; let desktop: Links }
            let titles: Titles
            let content_urls: URLs
            let extract: String?
            let views: Int?
            let rank: Int?
        }
        struct Story: Decodable {
            let story: String
            let links: [Page]
        }
        struct Day: Decodable {
            struct MostRead: Decodable { let articles: [Page] }
            let tfa: Page?
            let news: [Story]?
            let mostread: MostRead?
        }
        let day = try JSONDecoder().decode(Day.self, from: data)
        func item(_ page: Page, excerpt: String? = nil, reason: SourceReason? = nil) -> SourceItem? {
            // As Wikipedia links its pages and browsers show them, so a pasted link finds the same article.
            let address = page.content_urls.desktop.page.replacingOccurrences(of: "%3A", with: ":", options: .caseInsensitive)
            guard let url = try? ArticleURL.parse(address) else { return nil }
            return SourceItem(id: url.absoluteString, title: page.titles.normalized, url: url, discussionURL: nil, author: nil,
                              points: page.views, comments: nil, postedAt: nil, excerpt: excerpt ?? FeedParser.clean(page.extract), reason: reason)
        }
        var items = day.tfa.flatMap { item($0, reason: .featured) }.map { [$0] } ?? []
        for story in day.news ?? [] {
            // The story's subject is the article it links in bold; the rest are background.
            let bold = Set(matches(of: ##"<b\b[^>]*>\s*<a\b[^>]*href="\./([^"#]+)"##, in: story.story).compactMap { $0.removingPercentEncoding })
            let subject = story.links.first { bold.contains($0.content_urls.desktop.page.components(separatedBy: "/wiki/").last?.removingPercentEncoding ?? "") }
            // Its markup sits within words' own spacing, so is dropped without leaving any.
            let text = FeedParser.clean(story.story.replacingOccurrences(of: "<!--.*?-->|<[^>]*>", with: "", options: .regularExpression))
            if let page = subject ?? story.links.first, let found = item(page, excerpt: text, reason: .inTheNews) { items.append(found) }
        }
        let mostRead = (day.mostread?.articles ?? []).sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
        items += mostRead.prefix(wikipediaMostReadCount).compactMap { item($0) }
        var seen = Set<URL>()
        return items.filter { seen.insert($0.url).inserted }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
