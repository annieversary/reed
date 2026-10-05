import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
typealias PlatformViewController = NSViewController
typealias PlatformHostingController = NSHostingController
#else
typealias PlatformViewController = UIViewController
typealias PlatformHostingController = UIHostingController
#endif

/// Queues the shared link, PDF or EPUB in the inbox and gets out of the way; the app saves it next time it runs.
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
        do {
            guard let inbox = ShareInbox.shared else { throw CocoaError(.fileNoSuchFile) }
            // A PDF open in Safari comes with its link too, which saves it and keeps where it came from.
            if let url = await sharedURL() {
                try inbox.deposit(url)
            } else if try await depositSharedFile(in: inbox) == false {
                status.phase = .failed("Reed can only save web links, PDFs and EPUBs.")
                return
            }
        } catch {
            status.phase = .failed("Couldn't hand this to Reed. \(error.localizedDescription)")
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

    /// Copies the first shared PDF or EPUB into the inbox, while the file handed over still exists.
    private func depositSharedFile(in inbox: ShareInbox) async throws -> Bool {
        let providers = (extensionContext?.inputItems ?? []).compactMap { ($0 as? NSExtensionItem)?.attachments }.joined()
        guard let (provider, type) = [UTType.pdf, .epub].lazy.compactMap({ type in
            providers.first { $0.hasItemConformingToTypeIdentifier(type.identifier) }.map { ($0, type) }
        }).first else { return false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { file, error in
                guard let file else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                do {
                    // Files and Mail suggest the document's own name; the copy handed over may be named otherwise.
                    if type == .epub { try inbox.deposit(bookAt: file, name: provider.suggestedName) }
                    else { try inbox.deposit(pdfAt: file, name: provider.suggestedName) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        return true
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
                Text("It'll be ready next time Reed is open.").font(.footnote).foregroundStyle(.secondary)
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
