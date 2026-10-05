import SwiftUI
import WebKit
#if SWIFT_PACKAGE
import ReedCore
#endif

/// Substack's own sign-in page, which closes once it has signed the reader in and keeps only the session.
struct SubstackSignInView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SubstackSignInPage { session in
                SubstackAccount.shared.signIn(session: session)
                dismiss()
            }
            .navigationTitle("Sign In to Substack")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 640)
        #endif
    }
}

@MainActor private struct SubstackSignInPage {
    let signedIn: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(signedIn: signedIn) }

    func makeView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Kept apart from everything else, and gone once the sheet closes.
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: URL(string: "https://substack.com/sign-in")!))
        coordinator.watch(configuration.websiteDataStore.httpCookieStore)
        return view
    }

    /// Checks the session cookie with Substack while the page is open. Visitors get one before signing in,
    /// and signing in keeps it, so it is checked again until it is signed in.
    @MainActor final class Coordinator {
        let signedIn: (String) -> Void
        private var watcher: Task<Void, Never>?

        init(signedIn: @escaping (String) -> Void) { self.signedIn = signedIn }

        func watch(_ store: WKHTTPCookieStore) {
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    let cookies = await store.allCookies()
                    if let session = cookies.first(where: { $0.name == "substack.sid" && $0.domain.hasSuffix("substack.com") })?.value,
                       (try? await SubstackAccount.isSignedIn(session: session)) == true {
                        self?.signedIn(session)
                        return
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }

        func stop() { watcher?.cancel() }
    }
}

#if os(macOS)
extension SubstackSignInPage: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeView(coordinator: context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
}
#else
extension SubstackSignInPage: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeView(coordinator: context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
}
#endif
