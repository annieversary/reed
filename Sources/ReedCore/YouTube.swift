import Foundation

/// YouTube videos, saved as their captions set out as an article.
public enum YouTube {
    /// The eleven-character id of the video `url` plays, from any of the links YouTube gives out.
    public static func videoID(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var host = components.host?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let parts = components.path.split(separator: "/").map(String.init)
        let id: String? = switch host {
        case "youtu.be": parts.first
        case "youtube.com", "youtube-nocookie.com":
            if parts == ["watch"] { components.queryItems?.first { $0.name == "v" }?.value }
            else if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0]) { parts[1] }
            else { nil }
        default: nil
        }
        guard let id, id.wholeMatch(of: #/[A-Za-z0-9_-]{11}/#) != nil else { return nil }
        return id
    }

    public static func watchURL(_ id: String, at seconds: Int? = nil) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)" + (seconds.map { "&t=\($0)s" } ?? ""))!
    }

    /// The video's captions as an article, in the first of `languages` it has captions in.
    static func transcript(of id: String, languages: [String] = preferredLanguages,
                           using downloader: ArticleDownloader) async throws -> ExtractedArticle {
        async let published = publishedAt(of: id, using: downloader)
        let video = try video(from: await downloader.json(posting: playerRequest(id), to: playerURL, userAgent: client.userAgent))
        guard let track = track(among: video.tracks, languages: languages), var captionsURL = URLComponents(string: track.baseUrl) else {
            throw ReedError.noTranscript
        }
        captionsURL.queryItems = (captionsURL.queryItems ?? []).filter { $0.name != "fmt" } + [URLQueryItem(name: "fmt", value: "json3")]
        guard let url = captionsURL.url else { throw ReedError.noTranscript }
        let words = try words(from: await downloader.resource(at: url))
        guard !words.isEmpty else { throw ReedError.noTranscript }
        var images: [ExtractedArticle.Image] = []
        if let thumbnail = video.thumbnail, let link = URL(string: thumbnail) {
            let ext = link.pathExtension.isEmpty ? "jpg" : link.pathExtension
            images.append(.init(url: thumbnail, filename: "thumbnail." + ext, alt: video.title))
        }
        return ExtractedArticle(title: video.title, author: video.author, publishedAt: await published,
                                excerpt: excerpt(of: video.description),
                                html: html(id: id, words: words, chapters: chapters(in: video.description), thumbnail: images.first?.filename),
                                wordCount: words.count, images: images, page: PageLinks(title: video.title, links: []))
    }

    /// The Android app's client, whose caption links work without the proof-of-origin token the website's now need.
    private static let client = (name: "ANDROID", version: "20.10.38", userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14)")
    private static let playerURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!

    private static func playerRequest(_ id: String) -> Data {
        let body: [String: Any] = [
            "context": ["client": ["clientName": client.name, "clientVersion": client.version, "hl": "en"]],
            "videoId": id, "contentCheckOk": true, "racyCheckOk": true
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    static var preferredLanguages: [String] {
        (Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier } + ["en"])
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    struct Video {
        let title: String
        let author: String?
        let description: String
        let thumbnail: String?
        let tracks: [Track]
    }

    struct Track: Decodable {
        let baseUrl: String
        let languageCode: String
        /// "asr" for captions YouTube wrote itself.
        let kind: String?
    }

    static func video(from data: Data) throws -> Video {
        struct Response: Decodable {
            struct Status: Decodable { let status: String; let reason: String? }
            struct Details: Decodable {
                struct Thumbnails: Decodable { let thumbnails: [Thumbnail] }
                struct Thumbnail: Decodable { let url: String; let width: Int? }
                let title: String
                let author: String?
                let shortDescription: String?
                let thumbnail: Thumbnails?
            }
            struct Captions: Decodable {
                struct List: Decodable { let captionTracks: [Track]? }
                let playerCaptionsTracklistRenderer: List?
            }
            let playabilityStatus: Status
            let videoDetails: Details?
            let captions: Captions?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.playabilityStatus.status == "OK", let details = response.videoDetails else {
            throw ReedError.unavailableVideo(reason: response.playabilityStatus.reason)
        }
        return Video(title: details.title, author: details.author, description: details.shortDescription ?? "",
                     thumbnail: details.thumbnail?.thumbnails.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url,
                     tracks: response.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? [])
    }

    /// Captions a person wrote, before YouTube's own, in the first language that has either; otherwise whatever there is.
    static func track(among tracks: [Track], languages: [String]) -> Track? {
        func language(_ track: Track) -> String { String(track.languageCode.prefix { $0 != "-" }).lowercased() }
        for code in languages {
            let matching = tracks.filter { language($0) == code }
            if let track = matching.first(where: { $0.kind != "asr" }) ?? matching.first { return track }
        }
        return tracks.first { $0.kind != "asr" } ?? tracks.first
    }

    /// A spoken word, and when it's said in milliseconds.
    struct Word: Equatable {
        var text: String
        let start: Int
    }

    /// The words of a json3 caption track. Sound cues like "[Music]" are left out, and a change of speaker,
    /// written ">>", is kept as a word of its own.
    static func words(from data: Data) throws -> [Word] {
        struct Track: Decodable { let events: [Event]? }
        struct Event: Decodable { let tStartMs: Int?; let segs: [Segment]? }
        struct Segment: Decodable { let utf8: String?; let tOffsetMs: Int? }
        var words: [Word] = []
        for event in try JSONDecoder().decode(Track.self, from: data).events ?? [] {
            let start = event.tStartMs ?? 0
            // Segments split lines, and sometimes words; a word only ends at whitespace.
            var joinsLast = false
            for segment in event.segs ?? [] {
                let text = (segment.utf8 ?? "").replacing(#/\[[^\]]*\]|♪+/#, with: " ")
                var pieces = text.split(whereSeparator: \.isWhitespace).map(String.init)
                if joinsLast, text.first?.isWhitespace == false, !pieces.isEmpty, !words.isEmpty {
                    words[words.count - 1].text += pieces.removeFirst()
                }
                words += pieces.map { Word(text: $0, start: start + (segment.tOffsetMs ?? 0)) }
                joinsLast = text.last.map { !$0.isWhitespace } ?? joinsLast
            }
        }
        return words.filter { $0.text.contains { $0.isLetter || $0.isNumber } || $0.text == ">>" }
    }

    struct Chapter: Equatable {
        let start: Int
        let title: String
    }

    /// The chapters a description lists as lines starting with their times, such as "1:07 - Series preview".
    /// YouTube only takes them as chapters when the first starts the video and they run in order, and neither does this.
    static func chapters(in description: String) -> [Chapter] {
        let line = #/^\s*(?:(\d{1,3}):)?(\d{1,2}):(\d{2})\s*[-–—:|.)]?\s*(.+?)\s*$/#
        let chapters = description.split(whereSeparator: \.isNewline).compactMap { text -> Chapter? in
            guard let match = String(text).wholeMatch(of: line) else { return nil }
            let seconds = (Int(match.1 ?? "0") ?? 0) * 3600 + (Int(match.2) ?? 0) * 60 + (Int(match.3) ?? 0)
            return Chapter(start: seconds * 1000, title: String(match.4))
        }
        guard chapters.count >= 2, chapters[0].start == 0,
              zip(chapters, chapters.dropFirst()).allSatisfy({ $0.start < $1.start }) else { return [] }
        return chapters
    }

    /// The description's first paragraph, without the lines that only hold links.
    static func excerpt(of description: String) -> String {
        let first = description.components(separatedBy: "\n\n").first ?? ""
        let text = first.split(whereSeparator: \.isNewline).filter { !$0.contains("://") }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.count > 300 ? String(text.prefix(299)) + "…" : text
    }

    /// The words set out as paragraphs under each chapter's heading. A paragraph ends at a change of speaker,
    /// or at the end of a sentence once it's long enough, or wherever it's got to once it's too long, for
    /// captions written without punctuation.
    static func html(id: String, words: [Word], chapters: [Chapter], thumbnail: String?) -> String {
        var html = thumbnail.map { "<figure><img src=\"\(ArticleHTML.escape($0))\" alt=\"\"></figure>\n" } ?? ""
        var paragraph: [String] = []
        var upcoming = chapters[...]
        func endParagraph() {
            if !paragraph.isEmpty { html += "<p>\(ArticleHTML.escape(paragraph.joined(separator: " ")))</p>\n" }
            paragraph = []
        }
        for word in words {
            while let chapter = upcoming.first, word.start >= chapter.start {
                endParagraph()
                html += "<h2><a href=\"\(ArticleHTML.escape(watchURL(id, at: chapter.start / 1000).absoluteString))\">\(ArticleHTML.escape(chapter.title))</a></h2>\n"
                upcoming.removeFirst()
            }
            if word.text == ">>" { endParagraph(); continue }
            paragraph.append(word.text)
            let endsSentence = word.text.contains(#/[.!?]["'”’)]*$/#)
            if (endsSentence && paragraph.count >= 80) || paragraph.count >= 160 { endParagraph() }
        }
        endParagraph()
        return html
    }

    /// When the video was published, in milliseconds since 1970, from its page; nil if the page can't be read.
    private static func publishedAt(of id: String, using downloader: ArticleDownloader) async -> Double? {
        guard let page = try? await downloader.page(at: watchURL(id)),
              let match = page.html.firstMatch(of: #/"publishDate":"([^"]+)"/#) else { return nil }
        let text = String(match.1)
        let date = ISO8601DateFormatter().date(from: text) ?? {
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.dateFormat = "yyyy-MM-dd"
            return day.date(from: text)
        }()
        return date.map { $0.timeIntervalSince1970 * 1000 }
    }
}
