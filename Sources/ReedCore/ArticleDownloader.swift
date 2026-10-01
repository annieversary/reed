import Foundation

public struct DownloadedPage: Sendable {
    public let html: String
    public let url: URL
}

public actor ArticleDownloader {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15 Reed/0.1"]
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func page(at url: URL) async throws -> DownloadedPage {
        let (data, response) = try await fetch(url, limit: 8 * 1024 * 1024, kind: .html)
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

    public func image(at url: URL) async throws -> Data {
        try await fetch(url, limit: 12 * 1024 * 1024, kind: .image).0
    }

    public func json(at url: URL) async throws -> Data {
        try await fetch(url, limit: 2 * 1024 * 1024, kind: .json).0
    }

    private enum Kind { case html, image, json }

    private func fetch(_ url: URL, limit: Int, kind: Kind) async throws -> (Data, HTTPURLResponse) {
        _ = try ArticleURL.parse(url.absoluteString)
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else { throw ReedError.unsupportedContent }
        guard (200..<300).contains(response.statusCode) else { throw ReedError.httpStatus(response.statusCode) }
        let mime = response.mimeType?.lowercased() ?? ""
        switch kind {
        case .html:
            guard ["text/html", "application/xhtml+xml"].contains(mime) else { throw ReedError.unsupportedContent }
        case .json:
            guard mime == "application/json" else { throw ReedError.unsupportedContent }
        case .image:
            guard ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heic", "image/bmp", "image/tiff"].contains(mime) else { throw ReedError.unsupportedContent }
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
