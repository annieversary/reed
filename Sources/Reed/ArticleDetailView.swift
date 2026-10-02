import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

struct ArticleDetailView: View {
    let library: Library
    let article: Article
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @Environment(\.openURL) private var openURL
    @Environment(Narrator.self) private var narrator
    @State private var passages: [[String]]?
    @State private var reader = ReaderProxy()
    @State private var narrationAway: NarrationDirection?

    private var isNarrating: Bool { narrator.articleID == article.id }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 16) {
                Text(article.domain).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if library.contentURL(for: article) != nil {
                    progressLabel
                    if !isNarrating { listenButton }
                }
                readerMenu
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            Divider()
            #endif
            if let url = library.contentURL(for: article) {
                if article.state == .partial {
                    HStack {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("Text is saved. \(article.missingImageCount) \(article.missingImageCount == 1 ? "image is" : "images are") unavailable.")
                        Spacer()
                        Button("Retry") { library.retry(article) }.buttonStyle(.plain).foregroundStyle(ReedStyle.accent)
                    }
                    .font(.caption).padding(12).background(.yellow.opacity(0.08))
                }
                OfflineWebView(url: url, fontSize: fontSize, progress: article.progress, passages: passages,
                               narrating: isNarrating ? NarrationPosition(passage: narrator.current, sentence: narrator.sentence) : nil,
                               proxy: reader) { value in
                    library.updateProgress(article, value: value)
                } onAddLink: { link in
                    do { try library.add(link.absoluteString) }
                    catch { library.errorMessage = error.localizedDescription }
                } onNarrateFrom: { passage in
                    narrator.play(article, from: passage, in: library)
                } onNarrationAway: { direction in
                    withAnimation(.easeOut(duration: 0.2)) { narrationAway = direction }
                }
                .id(article.id.uuidString + (article.contentVersion ?? ""))
                // Text runs under the home indicator, but not under the narration controls.
                .ignoresSafeArea(edges: narrator.articleID == nil ? .bottom : [])
                .task(id: url) { passages = library.passages(for: article)?.map(ArticleSpeech.sentences(in:)) }
                // Drawn by the app rather than the page, so it sits above the narration controls.
                .overlay(alignment: .bottom) {
                    if isNarrating, let narrationAway { returnToNarrationButton(narrationAway) }
                }
            } else {
                VStack(spacing: 18) {
                    if article.state == .downloading || article.state == .queued {
                        ProgressView().controlSize(.large)
                        Text("Saving").font(.system(size: 25, design: .serif))
                        if article.state == .downloading, let imageActivity = library.imageActivity {
                            Text(imageActivity).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                        Text("Save failed.").font(.system(size: 25, design: .serif))
                        Text(article.failureMessage ?? "The article couldn't be downloaded.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                        HStack {
                            Button("Retry download") { library.retry(article) }.buttonStyle(.borderedProminent)
                            if let url = article.sourceURL { Button("Open original") { openURL(url) }.buttonStyle(.reedSecondary) }
                        }
                    }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReedStyle.paper)
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .toolbar {
            if library.contentURL(for: article) != nil {
                ToolbarItem(placement: .principal) { progressLabel }
                if !isNarrating { ToolbarItem(placement: .primaryAction) { listenButton } }
            }
            ToolbarItem(placement: .primaryAction) { readerMenu }
        }
        #endif
        .onDisappear { library.save() }
    }

    private var progressLabel: some View {
        Text(article.isRead ? "Finished" : "\(Int(article.progress * 100))%")
            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
    }

    private var listenButton: some View {
        Button("Listen", systemImage: "headphones") {
            Task {
                // Pick up where listening stopped; otherwise start from what's on screen.
                let visible = article.narrationPassage == nil ? await reader.visiblePassage() : nil
                narrator.play(article, from: visible, in: library)
            }
        }
            .labelStyle(.iconOnly)
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
            .help("Listen")
    }

    private func returnToNarrationButton(_ direction: NarrationDirection) -> some View {
        Button("Back to the Paragraph Being Read", systemImage: direction == .up ? "arrow.up" : "arrow.down") {
            reader.followNarration()
        }
        .labelStyle(.iconOnly).buttonStyle(.plain)
        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
        .frame(width: 38, height: 38)
        .background(ReedStyle.accent, in: Circle())
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.bottom, 16)
        .transition(.opacity.combined(with: .offset(y: 8)))
        .help("Back to the Paragraph Being Read")
    }

    private var readerMenu: some View {
        Menu {
            if article.isCached {
                Button("Save to Library", systemImage: "tray.and.arrow.down") { library.keep(article) }
            } else {
                Button("Remove from Library", systemImage: "tray.and.arrow.up") { library.removeFromLibrary(article) }
            }
            Divider()
            Button(article.isFavorite ? "Remove Favorite" : "Favorite", systemImage: article.isFavorite ? "star.slash" : "star") {
                library.toggleFavorite(article)
            }
            Button(article.isRead ? "Mark Unread" : "Mark Finished", systemImage: article.isRead ? "circle" : "checkmark.circle") {
                library.toggleRead(article)
            }
            #if os(iOS)
            ControlGroup { textSizeButtons }.menuActionDismissBehavior(.disabled)
            #else
            Menu("Text Size", systemImage: "textformat.size") { textSizeButtons }
            #endif
            if let url = article.sourceURL {
                Divider()
                Button("Open Original", systemImage: "safari") { openURL(url) }
            }
        } label: { Label("More", systemImage: "ellipsis") }
        .labelStyle(.iconOnly)
        #if os(macOS)
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        #endif
        .help("More")
    }

    @ViewBuilder private var textSizeButtons: some View {
        Button("Smaller", systemImage: "textformat.size.smaller") { fontSize = max(14, fontSize - 1) }
        Button("Reset", systemImage: "textformat.size") { fontSize = 19 }
        Button("Larger", systemImage: "textformat.size.larger") { fontSize = min(28, fontSize + 1) }
    }
}
