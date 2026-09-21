import Foundation
import SwiftData
import Testing
@testable import ReedCore

@Test func canonicalURLs() throws {
    #expect(try ArticleURL.parse("  EXAMPLE.com/story#heading  ").absoluteString == "https://example.com/story")
    #expect(try ArticleURL.parse("https://example.com:443").absoluteString == "https://example.com/")
    #expect(try ArticleURL.parse("http://example.com:80/a?edition=2").absoluteString == "http://example.com/a?edition=2")
    for input in ["", "not a url", "file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com", "https://"] {
        #expect(throws: (any Error).self) { try ArticleURL.parse(input) }
    }
}

@Test func articlePackagesSurviveStorageRecreation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ArticleStorage(root: root)
    let staging = try storage.createStagingDirectory()
    let id = UUID()
    try "<h1>Offline article</h1>".write(to: staging.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try Data([1, 2, 3]).write(to: staging.appendingPathComponent("image-0"))
    #expect(!FileManager.default.fileExists(atPath: storage.contentURL(id, version: "one").path))
    try storage.commit(staging: staging, id: id, version: "one")
    let reopened = try ArticleStorage(root: root)
    #expect(try String(contentsOf: reopened.contentURL(id, version: "one"), encoding: .utf8) == "<h1>Offline article</h1>")
    #expect(try Data(contentsOf: reopened.articleDirectory(id).appendingPathComponent("one/image-0")) == Data([1, 2, 3]))
    try reopened.removeArticle(id)
    #expect(!FileManager.default.fileExists(atPath: reopened.articleDirectory(id).path))
}

@Test func failedReplacementPreservesExistingArticle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ArticleStorage(root: root)
    let id = UUID()
    let first = try storage.createStagingDirectory()
    try "Original".write(to: first.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try storage.commit(staging: first, id: id, version: "original")
    #expect(throws: (any Error).self) {
        try storage.commit(staging: root.appendingPathComponent("nonexistent"), id: id, version: "replacement")
    }
    #expect(try String(contentsOf: storage.contentURL(id, version: "original"), encoding: .utf8) == "Original")
}

@Test func readerEscapesMetadataAndBlocksNetwork() {
    let html = ArticleHTML.document(title: "<script>alert('x')</script>", author: "<img src=x onerror=x>", domain: "example.com", minutes: 3, body: "<p>Trusted sanitized body</p>")
    #expect(!html.contains("<script>"))
    #expect(html.contains("&lt;script&gt;"))
    #expect(html.contains("default-src 'none'; img-src file:"))
    #expect(!html.contains("https://"))
}

@Test @MainActor func persistedMetadataAndInterruptedDownloads() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ArticleStorage(root: root)
    let configuration = ModelConfiguration(url: root.appendingPathComponent("Library.store"))
    do {
        let container = try ModelContainer(for: Article.self, configurations: configuration)
        let article = Article(url: URL(string: "https://example.com/story")!)
        article.state = .downloading
        article.isFavorite = true
        article.progress = 0.45
        container.mainContext.insert(article)
        try container.mainContext.save()
    }
    let library = try Library(root: storage.root)
    #expect(library.articles.count == 1)
    #expect(library.articles[0].state == .queued)
    #expect(library.articles[0].isFavorite)
    #expect(library.articles[0].progress == 0.45)
}

@Test @MainActor func missingOfflineFilesAreNotReportedAsReady() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try ArticleStorage(root: root)
    do {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store")))
        let article = Article(url: URL(string: "https://example.com/missing")!)
        article.state = .ready
        article.contentVersion = "gone"
        container.mainContext.insert(article)
        try container.mainContext.save()
    }
    let library = try Library(root: root)
    #expect(library.articles[0].state == .failed)
    #expect(library.articles[0].failureMessage == ReedError.damagedArticle.localizedDescription)
}

@Test @MainActor func deletionRemovesMetadataAndArticleFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ArticleStorage(root: root)
    let id = UUID()
    let staging = try storage.createStagingDirectory()
    try "Saved article".write(to: staging.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try storage.commit(staging: staging, id: id, version: "v1")
    do {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store")))
        let article = Article(url: URL(string: "https://example.com/deleted")!, id: id)
        article.state = .ready
        article.contentVersion = "v1"
        container.mainContext.insert(article)
        try container.mainContext.save()
    }
    let library = try Library(root: root)
    library.delete(library.articles[0])
    #expect(library.errorMessage == nil)
    #expect(library.articles.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: storage.articleDirectory(id).path))
    let reopened = try Library(root: root)
    #expect(reopened.articles.isEmpty)
}
