import Foundation
import Synchronization
import Testing
@testable import ReedCore

@Test func retriesBackOffOnlyForFailuresThatMayPass() {
    var failures = 0
    #expect(SaveRetry.wait(after: URLError(.notConnectedToInternet), failures: &failures) == SaveRetry.offlineWait)
    #expect(failures == 0)
    #expect(SaveRetry.wait(after: ReedError.httpStatus(404), failures: &failures) == nil)
    #expect(SaveRetry.wait(after: ReedError.unsupportedContent, failures: &failures) == nil)
    #expect(failures == 0)
    let waits = (0..<SaveRetry.backoff.count).map { _ in SaveRetry.wait(after: ReedError.httpStatus(503), failures: &failures) }
    #expect(waits == SaveRetry.backoff)
    #expect(SaveRetry.wait(after: URLError(.timedOut), failures: &failures) == nil)
}

@MainActor @Test func savesWaitThroughABusySiteThenFailForGood() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubServer.self]
    let library = try Library(root: root, downloader: ArticleDownloader(session: URLSession(configuration: configuration)))
    defer { StubServer.respond = nil }

    StubServer.respond = { _ in .failure(URLError(.notConnectedToInternet)) }
    let article = try library.add("https://stub.test/story")
    await library.idle()
    guard case .waiting(_, 0, "Waiting for a connection to save.") = article.saveState else { Issue.record("\(article.saveState)"); return }

    StubServer.respond = { _ in .success(503) }
    library.retryWaiting()
    await library.idle()
    guard case .waiting(_, 1, let reason) = article.saveState, reason.contains("503") else { Issue.record("\(article.saveState)"); return }
    #expect(library.retryWake != nil)

    StubServer.respond = { _ in .success(404) }
    library.retryWaiting()
    await library.idle()
    guard case .failed(let reason) = article.saveState, reason.contains("404") else { Issue.record("\(article.saveState)"); return }
}

@MainActor @Test func launchingTriesWaitingSavesAgain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(root: root)
    let article = try library.add("https://reed.invalid/story")
    await library.idle()
    article.saveState = .waiting(until: .distantFuture, failures: 2, reason: "")
    library.save()
    let reopened = try Library(root: root)
    #expect(reopened.articles.first?.saveState == .queued(failures: 2))
    await reopened.idle()
}

private final class StubServer: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) -> Result<Int, URLError>)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.respond?(request) ?? .success(500) {
        case .success(let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@MainActor @Test func aHostThatDoesNotAnswerIsAskedForFewOfItsImages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ImageServer.self]
    let library = try Library(root: root, downloader: ArticleDownloader(session: URLSession(configuration: configuration)))
    let images = (0..<12).map { index in
        ExtractedArticle.Image(url: "https://\(index.isMultiple(of: 3) ? "good" : "slow").test/\(index).png", filename: "\(index).png", alt: "")
    }
    let directory = try library.storage.createStagingDirectory()
    let missing = try await library.saveImages(images, pictures: [:], into: directory) { _ in }
    #expect(missing.map(\.filename) == images.filter { $0.url.contains("slow") }.map(\.filename))
    #expect(ImageServer.slowRequests.withLock { $0 } <= Library.imageFetches)
    for index in stride(from: 0, to: 12, by: 3) {
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(index).png").path))
    }
}

@Test func largeDownloadsAreGivenTimeBySize() {
    #expect(ArticleDownloader.Receiver.time(for: 1024) == ArticleDownloader.Receiver.leastTime)
    // A 64MB PDF on a connection managing 64KB a second.
    #expect(ArticleDownloader.Receiver.time(for: 64 * 1024 * 1024) >= 1024)
}

@MainActor @Test func replacedVersionsAreKeptWhileOpen() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(root: root)
    let id = UUID(), version = UUID().uuidString
    let folder = library.storage.articleDirectory(id).appendingPathComponent(version, isDirectory: true)
    let audio = library.storage.audioDirectory(id, version: version, voice: "voice")
    for url in [folder, audio] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    library.retained = [id]
    library.retire(version, of: .article(id), heldBy: [id])
    #expect(FileManager.default.fileExists(atPath: folder.path))
    library.retained = [UUID()]
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(!FileManager.default.fileExists(atPath: audio.path))
}

