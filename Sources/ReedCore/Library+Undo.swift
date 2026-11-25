import Foundation

/// An article taken out of the library but not yet erased, so taking it out can be undone.
public struct PendingDelete {
    let article: Article
    let membership: Membership
    /// Where it was in `articles`, to put it back in its place.
    let index: Int
}

/// An article taken out of the library but kept cached, to put back where it was.
public struct Removal {
    let article: Article
    let membership: Membership
    let index: Int
    let series: Series?
    let part: Int?
}

/// What marking things finished changed, to put it back.
public struct FinishedMark {
    let readables: [any Readable]
    /// Those that had never been finished before, whose finishing goes from the statistics again.
    let firstFinished: Set<UUID>
    public var isEmpty: Bool { readables.isEmpty }
}

extension Library {
    /// Takes the article out of the library at once, but erases it only once the delete is committed. Reed closing
    /// before then leaves it to be erased on the next launch.
    public func deleteUndoably(_ article: Article) -> PendingDelete? {
        guard article.membership.isSaved, let index = articles.firstIndex(where: { $0.id == article.id }) else { return nil }
        let pending = PendingDelete(article: article, membership: article.membership, index: index)
        pendingDeletes.insert(article.id)
        place(article, as: .discarded)
        save()
        return pending
    }

    public func undo(_ pending: PendingDelete) {
        let article = pending.article
        guard pendingDeletes.remove(article.id) != nil, article.membership == .discarded else { return }
        article.membership = pending.membership
        articles.insert(article, at: min(pending.index, articles.count))
        save()
        resumeDownloads()
    }

    /// Erases the article, or once its download settles if it's downloading.
    public func commit(_ pending: PendingDelete) {
        let article = pending.article
        guard pendingDeletes.remove(article.id) != nil, article.membership == .discarded else { return }
        removeFromSeries(article)
        if article.state != .downloading { erase(article) }
    }

    /// Puts a removed article back in the library, and in its series, where it was.
    public func undo(_ removal: Removal) {
        let article = removal.article
        guard article.membership == .cached else { return }
        place(article, as: removal.membership)
        articles.removeAll { $0.id == article.id }
        articles.insert(article, at: min(removal.index, articles.count))
        save()
        reindex(article)
        if let old = removal.series, let part = removal.part {
            updateSeries { all in
                if let index = all.firstIndex(where: { $0.id == old.id }) {
                    all[index].parts.insert(article.id, at: min(part, all[index].parts.count))
                } else {
                    all.append(Series(id: old.id, name: old.name, parts: [article.id]))
                }
            }
        }
        resumeDownloads()
    }

    /// Marks those not finished yet as finished.
    public func markFinished(_ readables: [any Readable]) -> FinishedMark {
        let unread = readables.filter { !$0.isRead }
        let finishedBefore = Set(readingRecords.filter { $0.finishedAt != nil }.map(\.id))
        for readable in unread {
            readable.isRead = true
            noteFinished(readable)
        }
        save()
        return FinishedMark(readables: unread, firstFinished: Set(unread.map(\.id)).subtracting(finishedBefore))
    }

    public func undo(_ mark: FinishedMark) {
        for readable in mark.readables { readable.isRead = false }
        for record in readingRecords where mark.firstFinished.contains(record.id) { record.finishedAt = nil }
        save()
    }
}
