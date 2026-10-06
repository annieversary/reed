import Foundation

/// Something read top to bottom in the reader, listened to and written beside: a saved article, or a chapter of a book.
public protocol Readable: AnyObject {
    var id: UUID { get }
    var title: String { get }
    /// What it's from, shown above the title: the website, or the book.
    var source: String { get }
    var location: ReadableLocation { get }
    var contentVersion: String? { get }
    var progress: Double { get set }
    var isRead: Bool { get set }
    /// The passage narration last reached, to resume from.
    var narrationPassage: Int? { get set }
    /// The start of that passage, as `ArticleNotes.anchor(for:)` gives it.
    var narrationAnchor: String? { get set }
}

/// Where a readable's files are kept in the library.
public enum ReadableLocation: Hashable, Sendable {
    case article(UUID)
    case chapter(book: UUID, index: Int)
}

extension Article: Readable {
    public var source: String { domain }
    public var location: ReadableLocation { .article(id) }
}
