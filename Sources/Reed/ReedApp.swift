import SwiftUI
import SwiftData
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
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        do {
            let library = try openLibrary()
            self.library = library
            present(LibraryView(library: library).tint(ReedStyle.accent))
            Task { @MainActor in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                    await SmokeTest.run(library: library)
                    return
                }
                #endif
                library.resumeDownloads()
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { library?.resumeDownloads() }
    func applicationDidResignActive(_ notification: Notification) { library?.save() }
    func applicationWillTerminate(_ notification: Notification) { library?.save() }

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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do { _library = State(initialValue: try openLibrary()) }
        catch { _startupError = State(initialValue: error.localizedDescription) }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let library {
                    LibraryView(library: library).task { library.resumeDownloads() }
                } else {
                    ContentUnavailableView("Couldn't open your library", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text(startupError ?? "An unknown storage error occurred."))
                }
            }
            .tint(ReedStyle.accent)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { library?.resumeDownloads() }
                else { library?.save() }
            }
        }
    }
}
#endif

extension Notification.Name {
    static let reedAddArticle = Notification.Name("reed.addArticle")
}

enum ReedStyle {
    static let accent = Color(red: 0.32, green: 0.42, blue: 0.32)
    static let warm = Color.primary.opacity(0.035)
}
