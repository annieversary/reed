import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

struct ArticleDetailView: View {
    let library: Library
    let article: Article
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 16) {
                Text(article.domain).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                readerControls
            }
            .buttonStyle(.plain).padding(.horizontal, 22).padding(.vertical, 15)
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
                OfflineWebView(url: url, fontSize: fontSize, progress: article.progress) { value in
                    library.updateProgress(article, value: value)
                }
                .id(article.id.uuidString + (article.contentVersion ?? ""))
                HStack(spacing: 12) {
                    Label("Saved on this device", systemImage: "checkmark.shield")
                    Spacer()
                    Text(article.isRead ? "Finished" : "\(Int(article.progress * 100))% read").monospacedDigit()
                }
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 11)
                .background(ReedStyle.warm)
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
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { readerControls } }
        #endif
        .onDisappear { library.save() }
    }

    @ViewBuilder private var readerControls: some View {
        Menu {
            Button("Larger text", systemImage: "textformat.size.larger") { fontSize = min(28, fontSize + 1) }
            Button("Smaller text", systemImage: "textformat.size.smaller") { fontSize = max(14, fontSize - 1) }
            Button("Reset text size") { fontSize = 19 }
        } label: { Image(systemName: "textformat.size") }
        .help("Reader text size").accessibilityLabel("Reader text size")
        Button { library.toggleFavorite(article) } label: { Image(systemName: article.isFavorite ? "star.fill" : "star") }
            .help(article.isFavorite ? "Remove favorite" : "Favorite").accessibilityLabel("Toggle favorite")
        Button { library.toggleRead(article) } label: { Image(systemName: article.isRead ? "checkmark.circle.fill" : "checkmark.circle") }
            .help(article.isRead ? "Mark unread" : "Mark finished").accessibilityLabel("Toggle finished")
        if let url = article.sourceURL {
            Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }
                .help("Open original in your browser").accessibilityLabel("Open original")
        }
    }
}
