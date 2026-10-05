import Foundation

/// A page's title and links, as `PageLinks.js` reads them.
public struct PageLinks: Codable, Hashable, Sendable {
    public struct Link: Codable, Hashable, Sendable {
        public var url: String
        /// What the link says, or its label when it's drawn as an icon.
        public var text: String
        /// Its `rel`, lowercased, such as "next".
        public var rel: String

        public init(url: String, text: String, rel: String = "") {
            self.url = url
            self.text = text
            self.rel = rel
        }
    }

    public var title: String
    public var links: [Link]

    public init(title: String, links: [Link]) {
        self.title = title
        self.links = links
    }
}

/// The chapters either side of a page, and the page listing them all, as its links give them.
public struct ChapterLinks: Hashable, Sendable {
    public var previous: URL?
    public var next: URL?
    public var contents: URL?

    /// Whether the page is a chapter with others around it.
    public var leadsToOtherChapters: Bool { previous != nil || next != nil }

    public init(page: PageLinks, url: URL) {
        let here = try? ArticleURL.parse(url.absoluteString)
        let site = Self.site(of: url)
        let links = page.links.compactMap { link -> (url: URL, label: String, rel: [String], text: String)? in
            guard let target = try? ArticleURL.parse(link.url), target != here, Self.site(of: target) == site else { return nil }
            return (target, Self.label(link.text), link.rel.split(separator: " ").map(String.init), link.text)
        }
        let number = SeriesTitle.partNumber(in: page.title)
        func find(_ words: [String], rels: [String], offset: Int) -> URL? {
            // "Next chapter" says so outright; a plain "Next", or a `rel`, could lead to any other post, so it's
            // only trusted on a page numbered as a part.
            let named = links.first { link in
                words.contains { link.label.hasPrefix($0 + " ") } && Self.partWords.contains { link.label.contains($0) }
            }
            let numbered = number.flatMap { number in links.first { SeriesTitle.partNumber(in: $0.text) == number + offset } }
            let plain = number == nil ? nil : links.first { link in
                link.rel.contains(where: rels.contains) || words.contains(link.label) || words.contains { link.label == $0 + " page" }
            }
            return (named ?? numbered ?? plain)?.url
        }
        previous = find(["previous", "prev", "prior"], rels: ["prev", "previous"], offset: -1)
        next = find(["next"], rels: ["next"], offset: 1)
        contents = links.first { link in
            Self.contentsLabels.contains(link.label) || link.rel.contains { ["contents", "toc", "index"].contains($0) }
        }?.url
    }

    private static let partWords = ["chapter", "part", "episode", "ch.", "ep."]
    private static let contentsLabels: Set = ["contents", "table of contents", "toc", "index", "chapter index", "chapters",
                                              "all chapters", "chapter list", "list of chapters"]

    /// The link's words, lowercased and without the arrows and marks drawn around them.
    static func label(_ text: String) -> String {
        let marks = CharacterSet(charactersIn: "«»‹›<>←→⟵⟶⇐⇒◀▶◄►|·:-–—").union(.whitespacesAndNewlines)
        return text.lowercased().components(separatedBy: marks).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func site(of url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// One chapter of a serial, found but not necessarily saved.
public struct Chapter: Identifiable, Hashable, Sendable {
    public let url: URL
    public let title: String
    public var id: URL { url }

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

public struct ChapterSearch: Sendable {
    /// Every chapter, in reading order.
    public var chapters: [Chapter]
    /// A name for the serial, from the titles of its pages.
    public var name: String
}

/// Finds every chapter of a serial from one of them: from its contents page when it links to one that lists it,
/// and otherwise by following the links from chapter to chapter.
@MainActor public struct ChapterFinder {
    /// The most chapters followed, so a site linking on and on doesn't keep the search going forever.
    public static let limit = 200
    /// The page at a URL, and where it ended up after redirects.
    public typealias Fetch = (URL) async throws -> (url: URL, page: PageLinks)
    let fetch: Fetch

    public init(fetch: @escaping Fetch) { self.fetch = fetch }

    /// `found` hears of the chapters found so far as the links between them are followed.
    public func chapters(around start: URL, found: ([Chapter]) -> Void) async throws -> ChapterSearch {
        let (fetched, page) = try await fetch(start)
        let url = try ArticleURL.parse(fetched.absoluteString)
        let links = ChapterLinks(page: page, url: url)
        if let contents = links.contents {
            do {
                let listing = try await fetch(contents)
                let chapters = Self.listed(on: listing.page, around: url, links: links)
                if chapters.count > 1 {
                    found(chapters)
                    return ChapterSearch(chapters: chapters, name: Self.name(for: [page.title, listing.page.title], or: page.title))
                }
            } catch is CancellationError { throw CancellationError() } catch {}
        }
        var chapters = [Chapter(url: url, title: page.title)]
        var seen: Set = [url]
        found(chapters)
        for forward in [false, true] {
            var cursor = forward ? links.next : links.previous
            while let link = cursor, chapters.count < Self.limit, seen.insert(link).inserted {
                try Task.checkCancellation()
                let fetched: (url: URL, page: PageLinks)
                // A chapter that fails to load ends the search that way, keeping what was found.
                do { fetched = try await fetch(link) } catch is CancellationError { throw CancellationError() } catch { break }
                guard let url = try? ArticleURL.parse(fetched.url.absoluteString), url == link || seen.insert(url).inserted else { break }
                let chapter = Chapter(url: url, title: fetched.page.title)
                if forward { chapters.append(chapter) } else { chapters.insert(chapter, at: 0) }
                found(chapters)
                let around = ChapterLinks(page: fetched.page, url: url)
                cursor = forward ? around.next : around.previous
            }
        }
        return ChapterSearch(chapters: chapters, name: Self.name(for: chapters.map(\.title), or: page.title))
    }

    /// The chapters a contents page lists: its links shaped like the chapter's own, such as `book3.html` for
    /// `book1.html`, in reading order. Empty unless the chapter is among them.
    static func listed(on contents: PageLinks, around url: URL, links: ChapterLinks) -> [Chapter] {
        let shape = Self.shape(of: url)
        var seen = Set<URL>()
        var chapters = contents.links.compactMap { link -> Chapter? in
            guard let target = try? ArticleURL.parse(link.url), Self.shape(of: target) == shape, seen.insert(target).inserted else { return nil }
            return Chapter(url: target, title: link.text.isEmpty ? target.lastPathComponent : link.text)
        }
        guard let here = chapters.firstIndex(where: { $0.url == url }) else { return [] }
        // Some contents pages list the newest chapter first.
        let next = links.next.flatMap { next in chapters.firstIndex { $0.url == next } }
        let previous = links.previous.flatMap { previous in chapters.firstIndex { $0.url == previous } }
        if let next, next < here { chapters.reverse() } else if let previous, previous > here { chapters.reverse() }
        return chapters
    }

    /// The URL's site, path and query with each number in it as "#".
    private static func shape(of url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let address = ChapterLinks.site(of: url) + (components?.path ?? "") + "?" + (components?.query ?? "")
        return address.replacing(#/\d+/#, with: "#")
    }

    private static func name(for titles: [String], or title: String) -> String {
        let name = SeriesTitle.name(for: titles)
        return name.isEmpty ? SeriesTitle.name(for: [title]) : name
    }
}
