import Foundation

public struct DownloadedPage: Sendable {
    public let html: String
    public let url: URL
}

/// A feed fetched with the validators from its last fetch.
public enum FeedDownload: Sendable {
    case unchanged
    case fetched(Data, url: URL, etag: String?, lastModified: String?)
}

public actor ArticleDownloader {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15 Reed/0.1"
    private let session: URLSession

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func page(at url: URL) async throws -> DownloadedPage {
        let (data, response) = try await fetch(Self.readablePage(for: url), limit: 8 * 1024 * 1024, kind: .html)
        let encoding: String.Encoding
        switch response.textEncodingName?.lowercased() {
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252": encoding = .windowsCP1252
        case "utf-16": encoding = .utf16
        default: encoding = .utf8
        }
        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .windowsCP1252),
              let finalURL = response.url else { throw ReedError.unsupportedContent }
        return DownloadedPage(html: html, url: finalURL)
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
        try await fetch(url, limit: 12 * 1024 * 1024, kind: .image).0
    }

    public func json(at url: URL) async throws -> Data {
        try await fetch(url, limit: 2 * 1024 * 1024, kind: .json).0
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

    private enum Kind { case html, image, json, resource, feed }

    private func fetch(_ url: URL, limit: Int, kind: Kind) async throws -> (Data, HTTPURLResponse) {
        try await fetch(URLRequest(url: url), limit: limit, kind: kind)
    }

    private func fetch(_ request: URLRequest, limit: Int, kind: Kind) async throws -> (Data, HTTPURLResponse) {
        _ = try ArticleURL.parse(request.url?.absoluteString ?? "")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReedError.unsupportedContent }
        if kind == .feed && response.statusCode == 304 { return (Data(), response) }
        guard (200..<300).contains(response.statusCode) else { throw ReedError.httpStatus(response.statusCode) }
        let mime = response.mimeType?.lowercased() ?? ""
        switch kind {
        case .html:
            guard ["text/html", "application/xhtml+xml"].contains(mime) else { throw ReedError.unsupportedContent }
        case .json:
            guard mime == "application/json" else { throw ReedError.unsupportedContent }
        case .resource:
            guard ["application/json", "text/html", "application/xhtml+xml"].contains(mime) else { throw ReedError.unsupportedContent }
        case .image:
            guard ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heic", "image/bmp", "image/tiff", "image/svg+xml"].contains(mime) else { throw ReedError.unsupportedContent }
        case .feed:
            break
        }
        guard response.expectedContentLength <= limit else { throw ReedError.oversizedDownload }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), limit))
        for try await byte in bytes {
            if data.count % 16384 == 0 { try Task.checkCancellation() }
            guard data.count < limit else { throw ReedError.oversizedDownload }
            data.append(byte)
        }
        return (data, response)
    }
}
