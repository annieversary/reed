import Foundation
import SwiftData

/// What's been read of an article or book chapter, kept after it leaves the library so reading can be counted over time.
@Model
public final class ReadingRecord {
    /// The article's or chapter's ID.
    @Attribute(.unique) public var id: UUID
    public var title: String
    /// Where it can be found on the web; nil for a chapter or a shared file.
    public var url: String?
    /// The website, or the book.
    public var source: String
    public var isChapter: Bool
    /// Its length when last read.
    public var wordCount: Int
    /// How far through it was ever scrolled, and ever listened to, from 0 to 1. Going back over it counts nothing more.
    public var furthestRead: Double
    public var furthestListened: Double
    public var startedAt: Date
    public var lastReadAt: Date
    /// When it was first finished, kept if it's marked unread again.
    public var finishedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \ReadingDay.record) public var days: [ReadingDay]

    public init(id: UUID, title: String, url: String?, source: String, isChapter: Bool, wordCount: Int, at date: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.source = source
        self.isChapter = isChapter
        self.wordCount = wordCount
        furthestRead = 0
        furthestListened = 0
        startedAt = date
        lastReadAt = date
        days = []
    }

    public var readWords: Double { days.reduce(0) { $0 + $1.readWords } }
    public var listenedWords: Double { days.reduce(0) { $0 + $1.listenedWords } }
}

/// The words of one record read and listened to on one day.
@Model
public final class ReadingDay {
    public var record: ReadingRecord?
    /// The start of the day, in the calendar it was read in.
    public var day: Date
    public var readWords: Double
    public var listenedWords: Double

    public init(day: Date) {
        self.day = day
        readWords = 0
        listenedWords = 0
    }
}

public enum ReadingStats {
    public struct Totals: Equatable, Sendable {
        public var finished = 0
        public var readWords: Double = 0
        public var listenedWords: Double = 0

        public init(finished: Int = 0, readWords: Double = 0, listenedWords: Double = 0) {
            self.finished = finished
            self.readWords = readWords
            self.listenedWords = listenedWords
        }
    }

    public struct Period: Equatable, Sendable {
        public let start: Date
        public var readWords: Double
        public var listenedWords: Double
    }

    public struct Source: Equatable, Sendable {
        public let name: String
        public let words: Double
    }

    /// What was finished and how many words were taken in from `start` on, or ever if it's nil.
    public static func totals(_ records: [ReadingRecord], since start: Date? = nil) -> Totals {
        var totals = Totals()
        for record in records {
            if let finished = record.finishedAt, start.map({ finished >= $0 }) ?? true { totals.finished += 1 }
            for day in record.days where start.map({ day.day >= $0 }) ?? true {
                totals.readWords += day.readWords
                totals.listenedWords += day.listenedWords
            }
        }
        return totals
    }

    /// Words for each of the last `count` days, months or other `unit`s up to `now`, oldest first, including those with none.
    public static func periods(_ records: [ReadingRecord], by unit: Calendar.Component, count: Int, endingAt now: Date = .now,
                               calendar: Calendar = .current) -> [Period] {
        guard let last = calendar.dateInterval(of: unit, for: now)?.start else { return [] }
        let starts = (0..<count).reversed().compactMap { calendar.date(byAdding: unit, value: -$0, to: last) }
        var byStart = Dictionary(uniqueKeysWithValues: starts.map { ($0, Period(start: $0, readWords: 0, listenedWords: 0)) })
        for record in records {
            for entry in record.days {
                guard let start = calendar.dateInterval(of: unit, for: entry.day)?.start else { continue }
                byStart[start]?.readWords += entry.readWords
                byStart[start]?.listenedWords += entry.listenedWords
            }
        }
        return starts.compactMap { byStart[$0] }
    }

    /// Websites and books by words taken in, most first.
    public static func sources(_ records: [ReadingRecord], limit: Int) -> [Source] {
        var words: [String: Double] = [:]
        for record in records { words[record.source, default: 0] += record.readWords + record.listenedWords }
        return words.filter { $0.value >= 1 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { Source(name: $0.key, words: $0.value) }
    }
}
