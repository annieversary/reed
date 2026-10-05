import Foundation

public struct ArticleStorage: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true).appendingPathComponent("Reed", isDirectory: true)
    }

    public func articleDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("Articles", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func contentURL(_ id: UUID, version: String) -> URL {
        articleDirectory(id).appendingPathComponent(version, isDirectory: true).appendingPathComponent("index.html")
    }

    /// Narration of one saved version in one voice. It sits beside the versions, so deleting the article removes it.
    public func audioDirectory(_ id: UUID, version: String, voice: String) -> URL {
        articleDirectory(id).appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true).appendingPathComponent(voice, isDirectory: true)
    }

    /// Notes written beside the article. They sit beside the versions, so they outlast a fresh download.
    public func notesURL(_ id: UUID) -> URL {
        articleDirectory(id).appendingPathComponent("Notes.json")
    }

    /// The comments last fetched from one place the article is discussed.
    public func discussionURL(_ id: UUID, site: DiscussionSite) -> URL {
        articleDirectory(id).appendingPathComponent("Discussions", isDirectory: true).appendingPathComponent(site.key + ".json")
    }

    /// A PDF shared as a file, kept beside the versions made from it so it can be read again.
    public func sharedFileURL(_ id: UUID) -> URL {
        articleDirectory(id).appendingPathComponent("Shared.pdf")
    }

    public func bookDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("Books", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The EPUB a book was added from, kept beside its versions so it can be converted again.
    public func bookFileURL(_ id: UUID) -> URL {
        bookDirectory(id).appendingPathComponent("Book.epub")
    }

    public func contentURL(_ location: ReadableLocation, version: String) -> URL {
        switch location {
        case .article(let id): contentURL(id, version: version)
        case .chapter(let book, let index):
            bookDirectory(book).appendingPathComponent(version, isDirectory: true).appendingPathComponent(BookFiles.chapter(index))
        }
    }

    public func audioDirectory(_ location: ReadableLocation, version: String, voice: String) -> URL {
        switch location {
        case .article(let id): audioDirectory(id, version: version, voice: voice)
        case .chapter(let book, let index):
            bookDirectory(book).appendingPathComponent("Audio", isDirectory: true).appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent(voice, isDirectory: true).appendingPathComponent(String(index), isDirectory: true)
        }
    }

    public func notesURL(_ location: ReadableLocation) -> URL {
        switch location {
        case .article(let id): notesURL(id)
        case .chapter(let book, let index):
            bookDirectory(book).appendingPathComponent("Notes", isDirectory: true).appendingPathComponent("\(index).json")
        }
    }

    public func commitBook(staging: URL, id: UUID, version: String) throws {
        let parent = bookDirectory(id)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: parent.appendingPathComponent(version))
    }

    /// Removes a saved version, once a newer one has replaced it.
    public func removeBookVersion(_ id: UUID, version: String) throws {
        let url = bookDirectory(id).appendingPathComponent(version, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func removeBook(_ id: UUID) throws {
        let url = bookDirectory(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func createStagingDirectory() throws -> URL {
        let url = root.appendingPathComponent("Staging", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // A complete immutable package is moved into place before the database references it.
    public func commit(staging: URL, id: UUID, version: String) throws {
        let parent = articleDirectory(id)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: parent.appendingPathComponent(version))
    }

    public func removeArticle(_ id: UUID) throws {
        let url = articleDirectory(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func cleanStaging() throws {
        let url = root.appendingPathComponent("Staging")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public enum ArticleHTML {
    public static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The file name of the first image in a saved reader document. Saved images are referenced by
    /// bare file names beside the document; anything else isn't one of ours.
    public static func firstImage(in html: String) -> String? {
        guard let match = html.firstMatch(of: #/<img\b[^>]*\bsrc="([^"/:]+)"/#.ignoresCase()) else { return nil }
        return String(match.output.1)
    }

    /// `after` follows the article, outside what's read aloud, such as the way on to a book's next chapter.
    public static func document(title: String, author: String?, domain: String, minutes: Int, body: String, after: String = "") -> String {
        let byline = [author, "\(minutes) min read"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --paper:#fff; --ink:#282d28; --muted:#797e74; --accent:#4c6450; --font-size:19px; }
        @media(prefers-color-scheme:dark) { :root { --paper:#000; --ink:#e5e8df; --muted:#a0a89b; --accent:#b6cda8; } }
        * { box-sizing:border-box } html { background:var(--paper); overflow-wrap:anywhere; }
        body { max-width:740px; margin:0 auto; padding:60px 42px 140px; color:var(--ink); font:var(--font-size)/1.8 Georgia,serif; }
        header { margin-bottom:38px; padding-bottom:30px; border-bottom:1px solid color-mix(in srgb,var(--muted) 25%,transparent); }
        .source { font:11px -apple-system,sans-serif; font-weight:600; letter-spacing:2px; color:var(--accent); }
        h1 { font-size:2.25em; font-weight:normal; line-height:1.16; letter-spacing:-1.4px; margin:18px 0; }
        .byline { color:var(--muted); font:13px/1.6 -apple-system,sans-serif; }
        h2,h3,h4 { line-height:1.35; margin-top:1.8em; } p { margin:1.2em 0; }
        a { color:var(--accent); text-underline-offset:4px; } img, svg { max-width:100%; height:auto; border-radius:4px; }
        @media(prefers-color-scheme:dark) { svg { background:#fff; color:#282d28; } }
        figure { margin:2em 0; } figcaption { font:13px/1.6 -apple-system,sans-serif; color:var(--muted); }
        figure.equation { margin:1.4em 0; text-align:center; } .footnotes { font-size:0.85em; color:var(--muted); }
        @media(prefers-color-scheme:dark) { figure.equation img { filter:invert(1) hue-rotate(180deg); } }
        blockquote { margin:1.7em 0; padding-left:24px; border-left:3px solid var(--accent); font-style:italic; }
        pre { overflow:auto; padding:18px; background:color-mix(in srgb,var(--muted) 10%,transparent); border-radius:5px; }
        math { font-family:"STIX Two Math",math; } code { font:0.85em ui-monospace,monospace; } table { display:block; max-width:100%; overflow:auto; border-collapse:collapse; }
        th,td { border:1px solid var(--muted); padding:8px; } hr { border:0; border-top:1px solid var(--muted); margin:2em 0; }
        .missing-image { color:var(--muted); font:13px -apple-system,sans-serif; }
        .next-chapter { display:block; margin-top:64px; padding:22px 26px; border:1px solid color-mix(in srgb,var(--muted) 30%,transparent); border-radius:10px; color:var(--ink); text-decoration:none; }
        .next-chapter:hover { border-color:var(--accent); }
        .next-chapter small { display:block; margin-bottom:6px; font:11px -apple-system,sans-serif; font-weight:600; letter-spacing:2px; color:var(--accent); }
        .next-chapter span { font-size:1.15em; }
        @media(max-width:500px) { body { padding:32px 24px 100px; } h1 { font-size:1.85em; } }
        </style></head><body><header><div class="source">\(escape(domain))</div>
        <h1>\(escape(title))</h1><div class="byline">\(escape(byline))</div></header>
        <main>\(body)</main>\(after)</body></html>
        """
    }
}

/// The names of a saved book version's files.
public enum BookFiles {
    public static func chapter(_ index: Int) -> String { "\(index).html" }

    /// A saved image's file name, from its path in the archive, as the extraction script names it.
    public static func imageName(for path: String) -> String {
        "book-" + String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "_" })
    }

    /// A card at the end of a chapter that opens the next one.
    public static func nextChapterCard(index: Int, title: String) -> String {
        "<a class=\"next-chapter\" href=\"\(chapter(index))\"><small>NEXT CHAPTER</small><span>\(ArticleHTML.escape(title))</span></a>"
    }

    /// The chapter a saved file is, from its name.
    public static func chapterIndex(of name: String) -> Int? {
        name.hasSuffix(".html") ? Int(name.dropLast(5)) : nil
    }
}
