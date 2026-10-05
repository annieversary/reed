import Foundation

/// An EPUB's metadata and its chapters, read from the package file and table of contents.
public struct EPUB {
    public struct Chapter: Equatable, Sendable {
        /// The table of contents' name for it; nil for pages before the first entry, or a book without one.
        public var title: String?
        /// What it's made of, in reading order. A chapter may run across files, or be one of several in a file.
        public var parts: [Part]
    }

    /// A file in the archive, or the part of it from one element to another, each given by its ID.
    public struct Part: Equatable, Sendable {
        public var path: String
        public var from: String?
        public var to: String?

        public init(_ path: String, from: String? = nil, to: String? = nil) {
            self.path = path
            self.from = from
            self.to = to
        }
    }

    /// An entry in the table of contents.
    struct Entry: Equatable {
        var title: String
        var path: String
        var fragment: String?
        /// Whether it's nested under an entry pointing into the same file, as a section of that chapter would be.
        var isSection = false

        init(title: String, path: String, fragment: String? = nil, isSection: Bool = false) {
            self.title = title
            self.path = path
            self.fragment = fragment
            self.isSection = isSection
        }

        /// An entry for a link written in the file at `base`, nested under one pointing into `parent`.
        init(title: String, href: String, base: String, parent: String?) {
            let path = EPUB.resolve(href, from: base)
            let fragment = href.firstIndex(of: "#").map { String(href[href.index(after: $0)...]) }.flatMap { $0.removingPercentEncoding ?? $0 }
            self.init(title: title, path: path, fragment: fragment?.isEmpty == false ? fragment : nil, isSection: parent == path && fragment != nil)
        }
    }

    public let title: String?
    public let author: String?
    /// The cover image's path in the archive.
    public let cover: String?
    public let chapters: [Chapter]
    private let archive: ZipArchive

    public init(data: Data) throws {
        do { archive = try ZipArchive(data) } catch { throw ReedError.unreadableBook }
        // Fonts may be obfuscated by these; anything else encrypted is a book locked to a store's app.
        let fontObfuscation: Set = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        if let encryption = try Self.document(archive, "META-INF/encryption.xml"),
           encryption.all("EncryptionMethod").contains(where: { !fontObfuscation.contains($0.attributes["Algorithm"] ?? "") }) {
            throw ReedError.protectedBook
        }
        guard let container = try Self.document(archive, "META-INF/container.xml"),
              let packagePath = container.first("rootfile")?.attributes["full-path"],
              let package = try Self.document(archive, packagePath) else { throw ReedError.unreadableBook }
        let metadata = package.first("metadata")
        title = metadata?.first("title")?.text.nonEmpty
        author = metadata?.all("creator").first?.text.nonEmpty

        var manifest: [String: (path: String, type: String, properties: Set<String>)] = [:]
        for item in package.first("manifest")?.all("item") ?? [] {
            guard let id = item.attributes["id"], let href = item.attributes["href"] else { continue }
            manifest[id] = (Self.resolve(href, from: packagePath), item.attributes["media-type"] ?? "",
                            Set((item.attributes["properties"] ?? "").split(separator: " ").map(String.init)))
        }
        let coverID = metadata?.all("meta").first { $0.attributes["name"] == "cover" }?.attributes["content"]
        cover = manifest.values.first { $0.properties.contains("cover-image") }?.path
            ?? coverID.flatMap { manifest[$0] }.flatMap { $0.type.hasPrefix("image/") ? $0.path : nil }

        let spineElement = package.first("spine")
        let spine = (spineElement?.all("itemref") ?? []).compactMap { $0.attributes["idref"].flatMap { manifest[$0]?.path } }
        guard !spine.isEmpty else { throw ReedError.unreadableBook }

        var contents: [Entry] = []
        if let nav = manifest.values.first(where: { $0.properties.contains("nav") }) {
            contents = try Self.navigation(archive, nav.path)
        }
        if contents.isEmpty, let ncx = spineElement?.attributes["toc"].flatMap({ manifest[$0] })
            ?? manifest.values.first(where: { $0.type == "application/x-dtbncx+xml" }) {
            contents = try Self.ncx(archive, ncx.path)
        }
        var ids: [String: [String]] = [:]
        for path in Set(contents.filter { $0.fragment != nil }.map(\.path)) {
            if let data = try? archive.file(path) { ids[path] = Self.ids(in: String(decoding: data, as: UTF8.self)).map(\.id) }
        }
        chapters = Self.chapters(spine: spine, contents: contents, ids: ids)
    }

