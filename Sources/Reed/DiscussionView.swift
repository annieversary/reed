import SwiftUI
import WebKit
#if SWIFT_PACKAGE
import ReedCore
#endif

/// The comments on an article from the places it is discussed, kept to read offline.
struct DiscussionView: View {
    let library: Library
    let article: Article
    @Binding var isPresented: Bool
    /// Whether to offer Done, as a sheet needs; the Mac's inspector closes from the toolbar instead.
    var showsDone = Self.isPhoneLike
    /// Told of comments as they arrive, so others showing counts can keep up.
    var onFetch: (DiscussionSite, Discussion) -> Void = { _, _ in }
    @Environment(\.openURL) private var openURL
    /// The place whose comments show, else the first found.
    @State var selected: DiscussionSite?
    @State private var pages: [DiscussionSite: String] = [:]
    @State private var refreshing: Set<DiscussionSite> = []
    @State private var failed: Set<DiscussionSite> = []
    @State private var searching = false

    #if os(iOS)
    private static let isPhoneLike = true
    #else
    private static let isPhoneLike = false
    #endif

    private var site: DiscussionSite? { selected ?? article.discussionSites.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                let sites = article.discussionSites
                if sites.count > 1 {
                    Picker("Site", selection: Binding(get: { site }, set: { selected = $0 })) {
                        ForEach(sites, id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                } else {
                    Text("Comments").font(.headline)
                }
                if let site, refreshing.contains(site) { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if let site {
                    Button("Open on \(site.name)", systemImage: "safari") { openURL(site.url) }
                        .labelStyle(.iconOnly).help("Open on \(site.name)")
                }
                if showsDone { Button("Done") { isPresented = false }.fontWeight(.semibold) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if let site, let page = pages[site] {
                if failed.contains(site) {
                    Text("Couldn't refresh; these are the comments last saved.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(6)
                }
                DiscussionWebView(html: page, baseURL: site.url)
            } else if let site, failed.contains(site) {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("The comments couldn't be loaded.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await refresh(site) } }.buttonStyle(.reedSecondary)
                }
                .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if site == nil && !searching {
                Text("No one is discussing this on Hacker News, Lobste.rs or Substack.").font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ReedStyle.paper)
        .task(id: article.id) {
            searching = true
            await library.findDiscussions(of: article)
            searching = false
        }
        .task(id: site) {
            guard let site else { return }
            if pages[site] == nil, let kept = library.discussion(site, of: article) { pages[site] = render(kept, from: site) }
            await refresh(site)
        }
    }

    private func render(_ discussion: Discussion, from site: DiscussionSite) -> String {
        discussion.html(site: site, title: article.title)
    }

    private func refresh(_ site: DiscussionSite) async {
        refreshing.insert(site)
        defer { refreshing.remove(site) }
        do {
            let discussion = try await library.refreshDiscussion(site, of: article)
            pages[site] = render(discussion, from: site)
            failed.remove(site)
            onFetch(site, discussion)
        } catch is CancellationError {
        } catch {
            failed.insert(site)
        }
    }
}

/// Shows a page of comments, opening its links in the browser.
@MainActor private struct DiscussionWebView {
    let html: String
    let baseURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
        return webView
    }

    func update(_ webView: WKWebView, coordinator: Coordinator) {
        // Reloading would reopen collapsed threads and lose the place, so only new comments reload.
        guard coordinator.html != html else { return }
        coordinator.html = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated else { return .allow }
            if let url = navigationAction.request.url { await openInBrowser(url) }
            return .cancel
        }
    }
}

#if os(macOS)
extension DiscussionWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) { update(nsView, coordinator: context.coordinator) }
}
#else
extension DiscussionWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) { update(uiView, coordinator: context.coordinator) }
}
#endif
