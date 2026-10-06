import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A subscribed RSS, Atom or JSON feed, with the entries last fetched from it.
public struct Feed: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public var title: String
    public var siteURL: URL?
    /// Newest first.
    public var items: [SourceItem] = []
    public var fetchedAt: Date?
    /// Why the last refresh failed; earlier items are kept.
    public var failure: String?
    var etag: String?
    var lastModified: String?

    /// How many entries are kept from each feed.
    static let itemLimit = 50

    init(url: URL, parsed: ParsedFeed, fetchedAt: Date, etag: String?, lastModified: String?) {
        id = UUID()
        self.url = url
        title = parsed.title ?? url.host() ?? url.absoluteString
        self.etag = etag
        self.lastModified = lastModified
        update(with: parsed, at: fetchedAt)
    }

    mutating func update(with parsed: ParsedFeed, at date: Date) {
        if let title = parsed.title { self.title = title }
        siteURL = parsed.siteURL ?? siteURL
        var seen = Set<String>()
        items = parsed.entries
            .map { entry in
                SourceItem(id: id.uuidString + "|" + (entry.id ?? entry.url.absoluteString), title: entry.title, url: entry.url,
                           discussionURL: nil, author: entry.author, points: nil, comments: nil, postedAt: entry.postedAt,
                           feedID: id, excerpt: entry.excerpt)
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
            .prefix(Self.itemLimit)
            .map { $0 }
        fetchedAt = date
        failure = nil
    }
}

/// A feed offered by a page, before subscribing to it.
public struct FeedCandidate: Identifiable, Hashable, Sendable {
    public let url: URL
    public let title: String
    public var id: URL { url }
}

struct ParsedFeed: Sendable {
    struct Entry: Sendable {
        var id: String?
        var title: String
        var url: URL
        var author: String?
        var postedAt: Date?
        var excerpt: String?
    }
    var title: String?
    var siteURL: URL?
    var entries: [Entry]
}

enum FeedParser {
    /// The feed in `data`, or nil if it isn't RSS, Atom or JSON Feed.
    static func parse(_ data: Data, from url: URL) -> ParsedFeed? {
        if let json = parseJSON(data, from: url) { return json }
        let delegate = XMLFeedDelegate(base: url)
        // Many feeds are served with blank lines before the XML declaration, which XMLParser rejects.
        let parser = XMLParser(data: Data(data.drop(while: \.isSkippedBeforeContent)))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        // Entries read before a malformed tail are still worth showing.
        _ = parser.parse()
        return delegate.result
    }

    private static func parseJSON(_ data: Data, from base: URL) -> ParsedFeed? {
        struct JSONFeed: Decodable {
            struct Author: Decodable { let name: String? }
            struct Item: Decodable {
                let id: String?
                let url: String?
                let external_url: String?
                let title: String?
                let summary: String?
                let content_text: String?
                let content_html: String?
                let date_published: String?
                let date_modified: String?
                let authors: [Author]?
                let author: Author?
            }
            let version: String
            let title: String?
            let home_page_url: String?
            let items: [Item]
            let authors: [Author]?
        }
        guard data.first(where: { !$0.isSkippedBeforeContent }) == UInt8(ascii: "{"),
              let feed = try? JSONDecoder().decode(JSONFeed.self, from: data),
              feed.version.contains("jsonfeed.org") else { return nil }
        let feedAuthor = feed.authors?.first?.name
        return ParsedFeed(
            title: clean(feed.title),
            siteURL: feed.home_page_url.flatMap { link($0, base: base) },
            entries: feed.items.compactMap { item in
                guard let url = (item.url ?? item.external_url).flatMap({ link($0, base: base) }) else { return nil }
                let excerpt = item.summary ?? item.content_text ?? item.content_html
                return .init(id: item.id, title: clean(item.title) ?? clean(excerpt).map { String($0.prefix(80)) } ?? url.absoluteString,
                             url: url, author: item.authors?.first?.name ?? item.author?.name ?? feedAuthor,
                             postedAt: (item.date_published ?? item.date_modified).flatMap(date), excerpt: summarize(excerpt))
            })
    }

    /// The feeds a web page links to, in the page's order.
    static func discover(in html: String, base: URL) -> [FeedCandidate] {
        let types = ["application/rss+xml", "application/atom+xml", "application/feed+json", "application/rdf+xml"]
        var seen = Set<URL>()
        return matches(of: #"<link\b[^>]*>"#, in: html).compactMap { tag in
            let rel = attribute("rel", in: tag)?.lowercased().split(separator: " ") ?? []
            guard rel.contains("alternate"), let type = attribute("type", in: tag)?.lowercased(), types.contains(type),
                  let href = attribute("href", in: tag), let url = link(href, base: base), seen.insert(url).inserted else { return nil }
            return FeedCandidate(url: url, title: clean(attribute("title", in: tag)) ?? url.host() ?? url.absoluteString)
        }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) { return ArticleHTML.decodingEntities(String(tag[range])) }
        }
        return nil
    }

    static func link(_ string: String, base: URL) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
        return try? ArticleURL.parse(url.absoluteString)
    }

    /// Text without markup or runs of whitespace; nil when nothing is left.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let stripped = ArticleHTML.decodingEntities(text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return stripped.isEmpty ? nil : stripped
    }

    static func summarize(_ text: String?) -> String? {
        guard let text = clean(text) else { return nil }
        return text.count > 280 ? String(text.prefix(280)) + "…" : text
    }

    /// Made once, since making formatters is slow and feeds are full of dates. Parsing with them is thread-safe.
    nonisolated(unsafe) private static let isoFormatters = [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]].map {
        (options: ISO8601DateFormatter.Options) in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }

    private static let dateFormatters = [
        "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm zzz",
        "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm zzz", "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd'T'HH:mmZZZZZ", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    /// Dates in RFC 822 (RSS) or ISO 8601 (Atom, JSON Feed), as feeds actually write them.
    static func date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        for formatter in isoFormatters { if let date = formatter.date(from: trimmed) { return date } }
        for formatter in dateFormatters { if let date = formatter.date(from: trimmed) { return date } }
        // Some feeds name the weekday wrongly or not in English; the date stands without it.
        if let comma = trimmed.firstIndex(of: ","), trimmed.distance(from: trimmed.startIndex, to: comma) <= 10 {
            return date(String(trimmed[trimmed.index(after: comma)...]))
        }
        return nil
    }
}

