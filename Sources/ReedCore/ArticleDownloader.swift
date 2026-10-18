import Foundation

public struct DownloadedPage: Sendable {
    public let html: String
    public let url: URL
}

/// What a link to an article turned out to be.
public enum DownloadedDocument: Sendable {
    case page(DownloadedPage)
    case pdf(Data, url: URL)
}

/// A feed fetched with the validators from its last fetch.
public enum FeedDownload: Sendable {
    case unchanged
    case fetched(Data, url: URL, etag: String?, lastModified: String?)
}

public actor ArticleDownloader {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15 Reed/0.1"
    /// Wikimedia asks programs to name themselves and how to reach whoever runs them, and limits those that pass as browsers.
    static let wikimediaUserAgent = "Reed/0.1 (https://github.com/annieversary/reed)"
    private let session: URLSession

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // Only a backstop: each download is given time by its size, as `Receiver` keeps.
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func page(at url: URL) async throws -> DownloadedPage {
        let (data, response) = try await fetch(Self.readablePage(for: url), limit: 8 * 1024 * 1024, kind: .html)
        return try Self.page(from: data, response: response)
    }

    /// The page at `url`, or the PDF it serves.
    public func document(at url: URL) async throws -> DownloadedDocument {
        let (data, response) = try await fetch(Self.readablePage(for: url), limit: 8 * 1024 * 1024, kind: .document)
        if data.starts(with: Data("%PDF".utf8)) { return .pdf(data, url: response.url ?? url) }
        guard Self.htmlTypes.contains(response.mimeType?.lowercased() ?? "") else { throw ReedError.unsupportedContent }
        return .page(try Self.page(from: data, response: response))
    }

    /// The PDF at `url`, as it is.
    public func pdf(at url: URL) async throws -> (data: Data, url: URL) {
        let (data, response) = try await fetch(url, limit: 8 * 1024 * 1024, kind: .document)
        guard data.starts(with: Data("%PDF".utf8)) else { throw ReedError.unsupportedContent }
        return (data, response.url ?? url)
    }

    private static func page(from data: Data, response: HTTPURLResponse) throws -> DownloadedPage {
        guard let html = text(of: data, declared: response.textEncodingName), let finalURL = response.url else {
            throw ReedError.unsupportedContent
        }
        return DownloadedPage(html: html, url: finalURL)
    }

    /// A page's text, in the encoding its header names, or else its `<meta>` tag, falling back to UTF-8 and then Windows-1252.
    static func text(of data: Data, declared: String?) -> String? {
        let named = (declared ?? metaCharset(in: data)).flatMap(encoding(named:))
        for encoding in [named, .utf8, .windowsCP1252].compactMap({ $0 }) {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    /// Labels that browsers read as a broader encoding, since pages labelled with them use its extra characters.
    private static let broaderEncodings = [
        "iso-8859-1": "windows-1252", "latin1": "windows-1252", "us-ascii": "windows-1252", "ascii": "windows-1252",
        "gb2312": "gb18030", "gbk": "gb18030", "x-gbk": "gb18030",
        "euc-kr": "windows-949", "ks_c_5601-1987": "windows-949",
        "shift_jis": "windows-31j", "sjis": "windows-31j", "x-sjis": "windows-31j",
    ]

    static func encoding(named name: String) -> String.Encoding? {
        let label = name.trimmingCharacters(in: .whitespaces).lowercased()
        let cf = CFStringConvertIANACharSetNameToEncoding((broaderEncodings[label] ?? label) as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// The charset a page names in a `<meta>` tag near its start.
    static func metaCharset(in data: Data) -> String? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        guard let match = head.firstMatch(of: /(?i)<meta\b[^>]*?charset\s*=\s*["']?\s*([A-Za-z0-9_.:\-]+)/) else { return nil }
        let name = String(match.1)
        // A tag read as ASCII can't be UTF-16, so browsers take it to mean UTF-8.
        return name.lowercased().hasPrefix("utf-16") ? "utf-8" : name
    }

    /// The PDF of an arXiv paper saved from its abstract page without the paper itself, because arXiv has no
    /// HTML rendering of it or couldn't make one.
    static func arxivPDF(for url: URL, extracted html: String) -> URL? {
        guard let host = url.host(), host == "arxiv.org" || host.hasSuffix(".arxiv.org"),
              url.path().hasPrefix("/abs/"), !html.contains("<h2>Paper</h2>") else { return nil }
        return URL(string: "https://arxiv.org/pdf/" + url.path().dropFirst("/abs/".count))
    }

    /// arXiv's PDF and HTML renderings, as their abstract page, which links to the HTML when there is one.
    static func readablePage(for url: URL) -> URL {
        guard let host = url.host(), host == "arxiv.org" || host.hasSuffix(".arxiv.org"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let parts = components.path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["pdf", "html"].contains(parts[0]) else { return url }
        var id = parts[1]
        if id.hasSuffix("/") { id.removeLast() }
        if id.hasSuffix(".pdf") { id.removeLast(4) }
        components.path = "/abs/" + id
        components.fragment = nil
        return components.url ?? url
    }

    /// Same-origin JSON or HTML a site rule asks for.
    public func resource(at url: URL) async throws -> Data {
        try await fetch(url, limit: 8 * 1024 * 1024, kind: .resource).0
    }

    public func image(at url: URL) async throws -> Data {
        // Pictures are fetched beside each other, so one host that doesn't answer is better given up on soon.
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        return try await fetch(request, limit: 12 * 1024 * 1024, kind: .image).0
    }

    /// JSON, sent with `cookie` alone when one is given.
    public func json(at url: URL, cookie: String? = nil, limit: Int = 2 * 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: url)
        if let cookie {
            request.httpShouldHandleCookies = false
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return try await fetch(request, limit: limit, kind: .json).0
    }

    /// The JSON answer to POSTing `body` as JSON.
    public func json(posting body: Data, to url: URL, userAgent: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        return try await fetch(request, limit: 2 * 1024 * 1024, kind: .json).0
    }

    /// A feed, or a page that may link to one; the content type isn't checked, since feeds are served under many.
    public func feed(at url: URL, etag: String? = nil, lastModified: String? = nil) async throws -> FeedDownload {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        request.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, text/html;q=0.8, */*;q=0.5",
                         forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request, limit: 5 * 1024 * 1024, kind: .feed)
        if response.statusCode == 304 { return .unchanged }
        return .fetched(data, url: response.url ?? url, etag: response.value(forHTTPHeaderField: "ETag"),
                        lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
    }

    private enum Kind { case html, document, image, json, resource, feed }
    private static let htmlTypes = ["text/html", "application/xhtml+xml"]
    private static let pdfTypes = ["application/pdf", "application/x-pdf", "application/octet-stream", "binary/octet-stream"]

    private nonisolated func fetch(_ url: URL, limit: Int, kind: Kind) async throws -> (Data, HTTPURLResponse) {
        try await fetch(URLRequest(url: url), limit: limit, kind: kind)
    }

    /// Off the actor, so downloads running side by side don't take turns reading their responses.
    private nonisolated func fetch(_ request: URLRequest, limit: Int, kind: Kind) async throws -> (Data, HTTPURLResponse) {
        _ = try ArticleURL.parse(request.url?.absoluteString ?? "")
        var request = request
        if let host = request.url?.host(), Self.isWikimedia(host), request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.wikimediaUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let receiver = Receiver { response in try Self.limit(for: response, kind: kind, limit: limit) }
        let task = session.dataTask(with: request)
        task.delegate = receiver
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { receiver.start(task, continuation: $0) }
        } onCancel: {
            task.cancel()
        }
    }

    static func isWikimedia(_ host: String) -> Bool {
        ["wikipedia.org", "wikimedia.org"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// How large a response may be, once its status and type are acceptable for `kind`.
    private static func limit(for response: HTTPURLResponse, kind: Kind, limit: Int) throws -> Int {
        if kind == .feed && response.statusCode == 304 { return 0 }
        guard (200..<300).contains(response.statusCode) else { throw ReedError.httpStatus(response.statusCode) }
        let mime = response.mimeType?.lowercased() ?? ""
        switch kind {
        case .html:
            guard htmlTypes.contains(mime) else { throw ReedError.unsupportedContent }
        case .document:
            guard htmlTypes.contains(mime) || pdfTypes.contains(mime) else { throw ReedError.unsupportedContent }
        case .json:
            guard mime == "application/json" else { throw ReedError.unsupportedContent }
        case .resource:
            guard ["application/json", "text/html", "application/xhtml+xml"].contains(mime) else { throw ReedError.unsupportedContent }
        case .image:
            guard ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heic", "image/bmp", "image/tiff", "image/svg+xml"].contains(mime) else { throw ReedError.unsupportedContent }
        case .feed:
            break
        }
        // PDFs carry their pictures with them, so they may be larger than a page.
        let limit = kind == .document && pdfTypes.contains(mime) ? 64 * 1024 * 1024 : limit
        guard response.expectedContentLength <= limit else { throw ReedError.oversizedDownload }
        return limit
    }

    /// Gathers a response as it arrives, a piece at a time, and stops it as soon as it's refused, grows past its limit
    /// or runs out of time.
    final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        /// The time any download is given.
        static let leastTime: TimeInterval = 60
        /// The slowest a download may arrive, on average, in bytes a second, so a large one has time to finish on a slow connection.
        static let slowestRate: Double = 64 * 1024

        /// How long a response of up to `limit` bytes is given to arrive.
        static func time(for limit: Int) -> TimeInterval { max(leastTime, Double(limit) / slowestRate) }

        private let lock = NSLock()
        private let check: @Sendable (HTTPURLResponse) throws -> Int
        private var limit = 0
        private var data = Data()
        private var response: HTTPURLResponse?
        private var failure: Error?
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var task: URLSessionTask?
        /// Counts the deadlines set, so one replaced by a later one passes unheeded.
        private var deadlines = 0

        init(check: @escaping @Sendable (HTTPURLResponse) throws -> Int) { self.check = check }

        func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            lock.withLock {
                self.continuation = continuation
                self.task = task
            }
            expire(after: Self.leastTime)
            task.resume()
        }

        /// Gives up on the download as timed out after `seconds`, unless another deadline is set first.
        private func expire(after seconds: TimeInterval) {
            let deadline = lock.withLock { deadlines += 1; return deadlines }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                let task = self.lock.withLock { () -> URLSessionTask? in
                    guard self.deadlines == deadline, self.continuation != nil, self.failure == nil else { return nil }
                    self.failure = URLError(.timedOut)
                    return self.task
                }
                task?.cancel()
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            do {
                guard let response = response as? HTTPURLResponse else { throw ReedError.unsupportedContent }
                let limit = try check(response)
                lock.withLock {
                    self.response = response
                    self.limit = limit
                    data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), limit))
                }
                expire(after: Self.time(for: limit))
                completionHandler(.allow)
            } catch {
                lock.withLock { failure = error }
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let fits = lock.withLock {
                guard self.data.count + data.count <= limit else { failure = ReedError.oversizedDownload; return false }
                self.data.append(data)
                return true
            }
            if !fits { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, result) = lock.withLock { () -> (CheckedContinuation<(Data, HTTPURLResponse), Error>?, Result<(Data, HTTPURLResponse), Error>) in
                defer { self.continuation = nil; self.task = nil }
                if let failure { return (self.continuation, .failure(failure)) }
                if let error = error as? URLError, error.code == .cancelled { return (self.continuation, .failure(CancellationError())) }
                if let error { return (self.continuation, .failure(error)) }
                guard let response else { return (self.continuation, .failure(ReedError.unsupportedContent)) }
                return (self.continuation, .success((data, response)))
            }
            continuation?.resume(with: result)
        }
    }
}
