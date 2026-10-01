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

    private var isNarrating: Bool { narrator.articleID == article.id }
    private var narrated: NarratedPassage? {
        guard isNarrating, let text = narrator.currentPassage else { return nil }
        return NarratedPassage(index: narrator.current, text: text)
    }

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
                OfflineWebView(url: url, fontSize: fontSize, progress: article.progress, narrated: narrated) { value in
                    library.updateProgress(article, value: value)
                } onAddLink: { link in
                    do { try library.add(link.absoluteString) }
                    catch { library.errorMessage = error.localizedDescription }
                }
                .id(article.id.uuidString + (article.contentVersion ?? ""))
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isNarrating { NarrationBar(narrator: narrator) }
                }
            } else {
                VStack(spacing: 18) {
                    if article.state == .downloading || article.state == .queued {
                        ProgressView().controlSize(.large)
                        Text("Making room for a good read.").font(.system(size: 25, design: .serif))
                        Text(library.activity ?? "Waiting to download…").font(.subheadline).foregroundStyle(.secondary)
                        Text("You can keep browsing your library.").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                        Text("This one needs another try.").font(.system(size: 25, design: .serif))
                        Text(article.failureMessage ?? "The article couldn't be downloaded.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                        HStack {
                            Button("Retry download") { library.retry(article) }.buttonStyle(.borderedProminent)
                            if let url = article.sourceURL { Button("Open original") { openURL(url) }.buttonStyle(.bordered) }
                        }
                    }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReedStyle.warm)
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
        Button("Listen", systemImage: "headphones") { narrator.play(article, in: library) }
            .labelStyle(.iconOnly)
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
            .help("Listen")
    }

    private var readerMenu: some View {
        Menu {
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

private struct NarrationBar: View {
    let narrator: Narrator

    var body: some View {
        HStack(spacing: 18) {
            Button("Previous Paragraph", systemImage: "backward.fill") { narrator.skip(by: -1) }
                .disabled(narrator.current == 0)
            Button(narrator.isPlaying ? "Pause" : "Play", systemImage: narrator.isPlaying ? "pause.fill" : "play.fill") {
                narrator.togglePlayback()
            }
            .font(.title2).frame(width: 28)
            Button("Next Paragraph", systemImage: "forward.fill") { narrator.skip(by: 1) }
                .disabled(narrator.current + 1 >= narrator.passageCount)
            status.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop Listening", systemImage: "xmark") { narrator.stop() }.foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var status: some View {
        if let error = narrator.errorMessage {
            HStack {
                Text(error).lineLimit(2)
                Button("Retry") { narrator.retry() }.foregroundStyle(ReedStyle.accent)
            }
        } else if narrator.isWaiting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(narrator.isLoadingVoice ? "Getting the voice ready. The first time, this downloads about 120 MB." : "Preparing audio…")
                    .lineLimit(2)
            }
        } else {
            Text("Paragraph \(narrator.current + 1) of \(narrator.passageCount)").monospacedDigit()
        }
    }
}
