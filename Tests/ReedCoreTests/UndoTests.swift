import Foundation
import Testing
@testable import ReedCore

@Test func shareableURLsLoseTrackingOnly() throws {
    func shared(_ address: String) -> String { ArticleURL.shareable(URL(string: address)!).absoluteString }
    #expect(shared("https://example.com/a?utm_source=x&utm_medium=y&id=4&fbclid=z") == "https://example.com/a?id=4")
    #expect(shared("https://example.com/a?utm_campaign=x") == "https://example.com/a")
    #expect(shared("https://example.com/a?edition=2") == "https://example.com/a?edition=2")
    #expect(shared("https://www.youtube.com/watch?v=abc&si=q&feature=shared") == "https://www.youtube.com/watch?v=abc")
    #expect(shared("https://example.com/search?s=reed&t=1") == "https://example.com/search?s=reed&t=1")
    #expect(shared("https://x.com/someone/status/1?s=20&t=abc") == "https://x.com/someone/status/1")
    #expect(shared("https://writer.substack.com/p/post?r=2b4&utm_medium=ios") == "https://writer.substack.com/p/post")
}

@MainActor @Test func deletesCanBeUndoneUntilCommitted() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(root: root)
    let first = try library.add("https://reed.invalid/first")
    let second = try library.add("https://reed.invalid/second")
    try library.add("https://reed.invalid/third")
    await library.idle()

    let pending = try #require(library.deleteUndoably(second))
    #expect(!library.articles.contains { $0.id == second.id })
    library.undo(pending)
    #expect(library.articles.map(\.id)[1] == second.id)
    library.commit(pending)
    #expect(library.articles.contains { $0.id == second.id })

    let deleted = try #require(library.deleteUndoably(first))
    library.commit(deleted)
    #expect(!library.articles.contains { $0.id == first.id })
    // Not committed before Reed closed, so erased when it opens again.
    _ = try #require(library.deleteUndoably(second))
    let reopened = try Library(root: root)
    #expect(reopened.articles.map(\.originalURL) == ["https://reed.invalid/third"])
    await reopened.idle()
}

@MainActor @Test func finishingCanBeUndone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(root: root)
    let article = try library.add("https://reed.invalid/story")
    let other = try library.add("https://reed.invalid/other")
    await library.idle()
    library.toggleRead(other)
    library.toggleRead(other)

    let mark = library.markFinished([article, other])
    #expect(article.isRead && other.isRead)
    library.undo(mark)
    #expect(!article.isRead && !other.isRead)
    #expect(library.readingRecords.first { $0.id == article.id }?.finishedAt == nil)
    // Finished before, so it stays counted as finished once.
    #expect(library.readingRecords.first { $0.id == other.id }?.finishedAt != nil)
}
