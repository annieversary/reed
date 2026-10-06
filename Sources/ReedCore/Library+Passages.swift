import Foundation
import SwiftData

/// What narration and notes work from: an article's passages and sentences, and the notes beside them.
public struct Speech: Sendable {
    public let passages: [String]
    public let sentences: [[String]]
}

extension Library {
    /// The saved text to read aloud, a passage at a time, and each passage's sentences, as narration follows them;
    /// nil if it isn't saved. Read and split away from the main thread.
    public func speech(for readable: any Readable) async -> Speech? {
        guard let url = contentURL(for: readable) else { return nil }
        // A saved version never changes, so its passages are kept while it's being read, noted and listened to.
        let key = PassageKey(content: url, title: readable.title)
        if let known = speechCache[key] { return known }
        guard let speech = await Self.speech(at: url, title: readable.title) else { return nil }
        if speechCache.count >= 4 { speechCache.removeAll() }
        speechCache[key] = speech
        return speech
    }

    /// The passages of what's open in the reader, which `speech(for:)` has usually read already.
    public func passages(for readable: any Readable) -> [String]? {
        guard let url = contentURL(for: readable) else { return nil }
        if let known = speechCache[PassageKey(content: url, title: readable.title)] { return known.passages }
        return (try? String(contentsOf: url, encoding: .utf8)).map { ArticleSpeech.passages(title: readable.title, html: $0) }
    }

    nonisolated static func speech(at url: URL, title: String) async -> Speech? {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let passages = ArticleSpeech.passages(title: title, html: html)
        return Speech(passages: passages, sentences: passages.map(ArticleSpeech.sentences(in:)))
    }

    /// The notes written beside the saved passages, as `passages(for:)` gives them.
    public func notes(for readable: any Readable, passages: [String]) -> [ArticleNote] {
        ArticleNotes.placed(storedNotes(for: readable), in: passages)
    }

    /// Replaces the note beside a passage; empty text removes it. Writing a note keeps a cached article,
    /// so the note isn't evicted with it.
    public func setNote(_ text: String, at passage: Int, for readable: any Readable) {
        guard let passages = passages(for: readable), passages.indices.contains(passage) else { return }
        var notes = ArticleNotes.placed(storedNotes(for: readable), in: passages).filter { $0.passage != passage }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            notes.append(ArticleNote(passage: passage, anchor: ArticleNotes.anchor(for: passages[passage]), text: text))
            notes.sort { $0.passage < $1.passage }
            if let article = readable as? Article { keep(article) }
        }
        let url = storage.notesURL(readable.location)
        do {
            if !notes.isEmpty {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(notes).write(to: url, options: .atomic)
            }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch { errorMessage = error.localizedDescription }
    }

    func storedNotes(for readable: any Readable) -> [ArticleNote] {
        guard let data = try? Data(contentsOf: storage.notesURL(readable.location)) else { return [] }
        return (try? JSONDecoder().decode([ArticleNote].self, from: data)) ?? []
    }
}
