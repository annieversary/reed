import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// The swipe actions every list of articles shares: swiping right keeps or acts on the article, swiping left
/// gets rid of it.
@MainActor enum ArticleSwipes {
    /// Retry while there's nothing saved to read, otherwise Finished or Unread, then Favorite.
    @ViewBuilder static func keep(_ article: Article, library: Library, undo: UndoToast) -> some View {
        if article.state == .failed || article.isWaitingToRetry {
            Button { library.retry(article) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .tint(ReedStyle.accent)
        } else {
            Button { undo.toggleRead(article, in: library) } label: {
                Label(article.isRead ? "Unread" : "Finished", systemImage: article.isRead ? "book.closed" : "checkmark.circle")
            }
            .tint(ReedStyle.accent)
        }
        favorite(article.isFavorite) { library.toggleFavorite(article) }
    }

    static func favorite(_ isFavorite: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "star.slash" : "star")
        }
        .tint(.orange)
    }

    static func delete(action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Label("Delete", systemImage: "trash") }
    }
}

extension View {
    /// Swipe right to finish, retry or favorite the article, left to delete it.
    func articleSwipes(_ article: Article, library: Library, onDelete: @escaping (Article) -> Void) -> some View {
        modifier(ArticleSwipesModifier(article: article, library: library, onDelete: onDelete))
    }
}

private struct ArticleSwipesModifier: ViewModifier {
    let article: Article
    let library: Library
    let onDelete: (Article) -> Void
    @Environment(UndoToast.self) private var undo

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) { ArticleSwipes.keep(article, library: library, undo: undo) }
            .swipeActions(edge: .trailing) { ArticleSwipes.delete { onDelete(article) } }
    }
}