/// Reads RSS 2.0, RSS 1.0 and Atom, which differ mostly in what their elements are called.
private final class XMLFeedDelegate: NSObject, XMLParserDelegate {
    private struct Entry {
        var id: String?
        var title: String?
        var link: String?
        var alternateLink: String?
        var author: String?
        var published: String?
        var updated: String?
        var summary: String?
        var content: String?
    }

    private let base: URL
    private var isFeed = false
    private var title: String?
    private var siteLink: String?
    private var feedAuthor: String?
    private var entries: [Entry] = []
    private var entry: Entry?
    private var path: [String] = []
    /// The text of each open element; markup inside an entry's text is flattened into it.
    private var texts: [String] = []
    private static let structural: Set<String> = ["rss", "rdf", "channel", "feed", "item", "entry"]

    init(base: URL) { self.base = base }

    var result: ParsedFeed? {
        guard isFeed else { return nil }
        return ParsedFeed(
            title: FeedParser.clean(title),
            siteURL: siteLink.flatMap { FeedParser.link($0, base: base) },
            entries: entries.compactMap { entry in
                guard let url = (entry.alternateLink ?? entry.link ?? entry.id.flatMap { $0.hasPrefix("http") ? $0 : nil })
                        .flatMap({ FeedParser.link($0, base: base) }) else { return nil }
                let excerpt = FeedParser.summarize(entry.summary ?? entry.content)
                return .init(id: entry.id, title: FeedParser.clean(entry.title) ?? excerpt.map { String($0.prefix(80)) } ?? url.absoluteString,
                             url: url, author: FeedParser.clean(entry.author ?? feedAuthor),
                             postedAt: (entry.published ?? entry.updated).flatMap(FeedParser.date), excerpt: excerpt)
            })
    }

    private static func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let element = Self.local(name)
        if path.isEmpty { isFeed = ["rss", "feed", "rdf"].contains(element) }
        if element == "item" || element == "entry" { entry = Entry() }
        // Atom links carry their address in an attribute; the alternate one is the article.
        if element == "link", let href = attributes["href"] {
            let rel = attributes["rel"] ?? "alternate"
            if entry != nil {
                if rel == "alternate", entry?.alternateLink == nil { entry?.alternateLink = href }
            } else if rel == "alternate", path.count == 1 {
                siteLink = siteLink ?? href
            }
        }
        path.append(element)
        texts.append("")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !texts.isEmpty { texts[texts.count - 1] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        self.parser(parser, foundCharacters: String(data: data, encoding: .utf8) ?? "")
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let element = Self.local(name)
        let raw = texts.removeLast()
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.dropLast().last
        defer { path.removeLast() }
        if let parent, !Self.structural.contains(parent), !texts.isEmpty { texts[texts.count - 1] += raw + " " }
        if element == "item" || element == "entry", let finished = entry {
            entries.append(finished)
            entry = nil
            return
        }
        guard !value.isEmpty else { return }
        if entry != nil {
            switch (element, parent) {
            case ("title", "item"), ("title", "entry"): entry?.title = value
            case ("link", "item"): entry?.link = value
            case ("guid", _), ("id", "entry"): entry?.id = value
            case ("pubdate", _), ("published", _), ("issued", _): entry?.published = value
            case ("date", _), ("updated", _), ("modified", _): entry?.updated = value
            case ("creator", _), ("name", "author"): if entry?.author == nil { entry?.author = value }
            // RSS authors are often an email address followed by a name in parentheses.
            case ("author", "item"): if entry?.author == nil { entry?.author = Self.rssAuthor(value) }
            case ("description", _), ("summary", _): entry?.summary = value
            case ("encoded", _), ("content", _): entry?.content = value
            default: break
            }
        } else {
            switch (element, parent) {
            case ("title", "channel"), ("title", "feed"): title = title ?? value
            case ("link", "channel"): siteLink = siteLink ?? value
            case ("name", "author") where path.count == 3, ("creator", "channel"): feedAuthor = feedAuthor ?? value
            default: break
            }
        }
    }

    private static func rssAuthor(_ value: String) -> String {
        if let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
            return String(value[value.index(after: open)..<close])
        }
        return value
    }
}

private extension UInt8 {
    /// Whitespace, or a byte of a UTF-8 byte order mark.
    var isSkippedBeforeContent: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D || self == 0xEF || self == 0xBB || self == 0xBF }
}
