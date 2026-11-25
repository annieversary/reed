import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// Subscribes to the feed at an address, or to one of the feeds a site's page links to.
struct AddFeedView: View {
    let library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    /// Why the address in the field couldn't be subscribed to, until it's changed.
    @State private var failure: (text: String, reason: String)?
    @State private var working = false
    @State private var task: Task<Void, Never>?
    /// Offered when a site has several feeds.
    @State private var candidates: [FeedCandidate] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add feed.").font(.system(size: 26, design: .serif))
            LinkField(prompt: "Site or feed address", text: $address, failure: failure, detail: site, focused: $focused, onSubmit: find)
                .onChange(of: address) { candidates = [] }
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This site has more than one feed.").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(candidates) { candidate in
                        Button { subscribe(to: candidate.url) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(candidate.url.absoluteString).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(ReedStyle.accent)
                            }
                            .padding(11).contentShape(Rectangle())
                            .background(ReedStyle.warm, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain).disabled(working)
                    }
                }
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Looking for the feed…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if address.isEmpty {
                    SheetPasteButton { address = $0; find($0) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Subscribe") { find(address) }
                    .buttonStyle(.borderedProminent).tint(ReedStyle.accent).keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
            .controlSize(.large)
        }
        .sheetLayout()
        .fittedSheet()
        #if os(macOS)
        .onAppear { focused = true }
        #endif
        // Closing the sheet abandons the search, rather than subscribing later.
        .onDisappear { task?.cancel() }
    }

    /// The site the address is on, so a mistyped one shows before it's looked up.
    private var site: String? {
        working ? nil : (try? ArticleURL.parse(address).host())
    }

    private func find(_ input: String) {
        guard !working, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        work {
            let found = try await library.findFeeds(at: input)
            if found.count == 1 {
                try await library.subscribe(to: found[0].url)
                dismiss()
            } else {
                candidates = found
            }
        }
    }

    private func subscribe(to url: URL) {
        work {
            try await library.subscribe(to: url)
            dismiss()
        }
    }

    private func work(_ body: @escaping () async throws -> Void) {
        failure = nil
        working = true
        task = Task {
            defer { working = false }
            do { try await body() } catch is CancellationError {} catch { failure = (address, error.localizedDescription) }
        }
    }
}

struct ManageFeedsView: View {
    let library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.feeds) { feed in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feed.title).font(.system(size: 16, design: .serif)).lineLimit(1)
                            HStack(spacing: 4) {
                                if feed.failure != nil { Image(systemName: "exclamationmark.circle") }
                                Text(status(of: feed)).lineLimit(2)
                            }
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { library.unsubscribe(feed) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Unsubscribe").accessibilityLabel("Unsubscribe from \(feed.title)")
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Unsubscribe", systemImage: "minus.circle", role: .destructive) { library.unsubscribe(feed) }
                    }
                }
                .onDelete { offsets in
                    for feed in offsets.map({ library.feeds[$0] }) { library.unsubscribe(feed) }
                }
            }
            .overlay {
                if library.feeds.isEmpty {
                    Text("No feeds yet.").font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Feeds")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .principal) { Text("Feeds").font(.system(size: 19, design: .serif)) }
                #endif
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add a feed", systemImage: "plus") { showingAdd = true }
                }
            }
            .sheet(isPresented: $showingAdd) { AddFeedView(library: library) }
        }
        #if os(macOS)
        .frame(width: 460, height: 420)
        #endif
    }

    private func status(of feed: Feed) -> String {
        let host = feed.url.host() ?? feed.url.absoluteString
        if let failure = feed.failure { return "\(host) · \(failure)" }
        guard let fetchedAt = feed.fetchedAt else { return host }
        return "\(host) · Updated \(fetchedAt.formatted(.relative(presentation: .named)))"
    }
}
