import Foundation
import SQLite3

/// Full-text index of the library, in its own SQLite database beside the SwiftData store.
/// Everything in it can be rebuilt from the saved articles, so a damaged or outdated file is discarded.
public actor SearchIndex {
    public struct Entry: Sendable {
        public let id: UUID
        /// Changes whenever the saved content does; nil until the article is downloaded.
        public let version: String?
        public let title: String
        public let author: String?
        public let domain: String
        /// The saved reader document, if there is one.
        public let content: URL?

        public init(id: UUID, version: String?, title: String, author: String?, domain: String, content: URL?) {
            self.id = id
            self.version = version
            self.title = title
            self.author = author
            self.domain = domain
            self.content = content
        }
    }

    public struct Match: Sendable, Equatable {
        public let id: UUID
        /// A passage of the body with matched terms between `highlightStart` and `highlightEnd`,
        /// or nil when only the title, author or site matched.
        public let snippet: String?
    }

    public static let highlightStart = "\u{2}"
    public static let highlightEnd = "\u{3}"
    private static let schemaVersion = 1
    private let connection: Connection

    public init(url: URL) throws {
        do { connection = try Self.open(url) } catch {
            try? FileManager.default.removeItem(at: url)
            connection = try Self.open(url)
        }
    }

    private static func open(_ url: URL) throws -> Connection {
        let connection = try Connection(url)
        var version = 0
        try connection.run("PRAGMA user_version") { version = Int(sqlite3_column_int($0, 0)) }
        if version != schemaVersion {
            try connection.execute("""
            DROP TABLE IF EXISTS articles;
            CREATE VIRTUAL TABLE articles USING fts5(
                id UNINDEXED, version UNINDEXED, title, author, domain, body,
                tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3');
            PRAGMA user_version = \(schemaVersion);
            """)
        }
        return connection
    }

    public func index(_ entry: Entry) throws {
        try connection.transaction { try store(entry) }
    }

    public func remove(_ id: UUID) throws {
        try connection.run("DELETE FROM articles WHERE id = ?", [id.uuidString])
    }

    /// Brings the index in line with `entries`, reading only the articles whose content changed.
    public func sync(_ entries: [Entry]) throws {
        try connection.transaction {
            var indexed: [String: String] = [:]
            try connection.run("SELECT id, version FROM articles") { indexed[Connection.text($0, 0) ?? ""] = Connection.text($0, 1) ?? "" }
            let wanted = Set(entries.map(\.id.uuidString))
            for id in indexed.keys where !wanted.contains(id) {
                try connection.run("DELETE FROM articles WHERE id = ?", [id])
            }
            for entry in entries where indexed[entry.id.uuidString] != entry.version ?? "" {
                try store(entry)
            }
        }
    }

    /// Articles containing every word of `text` (each also as a prefix), best match first.
    public func search(_ text: String) throws -> [Match] {
        guard let expression = Self.expression(for: text) else { return [] }
        var matches: [Match] = []
        // Weights follow the column order: id, version, title, author, domain, body.
        try connection.run("""
            SELECT id, snippet(articles, 5, ?, ?, '…', 14) FROM articles WHERE articles MATCH ?
            ORDER BY bm25(articles, 0, 0, 10, 4, 2, 1)
            """, [Self.highlightStart, Self.highlightEnd, expression]) { row in
            guard let id = Connection.text(row, 0).flatMap(UUID.init(uuidString:)) else { return }
            let snippet = Connection.text(row, 1)
            matches.append(Match(id: id, snippet: snippet?.contains(Self.highlightStart) == true ? snippet : nil))
        }
        return matches
    }

    /// Quotes each word so FTS5 syntax typed by the reader is matched literally.
    static func expression(for text: String) -> String? {
        let terms = text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " ")
    }

    private func store(_ entry: Entry) throws {
        let body = entry.content.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(ArticleText.plain) ?? ""
        try connection.run("DELETE FROM articles WHERE id = ?", [entry.id.uuidString])
        try connection.run("INSERT INTO articles (id, version, title, author, domain, body) VALUES (?, ?, ?, ?, ?, ?)",
                           [entry.id.uuidString, entry.version ?? "", entry.title, entry.author ?? "", entry.domain, body])
    }
}

public enum ArticleText {
    /// The readable text of a saved reader document, or of an HTML fragment.
    public static func plain(_ html: String) -> String {
        var text = Substring(html)
        if let start = text.range(of: "<main>"), let end = text.range(of: "</main>", options: .backwards), start.upperBound <= end.lowerBound {
            text = text[start.upperBound..<end.lowerBound]
        }
        return String(text)
            .replacing(#/<math\b([^>]*)>(.*?)</math\s*>/#.dotMatchesNewlines().ignoresCase()) { match in
                " " + spoken(mathAttributes: String(match.output.1), content: String(match.output.2)) + " "
            }
            .replacing(#/<(?:"[^"]*"|'[^']*'|[^"'>])*>/#, with: " ")
            .replacing(#/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/#) { match in
                let name = match.output.1
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } ?? String(match.output.0)
                }
                if name.hasPrefix("#") {
                    return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) } ?? String(match.output.0)
                }
                return ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "][String(name)] ?? String(match.output.0)
            }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// How a formula reads: its spoken label when it has one, otherwise its text if that's plain, like "n" or "32",
    /// and otherwise nothing, since the text of anything more is a jumble of symbols. The reader's narration
    /// highlighting reads formulas the same way.
    static func spoken(mathAttributes: String, content: String) -> String {
        if let label = mathAttributes.firstMatch(of: #/\baria-label="([^"]*)"/#)?.output.1 { return String(label) }
        guard let tex = mathAttributes.firstMatch(of: #/\balttext="([^"]*)"/#)?.output.1,
              !tex.contains(where: { "\\^_{".contains($0) }) else { return "" }
        return content
    }
}

private final class Connection {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { "Search index: \(message)" }
    }

    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ url: URL) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            sqlite3_close(handle)
            throw Failure(message: message)
        }
        self.handle = handle
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }

    func run(_ sql: String, _ arguments: [String] = [], row: (OpaquePointer) -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, Self.transient)
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw failure()
            }
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func failure() -> Failure { Failure(message: String(cString: sqlite3_errmsg(handle))) }
}
