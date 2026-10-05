import Foundation

/// A site whose current links can be browsed and saved into the library.
public enum ExternalSource: String, CaseIterable, Identifiable, Sendable {
    case hackerNews = "Hacker News", lobsters = "Lobste.rs"
    /// The posts Substack picks for the signed-in reader.
    case substack = "Substack"
    public var id: Self { self }

    /// A stable name for files kept about this source.
    var key: String {
        switch self {
        case .hackerNews: "hacker-news"
        case .lobsters: "lobsters"
        case .substack: "substack"
        }
    }

    /// The front page, in the site's own order.
    public func frontPage(using downloader: ArticleDownloader) async throws -> [SourceItem] {
        switch self {
        case .hackerNews:
            let ids = try JSONDecoder().decode([Int].self, from: await downloader.json(at: URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json")!))
            let front = Array(ids.prefix(30))
            let items = await withTaskGroup(of: (Int, SourceItem?).self) { group in
                for (rank, id) in front.enumerated() {
                    group.addTask {
                        let data = try? await downloader.json(at: URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!)
                        return (rank, data.flatMap { try? Self.hackerNewsItem(from: $0) })
                    }
                }
                var ranked: [(Int, SourceItem)] = []
                for await (rank, item) in group { if let item { ranked.append((rank, item)) } }
                return ranked.sorted { $0.0 < $1.0 }.map(\.1)
            }
            // One story failing is tolerable; all of them means the site is unreachable.
            if items.isEmpty && !front.isEmpty { throw ReedError.unsupportedContent }
            return items
        case .lobsters:
            return try Self.lobstersItems(from: await downloader.json(at: URL(string: "https://lobste.rs/hottest.json")!))
        case .substack:
            return try await Self.substackItems(using: downloader)
        }
    }

    static func hackerNewsItem(from data: Data) throws -> SourceItem? {
        struct Item: Decodable {
            let id: Int
            let type: String?
            let title: String?
            let url: String?
            let by: String?
            let score: Int?
            let descendants: Int?
            let time: TimeInterval?
            let dead: Bool?
            let deleted: Bool?
        }
        let item = try JSONDecoder().decode(Item.self, from: data)
        guard item.dead != true, item.deleted != true, let title = item.title,
              let discussion = URL(string: "https://news.ycombinator.com/item?id=\(item.id)") else { return nil }
        // Ask HN and other text posts have no link of their own; their discussion is the story.
        let link = item.url.flatMap { try? ArticleURL.parse($0) } ?? discussion
        return SourceItem(id: String(item.id), title: title, url: link, discussionURL: discussion, author: item.by,
                          points: item.score, comments: item.descendants, postedAt: item.time.map(Date.init(timeIntervalSince1970:)))
    }

    static func lobstersItems(from data: Data) throws -> [SourceItem] {
        struct Story: Decodable {
            let short_id: String
            let title: String
            let url: String
            let score: Int?
            let comment_count: Int?
            let submitter_user: String?
            let created_at: String?
            let comments_url: String
        }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONDecoder().decode([Story].self, from: data).compactMap { story in
            guard let discussion = try? ArticleURL.parse(story.comments_url) else { return nil }
            let link = (try? ArticleURL.parse(story.url)) ?? discussion
            return SourceItem(id: story.short_id, title: story.title, url: link, discussionURL: discussion, author: story.submitter_user,
                              points: story.score, comments: story.comment_count, postedAt: story.created_at.flatMap(dates.date(from:)))
        }
    }
}

public struct FrontPage: Codable, Sendable {
    public let items: [SourceItem]
    public let fetchedAt: Date
}

/// Why a link was picked for the reader.
public enum SourceReason: Hashable, Codable, Sendable {
    case restacked(by: String), liked(by: String), fromArchives
    /// Shared in a note, with what its author said about it.
    case note(author: String, text: String)
}

public struct SourceItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    /// Where the link is discussed, for sites that host discussions.
    public let discussionURL: URL?
    public let author: String?
    public let points: Int?
    public let comments: Int?
    public let postedAt: Date?
    /// The subscribed feed it came from, if any.
    public var feedID: UUID? = nil
    public var excerpt: String? = nil
    /// The publication it appeared in, for sources that name one.
    public var site: String? = nil
    /// Why the source picked it for the reader.
    public var reason: SourceReason? = nil
    /// Only paying subscribers can read all of it.
    public var paid: Bool? = nil
    public var wordCount: Int? = nil

    public var domain: String {
        let host = url.host() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
