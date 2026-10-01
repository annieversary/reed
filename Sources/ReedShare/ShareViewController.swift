import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
typealias PlatformViewController = NSViewController
typealias PlatformHostingController = NSHostingController
#else
typealias PlatformViewController = UIViewController
typealias PlatformHostingController = UIHostingController
#endif

/// Queues the shared link in the inbox and gets out of the way; the app downloads it next time it runs.
/// Extensions are short-lived and memory-capped, so no fetching or extraction happens here.
final class ShareViewController: PlatformViewController {
    private let status = ShareStatus()

    #if os(macOS)
    override func loadView() {
        view = NSView()
        preferredContentSize = NSSize(width: 320, height: 150)
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = PlatformHostingController(rootView: ShareView(status: status) { [weak self] in self?.finish() })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #if os(iOS)
        view.backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.didMove(toParent: self)
        #endif
        Task { await save() }
    }

    private func save() async {
        guard let url = await sharedURL() else {
            status.phase = .failed("Reed can only save web links.")
            return
        }
        do {
            guard let inbox = ShareInbox.shared else { throw CocoaError(.fileNoSuchFile) }
            try inbox.deposit(url)
        } catch {
            status.phase = .failed("Couldn't hand the link to Reed. \(error.localizedDescription)")
            return
        }
        status.phase = .saved
        try? await Task.sleep(for: .milliseconds(900))
        finish()
    }

    private func sharedURL() async -> URL? {
        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { ($0 as? NSExtensionItem)?.attachments }.joined()
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        for provider in providers {
            let url = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url, ["http", "https"].contains(url.scheme?.lowercased()) { return url }
        }
        return nil
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor @Observable final class ShareStatus {
    enum Phase { case saving, saved, failed(String) }
    var phase = Phase.saving
}

struct ShareView: View {
    let status: ShareStatus
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch status.phase {
            case .saving:
                ProgressView()
                Text("Saving to Reed…")
            case .saved:
                Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(accent)
                Text("Saved to Reed").font(.system(size: 20, design: .serif))
                Text("It'll download next time Reed is open.").font(.footnote).foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text(message).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(maxWidth: 320)
        #if os(iOS)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    // Matches ReedStyle.accent in the app.
    private var accent: Color { Color(red: 0.32, green: 0.42, blue: 0.32) }
}