    /// The file at `path` in the archive.
    public func file(_ path: String) throws -> Data? {
        do { return try archive.file(path) } catch { throw ReedError.unreadableBook }
    }

    /// Divides the reading order into chapters where the table of contents starts one: at a file, or at an element
    /// within one, since some books keep several chapters to a file. Sections of a chapter stay in it, and pages
    /// before the first entry are a chapter of their own. `ids` lists each file's element IDs in the order they appear,
    /// so chapters within a file follow the file even when the table of contents lists them out of order.
    static func chapters(spine: [String], contents: [Entry], ids: [String: [String]] = [:]) -> [Chapter] {
        var starts: [String: [Entry]] = [:]
        for entry in contents where !entry.isSection && spine.contains(entry.path) {
            guard !(starts[entry.path] ?? []).contains(where: { $0.fragment == entry.fragment }) else { continue }
            starts[entry.path, default: []].append(entry)
        }
        guard !starts.isEmpty else { return spine.map { Chapter(title: nil, parts: [Part($0)]) } }
        var chapters: [Chapter] = []
        func add(_ part: Part) {
            if chapters.isEmpty { chapters.append(Chapter(title: nil, parts: [])) }
            chapters[chapters.count - 1].parts.append(part)
        }
        for path in spine {
            // An entry for the whole file starts it; the others follow in the order they appear in it.
            let order = Dictionary((ids[path] ?? []).enumerated().map { ($1, $0) }) { first, _ in first }
            let fragments = (starts[path] ?? []).enumerated().filter { $0.element.fragment != nil }
                .sorted { (order[$0.element.fragment!] ?? .max, $0.offset) < (order[$1.element.fragment!] ?? .max, $1.offset) }.map(\.element)
            let entries = (starts[path] ?? []).filter { $0.fragment == nil } + fragments
            var from: String?
            for entry in entries {
                // What comes before an element starting a chapter belongs to the one before.
                if let fragment = entry.fragment { add(Part(path, from: from, to: fragment)) }
                chapters.append(Chapter(title: entry.title, parts: []))
                from = entry.fragment
            }
            add(Part(path, from: from))
        }
        return chapters
    }

    /// Which chapter each file belongs to, by path, and for files shared between chapters, which one each element
    /// is in, by path and ID, so links can be pointed at the saved chapter.
    func links(for chapters: [Chapter]) throws -> [String: Int] {
        var links: [String: Int] = [:]
        var shared: [String: [(start: String?, chapter: Int)]] = [:]
        for (index, chapter) in chapters.enumerated() {
            for part in chapter.parts {
                if part.from == nil && part.to == nil { links[part.path] = index } else { shared[part.path, default: []].append((part.from, index)) }
            }
        }
        for (path, parts) in shared {
            links[path] = links[path] ?? parts.first { $0.start == nil }?.chapter ?? parts[0].chapter
            guard let data = try file(path) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            let ids = Self.ids(in: html)
            let starts = parts.map { part in (at: part.start.flatMap { start in ids.first { $0.id == start }?.at } ?? html.startIndex, chapter: part.chapter) }
            for id in ids { links[path + "#" + id.id] = starts.last { $0.at <= id.at }?.chapter ?? links[path] }
        }
        return links
    }

