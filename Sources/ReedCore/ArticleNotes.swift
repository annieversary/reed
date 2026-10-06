import Foundation

/// A note written beside one passage of a saved article.
public struct ArticleNote: Codable, Equatable, Sendable {
    /// The passage it's beside, numbered as `ArticleSpeech.passages` numbers them.
    public var passage: Int
    /// The start of that passage, to find it again when the article is saved anew and its passages are renumbered.
    public var anchor: String
    public var text: String

    public init(passage: Int, anchor: String, text: String) {
        self.passage = passage
        self.anchor = anchor
        self.text = text
    }
}

public enum ArticleNotes {
    public static func anchor(for passage: String) -> String { String(passage.prefix(80)) }

    /// The passage nearest `index` that starts with `anchor`, or `index` within range if none does.
    public static func passage(near index: Int, anchor: String?, in passages: [String]) -> Int {
        passages.indices.filter { anchor != nil && self.anchor(for: passages[$0]) == anchor }.min { abs($0 - index) < abs($1 - index) }
            ?? min(max(index, 0), passages.count - 1)
    }

    /// `notes` moved to the passages they were written beside, found by their anchors, nearest first.
    /// A note whose passage is gone keeps its number, within range, and notes that land on the same passage are joined.
    public static func placed(_ notes: [ArticleNote], in passages: [String]) -> [ArticleNote] {
        guard !passages.isEmpty else { return [] }
        let anchors = passages.map(anchor(for:))
        var placed: [Int: String] = [:]
        for note in notes.sorted(by: { $0.passage < $1.passage }) {
            let at = passage(near: note.passage, anchor: note.anchor, in: passages)
            placed[at] = placed[at].map { $0 + "\n\n" + note.text } ?? note.text
        }
        return placed.sorted { $0.key < $1.key }.map { ArticleNote(passage: $0.key, anchor: anchors[$0.key], text: $0.value) }
    }
}
