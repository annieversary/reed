import Foundation
import os

/// Text bundled with ReedCore, such as the scripts run in web views. Each file is read once and kept.
public enum BundledResource {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())

    public static func text(_ name: String, extension ext: String) throws -> String {
        let key = name + "." + ext
        if let known = cache.withLock({ $0[key] }) { return known }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: ext) else { throw CocoaError(.fileNoSuchFile) }
        let text = try String(contentsOf: url, encoding: .utf8)
        cache.withLock { $0[key] = text }
        return text
    }

    /// The scripts that turn a page or a book's chapter into a saved article, in the order they run.
    static func extractionScript() throws -> String {
        try ["Readability", "purify.min", "temml.min", "MathMarkup", "SiteRules", "PageLinks", "ExtractArticle"]
            .map { try text($0, extension: "js") }.joined(separator: "\n")
    }
}
