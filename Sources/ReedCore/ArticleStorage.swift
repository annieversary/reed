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

    public static func document(title: String, author: String?, domain: String, minutes: Int, body: String) -> String {
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
        .source { font:11px -apple-system,sans-serif; font-weight:600; letter-spacing:2px; text-transform:uppercase; color:var(--accent); }
        h1 { font-size:2.25em; font-weight:normal; line-height:1.16; letter-spacing:-1.4px; margin:18px 0; }
        .byline { color:var(--muted); font:13px/1.6 -apple-system,sans-serif; }
        h2,h3,h4 { line-height:1.35; margin-top:1.8em; } p { margin:1.2em 0; }
        a { color:var(--accent); text-underline-offset:4px; } img { max-width:100%; height:auto; border-radius:4px; }
        figure { margin:2em 0; } figcaption { font:13px/1.6 -apple-system,sans-serif; color:var(--muted); }
        blockquote { margin:1.7em 0; padding-left:24px; border-left:3px solid var(--accent); font-style:italic; }
        pre { overflow:auto; padding:18px; background:color-mix(in srgb,var(--muted) 10%,transparent); border-radius:5px; }
        code { font:0.85em ui-monospace,monospace; } table { display:block; max-width:100%; overflow:auto; border-collapse:collapse; }
        th,td { border:1px solid var(--muted); padding:8px; } hr { border:0; border-top:1px solid var(--muted); margin:2em 0; }
        .missing-image { color:var(--muted); font:13px -apple-system,sans-serif; }
        @media(max-width:500px) { body { padding:32px 24px 100px; } h1 { font-size:1.85em; } }
        </style></head><body><header><div class="source">\(escape(domain))</div>
        <h1>\(escape(title))</h1><div class="byline">\(escape(byline))</div></header>
        <main>\(body)</main></body></html>
        """
    }
}
