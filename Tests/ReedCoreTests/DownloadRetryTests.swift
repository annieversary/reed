import Foundation
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
    #expect(article.isWaitingToRetry)
    #expect(article.failedAttempts == 0)
    #expect(article.failureMessage == "Waiting for a connection to save.")

    StubServer.respond = { _ in .success(503) }
    library.retryWaiting()
    await library.idle()
    #expect(article.isWaitingToRetry)
    #expect(article.failedAttempts == 1)
    #expect(article.failureMessage?.contains("503") == true)
    #expect(library.retryWake != nil)

    StubServer.respond = { _ in .success(404) }
    library.retryWaiting()
    await library.idle()
    #expect(article.state == .failed)
    #expect(article.retryAt == nil && article.failedAttempts == 0)
    #expect(article.failureMessage?.contains("404") == true)
}

@MainActor @Test func launchingTriesWaitingSavesAgain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(root: root)
    let article = try library.add("https://reed.invalid/story")
    await library.idle()
    article.retryAt = .distantFuture
    library.save()
    let reopened = try Library(root: root)
    #expect(reopened.articles.first?.retryAt == nil)
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
