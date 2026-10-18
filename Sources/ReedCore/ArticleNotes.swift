import Foundation

/// A note written beside one sentence of a saved article.
public struct ArticleNote: Codable, Equatable, Sendable {
    /// The passage it's beside, numbered as `ArticleSpeech.passages` numbers them.
    public var passage: Int
    /// The start of that passage, to find it again when the article is saved anew and its passages are renumbered.
    public var anchor: String
    /// The sentence it's beside, numbered within its passage as `ArticleSpeech.sentences(in:)` numbers them.
    public var sentence: Int
    /// That sentence, to find it again within its passage, and to show with the note.
    public var quote: String
    public var text: String

    public init(passage: Int, anchor: String, sentence: Int = 0, quote: String = "", text: String) {
        self.passage = passage
        self.anchor = anchor
        self.sentence = sentence
        self.quote = quote
        self.text = text
    }

    // Notes written before sentences could be noted were beside a whole passage, and go beside its first sentence.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        passage = try container.decode(Int.self, forKey: .passage)
        anchor = try container.decode(String.self, forKey: .anchor)
        sentence = try container.decodeIfPresent(Int.self, forKey: .sentence) ?? 0
        quote = try container.decodeIfPresent(String.self, forKey: .quote) ?? ""
        text = try container.decode(String.self, forKey: .text)
    }
}

/// A note written about one picture in a saved article.
public struct PictureNote: Codable, Equatable, Sendable {
    /// The picture's file, as the saved page names it.
    public var source: String
    /// Its alt text, to find it again should a fresh save name its file differently.
    public var alt: String
    public var text: String

    public init(source: String, alt: String, text: String) {
        self.source = source
        self.alt = alt
        self.text = text
    }
}

/// Everything written about one article or chapter: a note on the whole of it, and notes on its sentences and pictures.
public struct ReadableNotes: Codable, Equatable, Sendable {
    public var overall: String
    public var sentences: [ArticleNote]
    public var pictures: [PictureNote]

    public init(overall: String = "", sentences: [ArticleNote] = [], pictures: [PictureNote] = []) {
        self.overall = overall
        self.sentences = sentences
        self.pictures = pictures
    }

    public var isEmpty: Bool { overall.isEmpty && sentences.isEmpty && pictures.isEmpty }

    // Notes were once kept as a bare list of passage notes.
    public init(from decoder: any Decoder) throws {
        if let sentences = try? decoder.singleValueContainer().decode([ArticleNote].self) {
            self.init(sentences: sentences)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(overall: try container.decodeIfPresent(String.self, forKey: .overall) ?? "",
                  sentences: try container.decodeIfPresent([ArticleNote].self, forKey: .sentences) ?? [],
                  pictures: try container.decodeIfPresent([PictureNote].self, forKey: .pictures) ?? [])
    }
}

public enum ArticleNotes {
    public static func anchor(for passage: String) -> String { String(passage.prefix(80)) }

    /// The passage nearest `index` that starts with `anchor`, or `index` within range if none does.
    public static func passage(near index: Int, anchor: String?, in passages: [String]) -> Int {
        nearest(index, among: passages.indices.filter { anchor != nil && self.anchor(for: passages[$0]) == anchor })
            ?? min(max(index, 0), passages.count - 1)
    }

    private static func nearest(_ index: Int, among candidates: [Int]) -> Int? {
        candidates.min { abs($0 - index) < abs($1 - index) }
    }

    /// `notes` moved to the sentences they were written beside: their passage found by its anchor, or else by the sentence,
    /// and the sentence within it nearest where it was. A note whose sentence is gone keeps its numbers, within range,
    /// and notes that land on the same sentence are joined.
    public static func placed(_ notes: [ArticleNote], in passages: [String], sentences: [[String]]) -> [ArticleNote] {
        guard !passages.isEmpty, passages.count == sentences.count else { return [] }
        let anchors = passages.map(anchor(for:))
        var placed: [[Int]: String] = [:]
        for note in notes.sorted(by: { ($0.passage, $0.sentence) < ($1.passage, $1.sentence) }) {
            let quoted = note.quote.isEmpty ? [] : sentences.indices.filter { sentences[$0].contains(note.quote) }
            let at = nearest(note.passage, among: passages.indices.filter { anchors[$0] == note.anchor })
                ?? nearest(note.passage, among: quoted)
                ?? min(max(note.passage, 0), passages.count - 1)
            let list = sentences[at]
            let sentence = nearest(note.sentence, among: list.indices.filter { list[$0] == note.quote })
                ?? min(max(note.sentence, 0), max(list.count - 1, 0))
            placed[[at, sentence]] = placed[[at, sentence]].map { $0 + "\n\n" + note.text } ?? note.text
        }
        return placed.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map { key, text in
            let list = sentences[key[0]]
            return ArticleNote(passage: key[0], anchor: anchors[key[0]], sentence: key[1],
                               quote: list.indices.contains(key[1]) ? list[key[1]] : "", text: text)
        }
    }
}
