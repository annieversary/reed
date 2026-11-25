import Foundation
import SwiftData

public enum DownloadState: String, Codable, Sendable {
    case queued, downloading, ready, partial, failed

    public var isReadable: Bool { self == .ready || self == .partial }

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Saving article…"
        case .ready: "Available offline"
        case .partial: "Text saved · some images missing"
        case .failed: "Couldn't save"
        }
    }
}

/// Where saving an article has got. Each case holds only what means something in it; whether a copy is already
/// saved, to read while it's saved again, is told by the article's `contentVersion`.
public enum SaveState: Equatable, Sendable {
    /// Waiting its turn. `failures` counts the saves in a row that failed in a way that may pass, besides being offline,
    /// so the next failure waits longer.
    case queued(failures: Int)
    /// Waiting until `until` to be tried again after a save that may yet work, `reason` saying why.
    case waiting(until: Date, failures: Int, reason: String)
    case downloading(failures: Int)
    /// Saved, with any images that couldn't be counted in the article's `missingImageCount`.
    case saved
    case failed(reason: String)

    /// Why it's waiting or failed.
    public var reason: String? {
        switch self {
        case .waiting(_, _, let reason), .failed(let reason): reason
        case .queued, .downloading, .saved: nil
        }
    }

    var failures: Int {
        switch self {
        case .queued(let failures), .waiting(_, let failures, _), .downloading(let failures): failures
        case .saved, .failed: 0
        }
    }
}

/// Where an article stands with the library.
public enum Membership: Equatable, Sendable {
    /// In the library, and whether it's a favorite.
    case saved(favorite: Bool)
    /// Downloaded ahead to read offline, such as from a front page or feed, but not saved to the library. The cache
    /// keeps it while it's wanted there or open.
    case cached
    /// Gone from the library and the cache, to be erased once its download settles.
    case discarded

    public var isSaved: Bool { if case .saved = self { true } else { false } }
}

@Model
public final class Article {
    @Attribute(.unique) public var id: UUID
    public var originalURL: String
    public var resolvedURL: String?
    public var title: String
    public var author: String?
    public var excerpt: String
    public var savedAt: Date
    public var publishedAt: Date?
    public var downloadedAt: Date?
    // `saveState`, kept as columns.
    private var stateRaw: String
    private var failureMessage: String?
    public var wordCount: Int
    public var imageCount: Int
    public var missingImageCount: Int
    public var progress: Double
    public var isRead: Bool
    // `membership`, kept as columns.
    @Attribute(originalName: "isFavorite") private var isFavoriteColumn: Bool
    public var contentVersion: String?
    /// Whether pictures in the saved version were left for the on-device model to describe once Reed is open.
    public var imagesUndescribed: Bool = false
    /// The passage narration last reached, to resume from.
    public var narrationPassage: Int?
    /// The start of that passage, to find it again if the passages are numbered differently.
    public var narrationAnchor: String?
    @Attribute(originalName: "isCached") private var isCachedColumn: Bool = false
    private var isDiscarded: Bool = false
    /// Whether the page links to chapters either side of it; nil if it was saved before that was looked for.
    public var leadsToOtherChapters: Bool?
    /// Where the link is discussed, such as its Hacker News thread, in the order they were found.
    public var discussionURLs: [String]?
    /// When it was first opened in the reader, whether or not it was read any further.
    public var openedAt: Date?
    private var retryAt: Date?
    private var failedAttempts: Int = 0

    public var isWaitingToRetry: Bool { if case .waiting = saveState { true } else { false } }

    public init(url: URL, id: UUID = UUID()) {
        self.id = id
        originalURL = url.absoluteString
        title = url.host() ?? url.absoluteString
        excerpt = ""
        savedAt = .now
        stateRaw = DownloadState.queued.rawValue
        wordCount = 0
        imageCount = 0
        missingImageCount = 0
        progress = 0
        isRead = false
        isFavoriteColumn = false
        narrationPassage = nil
    }

    public var saveState: SaveState {
        get {
            switch DownloadState(rawValue: stateRaw) {
            case .queued: retryAt.map { .waiting(until: $0, failures: failedAttempts, reason: failureMessage ?? "") } ?? .queued(failures: failedAttempts)
            case .downloading: .downloading(failures: failedAttempts)
            case .ready, .partial: .saved
            case .failed, nil: .failed(reason: failureMessage ?? "")
            }
        }
        set {
            stateRaw = switch newValue {
            case .queued, .waiting: DownloadState.queued.rawValue
            case .downloading: DownloadState.downloading.rawValue
            case .saved: DownloadState.ready.rawValue
            case .failed: DownloadState.failed.rawValue
            }
            if case .waiting(let until, _, _) = newValue { retryAt = until } else { retryAt = nil }
            failureMessage = newValue.reason
            failedAttempts = newValue.failures
        }
    }

    public var membership: Membership {
        get { isDiscarded ? .discarded : isCachedColumn ? .cached : .saved(favorite: isFavoriteColumn) }
        set {
            isDiscarded = newValue == .discarded
            isCachedColumn = newValue == .cached
            isFavoriteColumn = newValue == .saved(favorite: true)
        }
    }

    public var isFavorite: Bool { membership == .saved(favorite: true) }
    public var isCached: Bool { membership == .cached }

    /// `saveState` in brief, a saved copy being partial when images are missing from it.
    public var state: DownloadState {
        switch saveState {
        case .queued, .waiting: .queued
        case .downloading: .downloading
        case .saved: missingImageCount > 0 ? .partial : .ready
        case .failed: .failed
        }
    }

