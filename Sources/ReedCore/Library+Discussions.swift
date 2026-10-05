import Foundation
import SwiftData

/// The places an article is discussed, and the comments last fetched from each.
extension Library {
    /// Adds where the article is discussed, unsaved, if it isn't known already.
    func note(_ discussion: URL?, of article: Article) {
        guard let discussion, let site = DiscussionSite(url: discussion), !article.discussionSites.contains(site) else { return }
        article.discussionURLs = (article.discussionURLs ?? []) + [site.url.absoluteString]
    }

    /// Asks other sites whether they discuss the article. This tells them its address, so it's only done when asked for.
    public func findDiscussions(of article: Article) async {
        guard let url = article.sourceURL else { return }
        let found = await DiscussionSite.discussions(of: url, using: downloader)
        for site in found { note(site.url, of: article) }
        save()
    }

    /// The comments last fetched from `site`, if any.
    public func discussion(_ site: DiscussionSite, of article: Article) -> Discussion? {
        guard let data = try? Data(contentsOf: storage.discussionURL(article.id, site: site)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Discussion.self, from: data)
    }

    /// Fetches the comments from `site` again, keeping them to read offline.
    public func refreshDiscussion(_ site: DiscussionSite, of article: Article) async throws -> Discussion {
        let discussion = try await site.discussion(using: downloader)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = storage.discussionURL(article.id, site: site)
        // Failing to keep a copy only costs reading them offline.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(discussion).write(to: url, options: .atomic)
        return discussion
    }
}