    /// The element IDs in a file, in order, with where each is.
    private static func ids(in html: String) -> [(id: String, at: String.Index)] {
        html.matches(of: #/\bid\s*=\s*["']([^"']+)["']/#).map { (id: String($0.output.1), at: $0.range.lowerBound) }
    }

    /// The links in an EPUB 3 navigation document's table of contents, in order.
    private static func navigation(_ archive: ZipArchive, _ path: String) throws -> [Entry] {
        guard let document = try document(archive, path) else { return [] }
        let navs = document.all("nav")
        guard let toc = navs.first(where: { ($0.attributes["epub:type"] ?? "").split(separator: " ").contains("toc") }) ?? navs.first else { return [] }
        var entries: [Entry] = []
        func visit(_ node: PackageNode, under parent: String?) {
            for child in node.children {
                guard child.name == "li" else { visit(child, under: parent); continue }
                var file = parent
                if let link = child.children.first(where: { $0.name == "a" }), let href = link.attributes["href"], let title = link.text.nonEmpty {
                    let entry = Entry(title: title, href: href, base: path, parent: parent)
                    entries.append(entry)
                    file = entry.path
                }
                for list in child.children where list.name == "ol" { visit(list, under: file) }
            }
        }
        visit(toc, under: nil)
        return entries
    }

    /// The entries of an EPUB 2 NCX table of contents, in order.
    private static func ncx(_ archive: ZipArchive, _ path: String) throws -> [Entry] {
        guard let document = try document(archive, path), let map = document.first("navMap") else { return [] }
        var entries: [Entry] = []
        func visit(_ node: PackageNode, under parent: String?) {
            for point in node.children where point.name == "navPoint" {
                var file = parent
                if let source = point.children.first(where: { $0.name == "content" })?.attributes["src"],
                   let title = point.children.first(where: { $0.name == "navLabel" })?.text.nonEmpty {
                    let entry = Entry(title: title, href: source, base: path, parent: parent)
                    entries.append(entry)
                    file = entry.path
                }
                visit(point, under: file)
            }
        }
        visit(map, under: nil)
        return entries
    }

    /// An archive path for `href`, written relative to the file at `base`, without its fragment.
    static func resolve(_ href: String, from base: String) -> String {
        let target = String(href.prefix { $0 != "#" })
        let decoded = target.removingPercentEncoding ?? target
        var parts = target.hasPrefix("/") ? [] : base.split(separator: "/", omittingEmptySubsequences: false).dropLast().map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }

    private static func document(_ archive: ZipArchive, _ path: String) throws -> PackageNode? {
        guard let data = try archive.file(path) else { return nil }
        return PackageNode.parse(data)
    }
}

/// A parsed XML element, enough to read a package's metadata and tables of contents.
final class PackageNode {
    /// The element's name without its namespace prefix.
    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [PackageNode] = []
    fileprivate var ownText = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Its text and its descendants', with runs of whitespace collapsed.
    var text: String {
        collectedText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var collectedText: String { ownText + children.map { " " + $0.collectedText }.joined() }

    /// Descendants named `name`, in document order.
    func all(_ name: String) -> [PackageNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }

    func first(_ name: String) -> PackageNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    static func parse(_ data: Data) -> PackageNode? {
        let builder = Builder()
        // XHTML written for browsers may use HTML's named entities, which XML doesn't define.
        let parser = XMLParser(data: Builder.definingEntities(in: data))
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = PackageNode(name: "", attributes: [:])
        private var stack: [PackageNode] = []

        func parserDidStartDocument(_ parser: XMLParser) { stack = [root] }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let node = PackageNode(name: String(elementName.split(separator: ":").last ?? ""), attributes: attributes)
            stack.last?.children.append(node)
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.ownText += string }

        private static let entities = ["nbsp": 160, "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "ldquo": 8220,
                                       "rdquo": 8221, "hellip": 8230, "copy": 169, "eacute": 233, "egrave": 232, "rsaquo": 8250, "lsaquo": 8249]

        static func definingEntities(in data: Data) -> Data {
            var text = String(decoding: data, as: UTF8.self)
            guard text.contains("&") else { return data }
            for (name, code) in entities { text = text.replacingOccurrences(of: "&\(name);", with: "&#\(code);") }
            return Data(text.utf8)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
