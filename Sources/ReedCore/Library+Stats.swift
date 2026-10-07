import Foundation
import SwiftData

extension Library {
    /// Credits the words between how far `readable` was ever read and `progress`.
    func creditReading(_ readable: any Readable, through progress: Double, at date: Date = .now) {
        credit(readable, through: progress, at: date, furthest: \.furthestRead, words: \.readWords)
    }

    /// Credits the words between how far `readable` was ever listened to and `progress`, but no more than `share`
    /// of it, the passage just heard, so skipping ahead doesn't count what was skipped.
    public func creditListening(_ readable: any Readable, through progress: Double, share: Double, at date: Date = .now) {
        credit(readable, through: progress, at: date, furthest: \.furthestListened, words: \.listenedWords, limit: share)
        save()
    }

    /// Notes when `readable` was first finished, whether or not anything of it was counted.
    func noteFinished(_ readable: any Readable, at date: Date = .now) {
        guard readingRecords.first(where: { $0.id == readable.id })?.finishedAt == nil else { return }
        let record = readingRecord(for: readable, at: date)
        record.finishedAt = date
    }

    private func credit(_ readable: any Readable, through progress: Double, at date: Date,
                        furthest: ReferenceWritableKeyPath<ReadingRecord, Double>,
                        words: ReferenceWritableKeyPath<ReadingDay, Double>, limit: Double = 1) {
        let progress = min(max(progress, 0), 1)
        let existing = readingRecords.first { $0.id == readable.id }
        let before = existing?[keyPath: furthest] ?? 0
        guard progress > before, readable.wordCount > 0 else { return }
        let record = existing ?? readingRecord(for: readable, at: date)
        record[keyPath: furthest] = progress
        record.lastReadAt = date
        day(date, of: record)[keyPath: words] += min(progress - before, limit) * Double(record.wordCount)
    }

    /// The record of `readable`, made if it has none, and brought up to date with its title and length.
    private func readingRecord(for readable: any Readable, at date: Date) -> ReadingRecord {
        let record: ReadingRecord
        if let existing = readingRecords.first(where: { $0.id == readable.id }) {
            record = existing
        } else {
            record = ReadingRecord(id: readable.id, title: readable.title, url: nil, source: readable.source,
                                   isChapter: readable is BookChapter, wordCount: 0, at: date)
            container.mainContext.insert(record)
            readingRecords.append(record)
        }
        record.title = readable.title
        record.source = readable.source
        record.url = (readable as? Article)?.sourceURL?.absoluteString
        record.wordCount = readable.wordCount
        return record
    }

    private func day(_ date: Date, of record: ReadingRecord) -> ReadingDay {
        let start = Calendar.current.startOfDay(for: date)
        if let day = record.days.first(where: { $0.day == start }) { return day }
        let day = ReadingDay(day: start)
        container.mainContext.insert(day)
        record.days.append(day)
        return day
    }

    /// A chapter converted again is a new chapter, so its record follows it.
    func moveReadingRecord(from old: UUID, to new: UUID) {
        readingRecords.first { $0.id == old }?.id = new
    }

    /// Records what was read before reading was recorded, on the day each was first opened, the first time the library opens with none.
    func loadReadingRecords() throws {
        readingRecords = try container.mainContext.fetch(FetchDescriptor<ReadingRecord>())
        guard readingRecords.isEmpty else { return }
        let chapters = books.flatMap { book in book.chapters.map { ($0 as any Readable, book.openedAt ?? book.addedAt) } }
        for (readable, date) in (articles + cached).map({ ($0 as any Readable, $0.openedAt ?? $0.savedAt) }) + chapters {
            creditReading(readable, through: readable.progress, at: date)
            if readable.isRead { noteFinished(readable, at: date) }
        }
        try container.mainContext.save()
    }
}