@Test func leftoverVersionsGoButNotTheCurrentOneOrNewerOnes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let current = UUID().uuidString, leftover = UUID().uuidString
    for name in [current, leftover, "Discussions"] {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let before = Date.now.addingTimeInterval(1)
    let newer = UUID().uuidString
    try FileManager.default.createDirectory(at: directory.appendingPathComponent(newer), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.creationDate: before.addingTimeInterval(60)], ofItemAtPath: directory.appendingPathComponent(newer).path)
    ArticleStorage.removeVersions(in: directory, except: current, madeBefore: before)
    let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    #expect(left == [current, "Discussions", newer])
}

@Test func audioNotListenedToLatelyGoesButTheRestStays() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ArticleStorage(root: root)
    let stale = UUID(), heard = UUID(), book = UUID(), version = UUID().uuidString
    let staleAudio = storage.audioDirectory(stale, version: version, voice: "voice")
    let heardAudio = storage.audioDirectory(heard, version: version, voice: "voice")
    let bookAudio = storage.audioDirectory(.chapter(book: book, index: 0), version: version, voice: "voice")
    for url in [staleAudio, heardAudio, bookAudio, storage.articleDirectory(stale).appendingPathComponent(version)] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    let longAgo = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
    for location in [ReadableLocation.article(stale), .article(heard), .chapter(book: book, index: 0)] {
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: storage.audioRoot(location).path)
    }
    storage.noteListened(.article(heard))
    storage.removeAudio(unheardSince: Date.now.addingTimeInterval(-60))
    #expect(!FileManager.default.fileExists(atPath: storage.audioRoot(.article(stale)).path))
    #expect(!FileManager.default.fileExists(atPath: storage.audioRoot(.chapter(book: book, index: 0)).path))
    #expect(FileManager.default.fileExists(atPath: storage.articleDirectory(stale).appendingPathComponent(version).path))
    #expect(FileManager.default.fileExists(atPath: heardAudio.path))
}

private final class ImageServer: URLProtocol {
    static let slowRequests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host() == "slow.test" {
            Self.slowRequests.withLock { $0 += 1 }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x89, 0x50, 0x4E, 0x47]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func pausingPutsWhatWasBeingSavedBackInTheQueue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SilentServer.self]
    let library = try Library(root: root, downloader: ArticleDownloader(session: URLSession(configuration: configuration)))
    let article = try library.add("https://stub.test/story")
    while article.saveState != .downloading(failures: 0) { await Task.yield() }
    #expect(library.hasPendingSaves)
    library.pauseDownloads()
    await library.idle()
    #expect(article.saveState == .queued(failures: 0))
}

@MainActor @Test func savingEverythingAddsWhatWasShared() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = ShareInbox(directory: root.appendingPathComponent("Inbox"))
    try inbox.deposit(URL(string: "https://reed.invalid/story")!)
    #expect(!inbox.isEmpty)
    let library = try Library(root: root.appendingPathComponent("Library"))
    await library.saveAll(from: inbox)
    #expect(inbox.isEmpty)
    #expect(library.articles.map(\.originalURL) == ["https://reed.invalid/story"])
    // Tried, and left to retry, as the host can't be found.
    guard case .waiting = library.articles.first?.saveState else { Issue.record("\(String(describing: library.articles.first?.saveState))"); return }
}

/// Never answers, so a save stays in progress until it's cancelled.
private final class SilentServer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@MainActor @Test func pausingLeavesRetriesForLater() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(root: root)
    let article = try library.add("https://reed.invalid/story")
    await library.idle()
    guard case .waiting = article.saveState else { Issue.record("\(article.saveState)"); return }
    library.resumeDownloads()
    library.pauseDownloads()
    await library.idle()
    #expect(library.retryWake == nil)
}
