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
    public var stateRaw: String
    public var failureMessage: String?
    public var wordCount: Int
    public var imageCount: Int
    public var missingImageCount: Int
    public var progress: Double
    public var isRead: Bool
    public var isFavorite: Bool
    public var contentVersion: String?
    /// The passage narration last reached, to resume from.
    public var narrationPassage: Int?
    /// Downloaded ahead from a front page or feed so it can be read offline, but not saved to the library.
    public var isCached: Bool = false
    /// Whether the page links to chapters either side of it; nil if it was saved before that was looked for.
    public var leadsToOtherChapters: Bool?

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
        isFavorite = false
        narrationPassage = nil
    }

    public var state: DownloadState {
        get { DownloadState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    /// Where the article can be found on the web; nil for a file shared to Reed.
    public var sourceURL: URL? { isFile ? nil : URL(string: resolvedURL ?? originalURL) }
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
    public var readingMinutes: Int { max(1, Int(ceil(Double(wordCount) / 230))) }

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
        case .unreadablePDF: "This PDF couldn't be read. It may be damaged or password-protected."
        case .pdfNeedsNewerSystem: "Saving PDFs needs macOS 26 or iOS 26."
        }
    }
}

public enum ArticleURL {
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
}
