import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

@MainActor private func openLibrary() throws -> Library {
    let arguments = ProcessInfo.processInfo.arguments
    let root: URL?
    if let index = arguments.firstIndex(of: "--library-root"), arguments.indices.contains(index + 1) {
        root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    } else { root = nil }
    return try Library(root: root)
}

/// An isolated library (smoke tests) never takes links shared to the real one.
@MainActor private let shareInbox = ProcessInfo.processInfo.arguments.contains("--library-root") ? nil : ShareInbox.shared

@MainActor private func addShared(to library: Library) {
    if let shareInbox { Task { await library.addShared(from: shareInbox) } }
}

/// Adds an EPUB opened with Reed from elsewhere, such as Finder or Files, and shows it.
/// A copy handed over in the app's Inbox is removed once Reed has copied it in turn.
@MainActor private func openBook(at url: URL, in library: Library) {
    Task {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            #if os(iOS)
            let inbox = URL.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true).resolvingSymlinksInPath().path + "/"
            if url.resolvingSymlinksInPath().path.hasPrefix(inbox) { try? FileManager.default.removeItem(at: url) }
            #endif
        }
        do {
            let book = try await library.add(bookAt: url, name: url.lastPathComponent)
            NotificationCenter.default.post(name: .reedShowBook, object: [book.id])
        } catch { library.errorMessage = error.localizedDescription }
    }
}

#if os(macOS)
// An explicit AppKit window gives the desktop prototype deterministic launch/reopen behavior.
// Its entire content is the same SwiftUI LibraryView used on iOS.
@main @MainActor enum ReedDesktop {
    static func main() {
        let application = NSApplication.shared
        let delegate = ReedDesktopDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class ReedDesktopDelegate: NSObject, NSApplicationDelegate {
    private var library: Library?
    /// Files opened before the library was, as when Reed is launched to open one.
    private var pendingFiles: [URL] = []
    private let narrator = Narrator()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        do {
            let library = try openLibrary()
            self.library = library
            present(LibraryView(library: library).environment(narrator).tint(ReedStyle.accent))
            Task { @MainActor in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                    await SmokeTest.run(library: library)
                    return
                }
                #endif
                addShared(to: library)
                library.resumeDownloads()
                for url in pendingFiles { openBook(at: url, in: library) }
                pendingFiles = []
            }
            ShareInbox.forwardDeposits()
            NotificationCenter.default.addObserver(forName: ShareInbox.didDeposit, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { addShared(to: library) }
            }
        } catch {
            present(ContentUnavailableView("Couldn't open your library", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text(error.localizedDescription)))
        }
    }

    private func present(_ root: some View) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Reed"
        window.minSize = NSSize(width: 940, height: 600)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.center()
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") { window.setFrameAutosaveName("ReedLibrary") }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let books = urls.filter { $0.pathExtension.lowercased() == "epub" }
        guard let library else { pendingFiles += books; return }
        window?.makeKeyAndOrderFront(nil)
        for url in books { openBook(at: url, in: library) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let library else { return }
        addShared(to: library)
        library.resumeDownloads()
    }
    func applicationDidResignActive(_ notification: Notification) { library?.save() }
    func applicationWillTerminate(_ notification: Notification) { library?.save() }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView().environment(narrator).tint(ReedStyle.accent)))
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func saveArticle() {
        window?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .reedAddArticle, object: nil)
    }

    private func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Reed")
        appMenu.addItem(withTitle: "About Reed", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Reed", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        let save = file.addItem(withTitle: "Save Article…", action: #selector(saveArticle), keyEquivalent: "n")
        save.target = self
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
    }
}
#else
@main struct ReedApp: App {
    @State private var library: Library?
    @State private var startupError: String?
    @State private var narrator = Narrator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do { _library = State(initialValue: try openLibrary()) }
        catch { _startupError = State(initialValue: error.localizedDescription) }
        ShareInbox.forwardDeposits()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let library {
                    LibraryView(library: library)
                        .task { addShared(to: library); library.resumeDownloads() }
                        .onReceive(NotificationCenter.default.publisher(for: ShareInbox.didDeposit)) { _ in addShared(to: library) }
                        .onOpenURL { url in
                            guard url.isFileURL, url.pathExtension.lowercased() == "epub" else { return }
                            openBook(at: url, in: library)
                        }
                } else {
                    ContentUnavailableView("Couldn't open your library", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text(startupError ?? "An unknown storage error occurred."))
                }
            }
            .environment(narrator)
            .tint(ReedStyle.accent)
            .onChange(of: scenePhase) { _, phase in
                guard let library else { return }
                // Synthesis can fail in the background, so it's picked up again on return.
                if phase == .active { addShared(to: library); library.resumeDownloads(); narrator.retry() }
                else { library.save() }
            }
        }
    }
}
#endif

extension Notification.Name {
    static let reedAddArticle = Notification.Name("reed.addArticle")
    /// Shows a book, and a chapter of it if given, as an array of their IDs.
    static let reedShowBook = Notification.Name("reed.showBook")
}

enum ReedStyle {
    static let accent = Color(red: 0.32, green: 0.42, blue: 0.32)
    static let warm = Color.primary.opacity(0.035)
    /// The reader's background, matching saved pages: white, or black in dark mode.
    #if os(iOS)
    static let paper = Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    #else
    static let paper = Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white })
    #endif
}

struct ReedSecondaryButtonStyle: ButtonStyle {
    var padded = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, padded ? 10 : 0).padding(.vertical, padded ? 5 : 0)
            .foregroundStyle(ReedStyle.accent)
            .background(ReedStyle.accent.opacity(configuration.isPressed ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

extension ButtonStyle where Self == ReedSecondaryButtonStyle {
    static var reedSecondary: ReedSecondaryButtonStyle { ReedSecondaryButtonStyle() }
    /// For icon buttons that size themselves.
    static var reedSecondaryIcon: ReedSecondaryButtonStyle { ReedSecondaryButtonStyle(padded: false) }
}
