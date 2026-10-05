import Foundation

/// Links, PDFs and EPUBs handed from the share extension to the app, kept in the App Group container they share.
/// Each is its own file, so the two processes never write to the same file.
public struct ShareInbox: Sendable {
    public let directory: URL

    public enum Item: Equatable, Sendable {
        case link(String)
        /// A shared PDF, and the name it was shared under.
        case pdf(URL, name: String)
        /// A shared EPUB, and the name it was shared under.
        case book(URL, name: String)
    }

    #if os(macOS)
    // macOS accepts team-prefixed groups without a provisioning profile.
    public static let appGroup = "KR4TU3GTWZ.town.versary.reed"
    #else
    public static let appGroup = "group.town.versary.reed"
    #endif
    /// Posted in-process after another process deposits a link; see `forwardDeposits()`.
    public static let didDeposit = Notification.Name("town.versary.reed.inbox")

    public init(directory: URL) { self.directory = directory }

    /// Nil when the process lacks the App Group entitlement.
    public static var shared: ShareInbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { ShareInbox(directory: $0.appendingPathComponent("Inbox", isDirectory: true)) }
    }

    public func deposit(_ url: URL) throws {
        let file = try nextFile(extension: "link")
        try Data(url.absoluteString.utf8).write(to: file, options: .atomic)
        announce()
    }

    /// Copies the PDF at `file`, which may be gone once the share extension finishes, under `name` or its own.
    public func deposit(pdfAt file: URL, name: String? = nil) throws {
        try deposit(file, name: name, extension: "pdf")
    }

    /// Copies the EPUB at `file`, as `deposit(pdfAt:name:)` does a PDF.
    public func deposit(bookAt file: URL, name: String? = nil) throws {
        try deposit(file, name: name, extension: "epub")
    }

    private func deposit(_ file: URL, name: String?, extension pathExtension: String) throws {
        var name = (name ?? file.lastPathComponent).replacingOccurrences(of: "/", with: "-")
        if !name.lowercased().hasSuffix("." + pathExtension) { name += "." + pathExtension }
        let destination = try nextFile(extension: pathExtension, named: name)
        // Copied under another extension and then renamed, so the app never reads half a file.
        let partial = destination.appendingPathExtension("partial")
        try FileManager.default.copyItem(at: file, to: partial)
        try FileManager.default.moveItem(at: partial, to: destination)
        announce()
    }

    /// A millisecond prefix keeps the files in the order they were shared. Files shared within the same
    /// millisecond take the next free one, since the UUID after it would order them randomly.
    private func nextFile(extension pathExtension: String, named name: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let latest = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .compactMap { UInt64($0.prefix(while: \.isNumber)) }.max() ?? 0
        let stamp = max(UInt64(Date().timeIntervalSince1970 * 1000), latest + 1)
        let prefix = String(format: "%013llu-%@", stamp, UUID().uuidString)
        return directory.appendingPathComponent(name.map { prefix + " " + $0 } ?? prefix + "." + pathExtension)
    }

    private func announce() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(Self.didDeposit.rawValue as CFString), nil, nil, true)
    }

    /// Hands each item to `save`, oldest first, removing it once saved.
    /// Stops at the first error, leaving that item and the rest for next time.
    public func drain(_ save: (Item) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["link", "pdf", "epub"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            if file.pathExtension == "link" {
                try save(.link(String(decoding: try Data(contentsOf: file), as: UTF8.self)))
            } else {
                // The name follows the stamp, the UUID and a space.
                let shared = String(file.lastPathComponent.drop { $0 != " " }.dropFirst())
                let name = shared.isEmpty ? file.lastPathComponent : shared
                try save(file.pathExtension.lowercased() == "epub" ? .book(file, name: name) : .pdf(file, name: name))
            }
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Re-posts deposits from other processes as `didDeposit` on the default notification center.
    public static func forwardDeposits() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: ShareInbox.didDeposit, object: nil) }
        }, didDeposit.rawValue as CFString, nil, .deliverImmediately)
    }
}
