import Foundation
import SwiftData
import Testing
@testable import ReedCore

/// A library holding one failed article of `words`, so nothing downloads, already read to `progress` before reading was recorded.
@MainActor private func library(words: Int, progress: Double = 0, isRead: Bool = false, root: URL) throws -> Library {
    _ = try ArticleStorage(root: root)
    do {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store")))
        let article = Article(url: URL(string: "https://example.com/essay")!)
        article.title = "Essay"
        article.wordCount = words
        article.progress = progress
        article.isRead = isRead
        article.state = .failed
        container.mainContext.insert(article)
        try container.mainContext.save()
    }
    return try Library(root: root)
}

@Test @MainActor func readingCountsOnlyWordsNotReadBefore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try library(words: 1000, root: root)
    let article = try #require(library.articles.first)
    library.updateProgress(article, value: 0.3)
    library.updateProgress(article, value: 0.1)
    library.updateProgress(article, value: 0.5)
    let record = try #require(library.readingRecords.first)
    #expect(abs(record.readWords - 500) < 0.001)
    #expect(record.url == "https://example.com/essay" && record.source == "example.com" && record.finishedAt == nil)
    // Scrolling while listening counts nothing as read.
    library.updateProgress(article, value: 0.8, listening: true)
    #expect(abs(record.readWords - 500) < 0.001)
}

@Test @MainActor func listeningCountsOnlyThePassageHeard() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try library(words: 1000, root: root)
    let article = try #require(library.articles.first)
    library.creditListening(article, through: 0.1, share: 0.1)
    // Skipped ahead, then heard one passage.
    library.creditListening(article, through: 0.6, share: 0.1)
    // Heard again.
    library.creditListening(article, through: 0.2, share: 0.1)
    let record = try #require(library.readingRecords.first)
    #expect(abs(record.listenedWords - 200) < 0.001 && record.readWords == 0)
}

@Test @MainActor func markingFinishedCountsNoWords() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try library(words: 1000, root: root)
    let article = try #require(library.articles.first)
    library.toggleRead(article)
    let record = try #require(library.readingRecords.first)
    let finished = try #require(record.finishedAt)
    #expect(record.readWords == 0)
    // Unread and finished again keeps when it was first finished.
    library.toggleRead(article)
    library.toggleRead(article)
    #expect(record.finishedAt == finished)
    #expect(ReadingStats.totals(library.readingRecords) == ReadingStats.Totals(finished: 1))
}

@Test @MainActor func recordsOutliveTheirArticles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try library(words: 400, root: root)
    let article = try #require(library.articles.first)
    library.updateProgress(article, value: 1)
    library.delete(article)
    let reopened = try Library(root: root)
    #expect(reopened.articles.isEmpty)
    let record = try #require(reopened.readingRecords.first)
    #expect(record.title == "Essay" && abs(record.readWords - 400) < 0.001 && record.finishedAt != nil)
}

@Test @MainActor func readingBeforeRecordsBeganIsCountedOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try library(words: 1000, progress: 0.4, isRead: true, root: root)
    #expect(ReadingStats.totals(library.readingRecords) == ReadingStats.Totals(finished: 1, readWords: 400))
    let reopened = try Library(root: root)
    #expect(ReadingStats.totals(reopened.readingRecords) == ReadingStats.Totals(finished: 1, readWords: 400))
}

@Test @MainActor func wordsAreGroupedByPeriod() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try library(words: 1000, root: root)
    let article = try #require(library.articles.first)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let today = calendar.startOfDay(for: .now)
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
    let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: today))
    library.creditReading(article, through: 0.25, at: twoDaysAgo.addingTimeInterval(3600))
    library.creditReading(article, through: 0.75, at: today.addingTimeInterval(3600))
    let days = ReadingStats.periods(library.readingRecords, by: .day, count: 3, endingAt: today, calendar: calendar)
    #expect(days.map(\.start) == [twoDaysAgo, yesterday, today])
    #expect(days.map(\.readWords) == [250, 0, 500])
    #expect(ReadingStats.totals(library.readingRecords, since: today).readWords == 500)
}
