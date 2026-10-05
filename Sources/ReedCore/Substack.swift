import Foundation
import Observation
import Security

/// The reader's Substack sign-in, which their For You feed needs. Only the session cookie is kept, in the keychain.
@MainActor @Observable
public final class SubstackAccount {
    public static let shared = SubstackAccount()
    public private(set) var isSignedIn: Bool

    private init() { isSignedIn = Self.session != nil }

    public func signIn(session: String) {
        Self.deleteSession()
        let item = Self.keychainQuery.merging([
            kSecValueData as String: Data(session.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { $1 }
        isSignedIn = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func signOut() {
        Self.deleteSession()
        isSignedIn = false
    }

    /// The value of the `substack.sid` cookie.
    nonisolated static var session: String? {
        let query = keychainQuery.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether `session` is signed in, rather than a visitor's.
    public nonisolated static func isSignedIn(session: String, using downloader: ArticleDownloader = ArticleDownloader()) async throws -> Bool {
        struct Status: Decodable { let loggedIn: Bool }
        let data = try await downloader.json(at: URL(string: "https://substack.com/api/v1/am_i_logged_in")!, cookie: cookie(session))
        return try JSONDecoder().decode(Status.self, from: data).loggedIn
    }

    nonisolated static func cookie(_ session: String) -> String { "substack.sid=" + session }

    private nonisolated static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "town.versary.reed.substack",
         kSecAttrAccount as String: "substack.sid"]
    }

    private nonisolated static func deleteSession() { SecItemDelete(keychainQuery as CFDictionary) }
}

extension ExternalSource {
    /// Enough posts for a front page; most of the feed is notes, so this takes several pages of it.
    static let substackPostCount = 30

    static func substackItems(using downloader: ArticleDownloader) async throws -> [SourceItem] {
        guard let session = SubstackAccount.session,
              try await SubstackAccount.isSignedIn(session: session, using: downloader) else { throw ReedError.substackSignedOut }
        var items: [SourceItem] = []
        var cursor: String?
        for _ in 0..<8 {
            // Cursors are base64, whose "+" would otherwise arrive as a space.
            let query = cursor.map { "&cursor=" + $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! } ?? ""
            let url = URL(string: "https://substack.com/api/v1/reader/feed?tab=for-you&type=base" + query)!
            let page = try substackPage(from: await downloader.json(at: url, cookie: SubstackAccount.cookie(session)))
            for item in page.items where !items.contains(where: { $0.url == item.url }) { items.append(item) }
            cursor = page.nextCursor
            if cursor == nil || items.count >= substackPostCount { break }
        }
        return items
    }

    /// The posts in a page of the reader's feed, both those it recommends and those shared in its notes.
    static func substackPage(from data: Data) throws -> (items: [SourceItem], nextCursor: String?) {
        struct Page: Decodable {
            let items: [Lossy<Entry>]
            let nextCursor: String?
        }
        struct Entry: Decodable {
            let type: String
            let context: Context?
            let publication: Publication?
            let post: Post?
            let comment: Comment?
        }
        struct Context: Decodable {
            let type: String?
            let users: [Person]?
        }
        struct Comment: Decodable {
            let name: String?
            let body: String?
            let attachments: [Lossy<Attachment>]?
        }
        struct Attachment: Decodable {
            let type: String?
            let post: Post?
            let publication: Publication?
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let items = page.items.compactMap(\.value).compactMap { entry -> SourceItem? in
            switch entry.type {
            case "post":
                guard let post = entry.post else { return nil }
                let by = entry.context?.users?.first?.name
                let reason: SourceReason? = switch entry.context?.type {
                case "post_restack": by.map { .restacked(by: $0) }
                case "post_like": by.map { .liked(by: $0) }
                case "from_archives": .fromArchives
                default: nil
                }
                return substackItem(post, publication: entry.publication, reason: reason)
            case "comment":
                guard let comment = entry.comment,
                      let shared = comment.attachments?.compactMap(\.value).first(where: { $0.type == "post" }),
                      let post = shared.post else { return nil }
                let text = comment.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let reason = comment.name.flatMap { text.isEmpty ? nil : SourceReason.note(author: $0, text: text) }
                return substackItem(post, publication: shared.publication, reason: reason)
            default:
                return nil
            }
        }
        return (items, page.nextCursor)
    }

    private struct Post: Decodable {
        let id: Int?
        let title: String?
        let subtitle: String?
        let canonical_url: String?
        let post_date: String?
        let audience: String?
        let wordcount: Int?
        let reaction_count: Int?
        let comment_count: Int?
        let publishedBylines: [Person]?
    }
    private struct Publication: Decodable { let name: String? }
    private struct Person: Decodable { let name: String? }

    private static func substackItem(_ post: Post, publication: Publication?, reason: SourceReason?) -> SourceItem? {
        guard let id = post.id, let title = post.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let link = post.canonical_url.flatMap({ try? ArticleURL.parse($0) }) else { return nil }
        let site = publication?.name
        // A publication's own name sometimes appears among its bylines, such as "Works in Progress" for "The Works in Progress Newsletter".
        let authors = (post.publishedBylines ?? []).compactMap(\.name).filter { !(site ?? "").localizedCaseInsensitiveContains($0) }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var item = SourceItem(id: String(id), title: title, url: link, discussionURL: link.appending(path: "comments"),
                              author: authors.isEmpty ? nil : authors.joined(separator: ", "),
                              points: post.reaction_count, comments: post.comment_count,
                              postedAt: post.post_date.flatMap { dates.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) })
        // Some subtitles are only an ellipsis.
        let subtitle = post.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        item.excerpt = subtitle?.contains(where: { $0.isLetter || $0.isNumber }) == true ? subtitle : nil
        item.site = site
        item.reason = reason
        item.paid = ["only_paid", "founding"].contains(post.audience ?? "") ? true : nil
        item.wordCount = post.wordcount
        return item
    }
}

/// A value that is dropped, rather than failing everything around it, when it doesn't decode.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
