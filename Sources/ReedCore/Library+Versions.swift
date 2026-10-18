import Foundation

/// Saved versions replaced by newer ones. One still open, in the reader or being narrated, is kept until it's closed,
/// so its pictures and narration don't vanish from under it.
extension Library {
    struct RetiredVersion: Hashable {
        enum Owner: Hashable { case article(UUID), book(UUID) }
        let owner: Owner
        let version: String
        /// What has it open: the article, or the book and its chapters.
        let holders: Set<UUID>
    }

    /// Removes `version` once nothing in `holders` is open, now if nothing is.
    func retire(_ version: String, of owner: RetiredVersion.Owner, heldBy holders: Set<UUID>) {
        let retired = RetiredVersion(owner: owner, version: version, holders: holders)
        if holders.isDisjoint(with: retained) { remove(retired) } else { retiredVersions.insert(retired) }
    }

    /// Removes the replaced versions nothing has open any more.
    func removeClosedVersions() {
        for retired in retiredVersions where retired.holders.isDisjoint(with: retained) {
            retiredVersions.remove(retired)
            remove(retired)
        }
    }

    private func remove(_ retired: RetiredVersion) {
        switch retired.owner {
        case .article(let id): try? storage.removeArticleVersion(id, version: retired.version)
        case .book(let id): try? storage.removeBookVersion(id, version: retired.version)
        }
    }

    /// Removes versions left behind by an earlier run, such as one still open when Reed quit. Only folders made before
    /// now are looked at, so a version being saved meanwhile is left alone.
    func removeLeftoverVersions() {
        let kept = articles.map { (storage.articleDirectory($0.id), $0.contentVersion) } + cached.map { (storage.articleDirectory($0.id), $0.contentVersion) }
            + books.map { (storage.bookDirectory($0.id), $0.contentVersion) }
        let before = Date.now
        Task.detached(priority: .background) {
            for (directory, version) in kept {
                for folder in [directory, directory.appendingPathComponent("Audio", isDirectory: true)] {
                    ArticleStorage.removeVersions(in: folder, except: version, madeBefore: before)
                }
            }
        }
    }
}

extension ArticleStorage {
    /// Removes the version folders in `directory`, named by their UUIDs, other than `version` and those made since `date`.
    static func removeVersions(in directory: URL, except version: String?, madeBefore date: Date) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]) else { return }
        for folder in folders where folder.lastPathComponent != version && UUID(uuidString: folder.lastPathComponent) != nil {
            guard let values = try? folder.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey]),
                  values.isDirectory == true, let created = values.creationDate, created < date else { continue }
            try? manager.removeItem(at: folder)
        }
    }
}