    /// Where the article can be found on the web; nil for a file shared to Reed.
    public var sourceURL: URL? { isFile ? nil : URL(string: resolvedURL ?? originalURL) }
    public var discussionSites: [DiscussionSite] { (discussionURLs ?? []).compactMap { URL(string: $0).flatMap(DiscussionSite.init(url:)) } }
    public var domain: String { URL(string: resolvedURL ?? originalURL).flatMap(Self.domain(of:)) ?? originalURL }
    public static func domain(of url: URL) -> String? {
        if url.scheme == fileScheme { return "PDF" }
        guard let host = url.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    /// Whether finding the chapters around this one is worth offering. Articles saved before chapter links were
    /// looked for are guessed at from their titles.
    public var mayHaveOtherChapters: Bool {
        sourceURL != nil && (leadsToOtherChapters ?? (SeriesTitle.partNumber(in: title) != nil))
    }
    public var readingMinutes: Int { Self.readingMinutes(words: wordCount) }

    /// How long reading `words` takes, at about 230 words a minute.
    public static func readingMinutes(words: Int) -> Int { max(1, Int(ceil(Double(words) / 230))) }

    /// Files shared to Reed are known by their contents, so sharing one twice saves it once.
    static let fileScheme = "reed-file"
    public var isFile: Bool { originalURL.hasPrefix(Self.fileScheme + ":") }
    static func fileURL(digest: String, name: String) -> URL {
        var components = URLComponents()
        components.scheme = fileScheme
        components.path = "/\(digest)/\(name.replacingOccurrences(of: "/", with: "-"))"
        return components.url!
    }
}

public enum ReedError: LocalizedError {
    case invalidURL, unsupportedContent, emptyArticle, oversizedDownload, httpStatus(Int), extractionTimeout
    case damagedArticle, noFeed, unreadableFeed, substackSignedOut, noTranscript, unavailableVideo(reason: String?)
    case unreadableBook, protectedBook
    case unreadablePDF, pdfNeedsNewerSystem

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid http or https article URL."
        case .unsupportedContent: "This link isn't an HTML article or a PDF."
        case .emptyArticle: "No readable article was found. The page may need a login or JavaScript."
        case .oversizedDownload: "This page or image exceeds the download size limit."
        case .httpStatus(let code): "The website returned an error (HTTP \(code)). Try opening the original link."
        case .extractionTimeout: "Article extraction took too long. Please try again."
        case .damagedArticle: "The saved article files are missing. Retry to download them again."
        case .noFeed: "No feed was found at this address."
        case .unreadableFeed: "The feed couldn't be read."
        case .substackSignedOut: "Sign in to Substack in Settings to see the posts it picks for you."
        case .noTranscript: "This video has no captions to make a transcript from."
        case .unavailableVideo(let reason): "YouTube won't play this video" + (reason.map { ": \($0)" } ?? ".")
        case .unreadableBook: "This file isn't an EPUB that Reed can read."
        case .protectedBook: "This book is locked to the store it was bought from, so only that store's app can open it."
        case .unreadablePDF: "This PDF couldn't be read. It may be damaged or password-protected."
        case .pdfNeedsNewerSystem: "Saving PDFs needs macOS 26 or iOS 26."
        }
    }
}

public enum ArticleURL {
    /// The links in pasted or typed text, in order and each once, to save one by one. Full links are picked out
    /// of any words around them; otherwise each word is taken as a link if they all look like addresses, and
    /// the text is given back whole if not, so saving it says why it isn't a link.
    public static func links(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var links: [String] = []
        func keep(_ link: String) { if !links.contains(link) { links.append(link) } }
        if trimmed.contains("://"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                guard let scheme = match.url?.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      let found = Range(match.range, in: trimmed) else { continue }
                keep(String(trimmed[found]))
            }
            if !links.isEmpty { return links }
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.allSatisfy({ $0.contains(".") }) else { return [trimmed] }
        words.forEach(keep)
        return links
    }

    public static func parse(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { throw ReedError.invalidURL }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { throw ReedError.invalidURL }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        guard let url = components.url else { throw ReedError.invalidURL }
        // A video's many links all save as the one.
        return YouTube.videoID(in: url).map { YouTube.watchURL($0) } ?? url
    }

    /// `url` without the parameters that only track where it was shared or clicked from, to pass on.
    public static func shareable(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = components.queryItems else { return url }
        let host = components.host?.lowercased() ?? ""
        func on(_ site: String) -> Bool { host == site || host.hasSuffix("." + site) }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            if name.hasPrefix("utm_") || trackingParameters.contains(name) { return false }
            // Names other sites may well use for something else.
            switch name {
            case "si": return !(on("youtube.com") || on("youtu.be") || on("spotify.com"))
            case "s", "t": return !(on("twitter.com") || on("x.com"))
            case "r", "triedredirect": return !on("substack.com")
            case "source": return !on("medium.com")
            case "feature", "pp": return !on("youtube.com")
            default: return true
            }
        }
        guard kept.count != items.count else { return url }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "twclid", "ttclid", "li_fat_id", "yclid",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "hsctatracking", "mkt_tok", "igshid", "igsh", "ref_src", "ref_url",
        "oly_anon_id", "oly_enc_id", "vero_id", "wickedid", "rb_clickid", "_ga", "_gl", "cmpid", "share_id",
    ]
}
