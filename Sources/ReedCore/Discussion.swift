import Foundation

/// The comments on a link, as threaded on the site that hosts them.
public struct Discussion: Codable, Equatable, Sendable {
    public struct Comment: Codable, Equatable, Sendable {
        public let id: String
        /// Nil once the comment is deleted; it stays while it has replies.
        public let author: String?
        public let postedAt: Date?
        /// The comment's text, as HTML.
        public let html: String
        public var replies: [Comment]

        /// This comment and every reply beneath it.
        public var threadCount: Int { 1 + replies.reduce(0) { $0 + $1.threadCount } }
    }

    public let url: URL
    public let points: Int?
    public let comments: [Comment]
    public let fetchedAt: Date

    public var count: Int { comments.reduce(0) { $0 + $1.threadCount } }
}

/// A site whose discussions Reed can show.
public enum DiscussionSite: Hashable, Sendable {
    case hackerNews(id: Int)
    case lobsters(id: String)
    /// A Substack post's comments, on the publication's own host.
    case substack(host: String, slug: String)

    public init?(url: URL) {
        let host = url.host()?.lowercased() ?? ""
        let path = url.pathComponents.filter { $0 != "/" }
        if host == "news.ycombinator.com", path == ["item"],
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int.init) {
            self = .hackerNews(id: id)
        } else if host == "lobste.rs", path.count >= 2, path[0] == "s" {
            self = .lobsters(id: path[1])
        } else if path.count == 3, path[0] == "p", path[2] == "comments" {
            self = .substack(host: host, slug: path[1])
        } else {
            return nil
        }
    }

    public var name: String {
        switch self {
        case .hackerNews: "Hacker News"
        case .lobsters: "Lobste.rs"
        case .substack: "Substack"
        }
    }

    /// What the site calls a vote, such as "point".
    public var pointName: String {
        switch self {
        case .hackerNews, .lobsters: "point"
        case .substack: "like"
        }
    }

    public var url: URL {
        switch self {
        case .hackerNews(let id): URL(string: "https://news.ycombinator.com/item?id=\(id)")!
        case .lobsters(let id): URL(string: "https://lobste.rs/s/\(id)")!
        case .substack(let host, let slug): URL(string: "https://\(host)/p/\(slug)/comments")!
        }
    }

    /// A stable name for files kept about this discussion.
    public var key: String {
        switch self {
        case .hackerNews(let id): "hacker-news-\(id)"
        case .lobsters(let id): "lobsters-\(id)"
        case .substack(let host, let slug): "substack-\(host)-\(slug)"
        }
    }

    /// Long threads run to megabytes.
    static let sizeLimit = 32 * 1024 * 1024

    public func discussion(using downloader: ArticleDownloader) async throws -> Discussion {
        switch self {
        case .hackerNews(let id):
            // Algolia sends the whole thread at once; HN's own API gives the order it ranks the top comments in.
            async let thread = downloader.json(at: URL(string: "https://hn.algolia.com/api/v1/items/\(id)")!, limit: Self.sizeLimit)
            async let ranking = try? downloader.json(at: URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!)
            return try Self.hackerNewsDiscussion(from: await thread, ranking: await ranking, url: url)
        case .lobsters(let id):
            return try Self.lobstersDiscussion(from: await downloader.json(at: URL(string: "https://lobste.rs/s/\(id).json")!, limit: Self.sizeLimit), url: url)
        case .substack(let host, let slug):
            let post = try Self.substackPost(from: await downloader.json(at: URL(string: "https://\(host)/api/v1/posts/\(slug)")!))
            // Subscriber-only threads need the reader's session, which only Substack's own domains are sent.
            let cookie = host == "substack.com" || host.hasSuffix(".substack.com") ? SubstackAccount.session.map(SubstackAccount.cookie) : nil
            let comments = URL(string: "https://\(host)/api/v1/post/\(post.id)/comments?all_comments=true&sort=best_first")!
            return try Self.substackDiscussion(from: await downloader.json(at: comments, cookie: cookie, limit: Self.sizeLimit),
                                               points: post.reaction_count, url: url)
        }
    }

    /// `ranking` is the story from HN's own API, whose `kids` are its top comments best first.
    /// Replies keep Algolia's order, oldest first, so they read as a conversation.
    static func hackerNewsDiscussion(from data: Data, ranking: Data?, url: URL, fetchedAt: Date = .now) throws -> Discussion {
        final class Item: Decodable {
            let id: Int
            let author: String?
            let created_at_i: TimeInterval?
            let text: String?
            let points: Int?
            let children: [Item]?
        }
        struct Ranking: Decodable { let kids: [Int]? }
        func comment(_ item: Item) -> Discussion.Comment? {
            let replies = (item.children ?? []).compactMap(comment)
            // Deleted and flagged comments come back without an author or text.
            if item.author == nil && item.text == nil && replies.isEmpty { return nil }
            return Discussion.Comment(id: String(item.id), author: item.author, postedAt: item.created_at_i.map(Date.init(timeIntervalSince1970:)),
                                      html: item.text.map { "<p>" + $0 } ?? "", replies: replies)
        }
        let story = try JSONDecoder().decode(Item.self, from: data)
        var comments = (story.children ?? []).compactMap(comment)
        if let kids = ranking.flatMap({ try? JSONDecoder().decode(Ranking.self, from: $0) })?.kids {
            let rank = Dictionary(kids.enumerated().map { (String($1), $0) }, uniquingKeysWith: { first, _ in first })
            comments = comments.enumerated().sorted { a, b in
                (rank[a.element.id] ?? kids.count + a.offset) < (rank[b.element.id] ?? kids.count + b.offset)
            }.map(\.element)
        }
        return Discussion(url: url, points: story.points, comments: comments, fetchedAt: fetchedAt)
    }

    /// Lobsters lists a story's comments in thread order, each with its depth.
    static func lobstersDiscussion(from data: Data, url: URL, fetchedAt: Date = .now) throws -> Discussion {
        struct Story: Decodable {
            let score: Int?
            let comments: [Comment]?
        }
        struct Comment: Decodable {
            let short_id: String
            let created_at: String?
            let is_deleted: Bool?
            let is_moderated: Bool?
            let comment: String?
            let depth: Int
            let commenting_user: String?
        }
        let story = try JSONDecoder().decode(Story.self, from: data)
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Each open thread, from the top comment down to the one last added.
        var open: [Discussion.Comment] = []
        var comments: [Discussion.Comment] = []
        func close(to depth: Int) {
            while open.count > depth {
                let finished = open.removeLast()
                // A removed comment only stays to hold its replies.
                if finished.author == nil && finished.replies.isEmpty { continue }
                if open.isEmpty { comments.append(finished) } else { open[open.count - 1].replies.append(finished) }
            }
        }
        for item in story.comments ?? [] {
            close(to: min(item.depth, open.count))
            let removed = item.is_deleted == true || item.is_moderated == true
            open.append(Discussion.Comment(id: item.short_id, author: removed ? nil : item.commenting_user,
                                           postedAt: item.created_at.flatMap { dates.date(from: $0) },
                                           html: removed ? "" : item.comment ?? "", replies: []))
        }
        close(to: 0)
        return Discussion(url: url, points: story.score, comments: comments, fetchedAt: fetchedAt)
    }

    struct SubstackPost: Decodable {
        let id: Int
        let comment_count: Int?
        let reaction_count: Int?
    }

    static func substackPost(from data: Data) throws -> SubstackPost {
        try JSONDecoder().decode(SubstackPost.self, from: data)
    }

    /// Substack sends comments as plain text, already threaded, best first.
    static func substackDiscussion(from data: Data, points: Int?, url: URL, fetchedAt: Date = .now) throws -> Discussion {
        final class Comment: Decodable {
            let id: Int
            let name: String?
            let body: String?
            let date: String?
            let deleted: Bool?
            let children: [Comment]?
        }
        struct Page: Decodable { let comments: [Comment] }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func comment(_ item: Comment) -> Discussion.Comment? {
            let replies = (item.children ?? []).compactMap(comment)
            let removed = item.deleted == true || item.body == nil
            if removed && replies.isEmpty { return nil }
            return Discussion.Comment(id: String(item.id), author: removed ? nil : item.name, postedAt: item.date.flatMap { dates.date(from: $0) },
                                      html: removed ? "" : Discussion.html(fromText: item.body ?? ""), replies: replies)
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        return Discussion(url: url, points: points, comments: page.comments.compactMap(comment), fetchedAt: fetchedAt)
    }

    /// Where `article` is discussed, among the sites that can be asked. Lookups that fail are left out.
    public static func discussions(of article: URL, using downloader: ArticleDownloader) async -> [DiscussionSite] {
        async let hackerNews = try? hackerNewsDiscussion(of: article, using: downloader)
        async let lobsters = try? lobstersDiscussion(of: article, using: downloader)
        async let substack = try? substackDiscussion(of: article, using: downloader)
        return await [hackerNews, lobsters, substack].compactMap { $0 ?? nil }
    }

    private static func hackerNewsDiscussion(of article: URL, using downloader: ArticleDownloader) async throws -> DiscussionSite? {
        var search = URLComponents(string: "https://hn.algolia.com/api/v1/search")!
        search.queryItems = [URLQueryItem(name: "query", value: article.absoluteString),
                             URLQueryItem(name: "restrictSearchableAttributes", value: "url"), URLQueryItem(name: "tags", value: "story")]
        return try hackerNewsMatch(for: article, in: await downloader.json(at: search.url!))
    }

    /// The most discussed submission of `article` among search hits, since the search also matches longer URLs.
    static func hackerNewsMatch(for article: URL, in data: Data) throws -> DiscussionSite? {
        struct Hit: Decodable {
            let objectID: String
            let url: String?
            let num_comments: Int?
        }
        struct Results: Decodable { let hits: [Hit] }
        let key = matchKey(article)
        let best = try JSONDecoder().decode(Results.self, from: data).hits
            .filter { ($0.num_comments ?? 0) > 0 && $0.url.flatMap(URL.init(string:)).map(matchKey) == key }
            .max { ($0.num_comments ?? 0) < ($1.num_comments ?? 0) }
        return best.flatMap { Int($0.objectID) }.map { .hackerNews(id: $0) }
    }

    private static func lobstersDiscussion(of article: URL, using downloader: ArticleDownloader) async throws -> DiscussionSite? {
        var lookup = URLComponents(string: "https://lobste.rs/stories/url/all.json")!
        lookup.queryItems = [URLQueryItem(name: "url", value: article.absoluteString)]
        return try lobstersMatch(in: await downloader.json(at: lookup.url!))
    }

    static func lobstersMatch(in data: Data) throws -> DiscussionSite? {
        struct Story: Decodable {
            let short_id: String
            let comment_count: Int?
        }
        let best = try JSONDecoder().decode([Story].self, from: data).filter { ($0.comment_count ?? 0) > 0 }
            .max { ($0.comment_count ?? 0) < ($1.comment_count ?? 0) }
        return best.map { .lobsters(id: $0.short_id) }
    }

    /// A Substack post's own comments; any site with a `/p/` path is asked, since publications use their own domains.
    private static func substackDiscussion(of article: URL, using downloader: ArticleDownloader) async throws -> DiscussionSite? {
        let path = article.pathComponents.filter { $0 != "/" }
        guard path.count == 2, path[0] == "p", let host = article.host()?.lowercased() else { return nil }
        let post = try substackPost(from: await downloader.json(at: URL(string: "https://\(host)/api/v1/posts/\(path[1])")!))
        return (post.comment_count ?? 0) > 0 ? .substack(host: host, slug: path[1]) : nil
    }

    /// A URL as sites tell submissions apart: without its scheme, `www.`, or a trailing slash.
    static func matchKey(_ url: URL) -> String {
        var host = url.host()?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path + (url.query().map { "?" + $0 } ?? "")
    }
}

