import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// An article in the library list: where it's from, its title and byline, an excerpt or what matched a search, and how it stands.
struct ArticleRow: View {
    let article: Article
    /// The passage that matched a search, shown in place of the excerpt.
    let snippet: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(article.domain).font(.system(size: 9, weight: .semibold)).tracking(1.1)
                Spacer()
                if article.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)) }
            }.foregroundStyle(ReedStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(3).lineSpacing(2)
                if let byline {
                    Text(byline).font(.system(size: 12, design: .serif).italic()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let snippet {
                Text(Self.highlighted(snippet)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).lineSpacing(3)
            } else if !article.excerpt.isEmpty {
                Text(article.excerpt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
            }
            HStack(spacing: 5) {
                if article.state == .downloading || article.state == .queued { ProgressView().controlSize(.mini) }
                else if !article.state.isReadable { Image(systemName: "exclamationmark.circle").font(.system(size: 10)) }
                Text(article.state.isReadable ? "\(article.readingMinutes) min read" : article.state.label)
                if article.state == .partial { Image(systemName: "photo.badge.exclamationmark") }
                if article.isRead {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                        .accessibilityLabel("Finished")
                } else if article.progress > 0 {
                    Text("· \(Int(article.progress * 100))%")
                }
                Spacer()
                Text("Saved \(article.savedAt.formatted(.dateTime.month(.abbreviated).day()))")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(.vertical, 15).padding(.horizontal, 7)
        .readFading(article)
        .accessibilityElement(children: .combine)
    }

    private var byline: String? {
        let parts = [article.author, article.publishedAt.map(Self.formatPublished)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in snippet.components(separatedBy: SearchIndex.highlightStart).enumerated() {
            let pieces = part.components(separatedBy: SearchIndex.highlightEnd)
            guard index > 0, pieces.count > 1 else { result += AttributedString(part); continue }
            var term = AttributedString(pieces[0])
            term.foregroundColor = .primary
            term.inlinePresentationIntent = .stronglyEmphasized
            result += term + AttributedString(pieces.dropFirst().joined())
        }
        return result
    }

    private static func formatPublished(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}
