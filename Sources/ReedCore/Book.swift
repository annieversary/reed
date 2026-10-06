import Foundation
import SwiftData

/// An ebook added from an EPUB file, read a chapter at a time.
@Model
public final class Book {
    @Attribute(.unique) public var id: UUID
    /// SHA-256 of the EPUB, so adding the same file twice finds the copy already kept.
    @Attribute(.unique) public var fileHash: String
    public var title: String
    public var author: String?
    public var addedAt: Date
    public var stateRaw: String
    public var failureMessage: String?
    public var contentVersion: String?
    /// The cover image's file name in the saved version, if the book has one.
    public var coverFile: String?
    /// Pictures the saved version couldn't keep, which make it partly saved.
    public var missingImageCount: Int = 0
    public var isFavorite: Bool
    /// The chapter last opened, to carry on from.
    public var currentChapter: Int?
    /// When a chapter was last opened, so books being read come first.
    public var openedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \BookChapter.book) public var chapters: [BookChapter]

    public init(fileHash: String, title: String, id: UUID = UUID()) {
        self.id = id
        self.fileHash = fileHash
        self.title = title
        addedAt = .now
        stateRaw = DownloadState.queued.rawValue
        isFavorite = false
        chapters = []
    }

    public var state: DownloadState {
        get { DownloadState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    /// The chapters in reading order.
    public var orderedChapters: [BookChapter] { chapters.sorted { $0.index < $1.index } }

    public var wordCount: Int { chapters.reduce(0) { $0 + $1.wordCount } }

    /// How much of the book has been read, by words: the chapters finished, and the way through the rest.
    public var progress: Double {
        let total = wordCount
        guard total > 0 else { return 0 }
        let read = chapters.reduce(0.0) { $0 + Double($1.wordCount) * ($1.isRead ? 1 : $1.progress) }
        return min(read / Double(total), 1)
    }

    public var isRead: Bool { !chapters.isEmpty && chapters.allSatisfy(\.isRead) }

    /// The chapter to carry on with: the one last opened, unless it's finished, then the first not finished after it.
    public var upNext: BookChapter? {
        let ordered = orderedChapters
        let start = ordered.firstIndex { $0.index == currentChapter } ?? 0
        if ordered.indices.contains(start), !ordered[start].isRead { return ordered[start] }
        return ordered[start...].first { !$0.isRead } ?? ordered.first { !$0.isRead } ?? ordered.first
    }
}

@Model
public final class BookChapter {
    @Attribute(.unique) public var id: UUID
    public var book: Book?
    /// Its place in the book, from 0, which also names its files.
    public var index: Int
    public var title: String
    /// Where it starts in the EPUB, as a file's path and an element's ID, which stays the same when the book is converted again.
    public var start: String?
    public var wordCount: Int
    public var progress: Double
    public var isRead: Bool
    public var narrationPassage: Int?
    public var narrationAnchor: String?

    public init(index: Int, title: String, start: String? = nil, wordCount: Int, id: UUID = UUID()) {
        self.id = id
        self.index = index
        self.title = title
        self.start = start
        self.wordCount = wordCount
        progress = 0
        isRead = false
    }
}

extension BookChapter: Readable {
    public var source: String { book?.title ?? "" }
    public var location: ReadableLocation { .chapter(book: book?.id ?? id, index: index) }
    public var contentVersion: String? { book?.contentVersion }
}