extension Discussion {
    /// Plain text as paragraphs, with its web addresses linked.
    static func html(fromText text: String) -> String {
        let links = #/https?://[^\s<>"]+[^\s<>".,;:!?)\]'"]/#
        return text.components(separatedBy: "\n\n").map { paragraph in
            var html = ""
            var rest = Substring(paragraph)
            while let match = rest.firstMatch(of: links) {
                html += ArticleHTML.escape(String(rest[..<match.range.lowerBound]))
                let link = ArticleHTML.escape(String(match.output))
                html += "<a href=\"\(link)\">\(link)</a>"
                rest = rest[match.range.upperBound...]
            }
            html += ArticleHTML.escape(String(rest))
            return "<p>" + html.replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        }.joined()
    }

    /// A page of the comments, each thread collapsible, for reading offline.
    public func html(site: DiscussionSite, title: String, now: Date = .now) -> String {
        let times = RelativeDateTimeFormatter()
        times.unitsStyle = .abbreviated
        func render(_ comment: Comment) -> String {
            let meta = [comment.postedAt.map { times.localizedString(for: $0, relativeTo: now) },
                        comment.replies.isEmpty ? nil : "\(comment.threadCount - 1) \(comment.threadCount == 2 ? "reply" : "replies")"]
                .compactMap { $0 }.map { "<span>· \(ArticleHTML.escape($0))</span>" }.joined(separator: " ")
            let author = comment.author.map { "<b>\(ArticleHTML.escape($0))</b>" } ?? "<i>deleted</i>"
            return "<details open><summary>\(author) \(meta)</summary><div class=\"text\">\(comment.html)</div>"
                + comment.replies.map(render).joined() + "</details>"
        }
        let byline = [points.map { "\($0) \(site.pointName)\($0 == 1 ? "" : "s")" }, "\(count) \(count == 1 ? "comment" : "comments")"]
            .compactMap { $0 }.joined(separator: " · ")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: light dark; --paper:#fff; --ink:#282d28; --muted:#797e74; --accent:#4c6450; }
        @media(prefers-color-scheme:dark) { :root { --paper:#000; --ink:#e5e8df; --muted:#a0a89b; --accent:#b6cda8; } }
        * { box-sizing:border-box } html { background:var(--paper); overflow-wrap:anywhere; }
        body { max-width:740px; margin:0 auto; padding:28px 24px 80px; color:var(--ink); font:15px/1.6 -apple-system,sans-serif; }
        header { margin-bottom:22px; } .source { font-size:11px; font-weight:600; letter-spacing:2px; color:var(--accent); }
        h1 { font:normal 1.5em/1.25 Georgia,serif; margin:10px 0 6px; } .byline { color:var(--muted); font-size:13px; }
        details { margin-top:14px; } details details { margin-left:4px; padding-left:14px; border-left:2px solid color-mix(in srgb,var(--muted) 22%,transparent); }
        summary { list-style:none; cursor:pointer; font-size:13px; color:var(--muted); } summary::-webkit-details-marker { display:none; }
        summary b { color:var(--ink); font-weight:600; } details:not([open]) > summary::after { content:" ⋯"; }
        .text p { margin:0.5em 0; } a { color:var(--accent); text-underline-offset:3px; } img { display:none; }
        pre { overflow:auto; padding:10px; background:color-mix(in srgb,var(--muted) 10%,transparent); border-radius:5px; } code { font:0.9em ui-monospace,monospace; }
        blockquote { margin:0.5em 0; padding-left:12px; border-left:3px solid color-mix(in srgb,var(--muted) 40%,transparent); color:var(--muted); }
        .empty { color:var(--muted); }
        </style></head><body><header><div class="source">\(ArticleHTML.escape(site.name.uppercased()))</div>
        <h1>\(ArticleHTML.escape(title))</h1><div class="byline">\(ArticleHTML.escape(byline))</div></header>
        \(comments.isEmpty ? "<p class=\"empty\">No comments yet.</p>" : comments.map(render).joined())
        </body></html>
        """
    }
}
