import Foundation

/// Links handed from the share extension to the app, kept in the App Group container they share.
/// Each link is its own file, so the two processes never write to the same file.
public struct ShareInbox: Sendable {
    public let directory: URL

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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A millisecond prefix keeps the files in the order they were shared. Links shared within
        // the same millisecond take the next free one, since the UUID suffix would order them randomly.
        let latest = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .compactMap { UInt64($0.prefix(while: \.isNumber)) }.max() ?? 0
        let stamp = max(UInt64(Date().timeIntervalSince1970 * 1000), latest + 1)
        let name = String(format: "%013llu-%@.link", stamp, UUID().uuidString)
        try Data(url.absoluteString.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(Self.didDeposit.rawValue as CFString), nil, nil, true)
    }

    /// Hands each link to `save`, oldest first, removing it once saved.
    /// Stops at the first error, leaving that link and the rest for next time.
    public func drain(_ save: (String) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "link" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            try save(String(decoding: try Data(contentsOf: file), as: UTF8.self))
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
