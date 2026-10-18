import Foundation
import SwiftData

/// What narration and notes work from: an article's passages and sentences, and the notes written on it.
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

    nonisolated static func speech(at url: URL, title: String) async -> Speech? {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let passages = ArticleSpeech.passages(title: title, html: html)
        return Speech(passages: passages, sentences: passages.map(ArticleSpeech.sentences(in:)))
    }

    /// The saved passages and sentences of what's open in the reader, which `speech(for:)` has usually read already.
    func knownSpeech(for readable: any Readable) -> Speech? {
        guard let url = contentURL(for: readable) else { return nil }
        if let known = speechCache[PassageKey(content: url, title: readable.title)] { return known }
        return (try? String(contentsOf: url, encoding: .utf8)).map {
            let passages = ArticleSpeech.passages(title: readable.title, html: $0)
            return Speech(passages: passages, sentences: passages.map(ArticleSpeech.sentences(in:)))
        }
    }

    /// The notes written on `readable`, those on its sentences placed beside them as `speech` gives them.
    public func notes(for readable: any Readable, speech: Speech) -> ReadableNotes {
        var notes = storedNotes(for: readable)
        notes.sentences = ArticleNotes.placed(notes.sentences, in: speech.passages, sentences: speech.sentences)
        return notes
    }

    /// Replaces the note beside a sentence; empty text removes it.
    public func setNote(_ text: String, at passage: Int, sentence: Int, for readable: any Readable) {
        guard let speech = knownSpeech(for: readable), speech.passages.indices.contains(passage),
              speech.sentences[passage].indices.contains(sentence) else { return }
        var notes = self.notes(for: readable, speech: speech)
        notes.sentences.removeAll { $0.passage == passage && $0.sentence == sentence }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            notes.sentences.append(ArticleNote(passage: passage, anchor: ArticleNotes.anchor(for: speech.passages[passage]),
                                               sentence: sentence, quote: speech.sentences[passage][sentence], text: text))
            notes.sentences.sort { ($0.passage, $0.sentence) < ($1.passage, $1.sentence) }
        }
        store(notes, for: readable)
    }

    /// Replaces the note on a picture, by its file; empty text removes it.
    public func setPictureNote(_ text: String, source: String, alt: String, for readable: any Readable) {
        var notes = storedNotes(for: readable)
        notes.pictures.removeAll { $0.source == source }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { notes.pictures.append(PictureNote(source: source, alt: alt, text: text)) }
        store(notes, for: readable)
    }

    /// Replaces the note on the whole of `readable`; empty text removes it.
    public func setOverallNote(_ text: String, for readable: any Readable) {
        var notes = storedNotes(for: readable)
        notes.overall = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store(notes, for: readable)
    }

    /// Writing a note keeps a cached article, so the note isn't evicted with it.
    private func store(_ notes: ReadableNotes, for readable: any Readable) {
        if !notes.isEmpty, let article = readable as? Article { keep(article) }
        let url = storage.notesURL(readable.location)
        do {
            if !notes.isEmpty {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(notes).write(to: url, options: .atomic)
            }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch { errorMessage = error.localizedDescription }
    }

    func storedNotes(for readable: any Readable) -> ReadableNotes {
        guard let data = try? Data(contentsOf: storage.notesURL(readable.location)) else { return ReadableNotes() }
        return (try? JSONDecoder().decode(ReadableNotes.self, from: data)) ?? ReadableNotes()
    }
}
