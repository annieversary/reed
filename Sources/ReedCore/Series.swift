import Foundation

/// Saved articles read as parts of one whole, such as "Part 1", "Part 2" and so on.
public struct Series: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// The parts' article IDs, in reading order.
    public var parts: [UUID]

    public init(id: UUID = UUID(), name: String, parts: [UUID]) {
        self.id = id
        self.name = name
        self.parts = parts
    }
}

public enum SeriesTitle {
    /// The part number a title gives, as in "Part 3", "Pt. III", "(3/7)" or "#3".
    public static func partNumber(in title: String) -> Int? {
        let title = title.lowercased()
        if let match = title.firstMatch(of: #/\b(?:part|pt\.?|chapter|ch\.|episode|ep\.?|lesson|day|no\.)\s*(\d+)\b/#) {
            return Int(match.output.1)
        }
        if let match = title.firstMatch(of: #/\b(?:part|pt\.?|chapter)\s+([ivxlc]+|[a-z]+)\b/#),
           let number = roman(match.output.1) ?? words[String(match.output.1)] {
            return number
        }
        if let match = title.firstMatch(of: #/(?:^|[\s(\[])(\d+)\s*(?:/|of)\s*\d+\b/#) { return Int(match.output.1) }
        if let match = title.firstMatch(of: #/(?:^|\s)#(\d+)\b/#) { return Int(match.output.1) }
        return nil
    }

    /// A name for a series of articles with these titles: the words they share, without part numbers.
    /// Empty if they share none.
    public static func name(for titles: [String]) -> String {
        let titles = titles.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
        guard let first = titles.first else { return "" }
        let prefix = titles.dropFirst().reduce(first) { shared, words in
            Array(zip(shared, words).prefix { $0.lowercased() == $1.lowercased() }.map(\.0))
        }
        let name = trimmed(Array(prefix.reversed().drop(while: isFiller).reversed()))
        if titles.count > 1, name.count < 3 {
            let suffix = titles.dropFirst().reduce(Array(first.reversed())) { shared, words in
                Array(zip(shared, words.reversed()).prefix { $0.lowercased() == $1.lowercased() }.map(\.0))
            }
            let name = trimmed(Array(suffix.reversed().drop(while: isFiller)))
            if name.count >= 3 { return name }
        }
        if titles.count > 1 { return name.count >= 3 ? name : "" }
        return name.isEmpty ? first.joined(separator: " ") : name
    }

    private static let separators = CharacterSet(charactersIn: ":-–—|,·([#").union(.whitespaces)

    private static func trimmed(_ words: [String]) -> String {
        words.joined(separator: " ").trimmingCharacters(in: separators)
    }

    /// Whether a word only marks the part, as "Part", "3", "III" or ":" do.
    private static func isFiller(_ word: String) -> Bool {
        let word = word.lowercased().trimmingCharacters(in: separators.union(CharacterSet(charactersIn: ").]")))
        return word.isEmpty || Int(word) != nil || roman(Substring(word)) != nil || words[word] != nil
            || ["part", "pt", "pt.", "chapter", "ch.", "episode", "ep", "ep.", "lesson", "day", "no."].contains(word)
            || word.firstMatch(of: #/^\d+(?:/|of)\d+$/#) != nil
    }

    private static let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                                "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]

    private static func roman(_ text: Substring) -> Int? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100]
        let digits = text.compactMap { values[$0] }
        guard !digits.isEmpty, digits.count == text.count else { return nil }
        return digits.indices.reduce(0) { total, index in
            index + 1 < digits.count && digits[index] < digits[index + 1] ? total - digits[index] : total + digits[index]
        }
    }
}
