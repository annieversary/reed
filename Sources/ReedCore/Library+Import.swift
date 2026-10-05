import CryptoKit
import Foundation
import SwiftData

/// A file being added, copied into staging and hashed away from the main actor.
struct ImportedFile: Sendable {
    let copy: URL
    let digest: String
    /// Its first bytes, to tell what it is.
    let head: Data
}

/// PDFs and EPUBs added as files, and what the share extension hands over.
extension Library {
    /// Saves the PDF at `file`, shared as a file rather than a link. Reed keeps a copy to read it from.
    @discardableResult public func add(pdfAt file: URL, name: String) async throws -> Article {
        let staging = try storage.createStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let imported = try await Self.importFile(file, into: staging)
        guard imported.head.starts(with: Data("%PDF".utf8)) else { throw ReedError.unsupportedContent }
        let digest = imported.digest
        if let existing = articles.first(where: { $0.isFile && URL(string: $0.originalURL)?.pathComponents.dropFirst().first == digest }) {
            return existing
        }
        let article = Article(url: Article.fileURL(digest: digest, name: name))
        article.title = (name as NSString).deletingPathExtension
        let copy = storage.sharedFileURL(article.id)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: imported.copy, to: copy)
        container.mainContext.insert(article)
        do { try container.mainContext.save() }
        catch { container.mainContext.delete(article); try? storage.removeArticle(article.id); throw error }
        articles.insert(article, at: 0)
        reindex(article)
        resumeDownloads()
        return article
    }

    /// Adds what's waiting in the inbox. Called again while it's at work, it goes round once more when done.
    public func addShared(from inbox: ShareInbox) async {
        guard !addingShared else { inboxChanged = true; return }
        addingShared = true
        defer { addingShared = false }
        repeat {
            inboxChanged = false
            await drain(inbox)
        } while inboxChanged
    }

    func drain(_ inbox: ShareInbox) async {
        do {
            // An item that keeps failing is set aside, so it doesn't report the same error every time Reed is opened.
            try await inbox.drain(giveUp: { file in
                inboxFailures[file.lastPathComponent, default: 0] += 1
                return inboxFailures[file.lastPathComponent]! >= Self.inboxAttempts
            }) { item in
                // What can never be saved is dropped rather than retried forever.
                switch item {
                case .link(let input): do { try add(input) } catch ReedError.invalidURL {}
                case .pdf(let file, let name): do { try await add(pdfAt: file, name: name) } catch ReedError.unsupportedContent {}
                case .book(let file, let name):
                    // Said why, since it was chosen to read, then dropped like the rest.
                    do { try await add(bookAt: file, name: name) }
                    catch ReedError.unreadableBook { errorMessage = ReedError.unreadableBook.localizedDescription }
                    catch ReedError.protectedBook { errorMessage = ReedError.protectedBook.localizedDescription }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Copies `file` into `staging` and hashes the copy, a chunk at a time, so a large file needn't be read whole.
    nonisolated static func importFile(_ file: URL, into staging: URL) async throws -> ImportedFile {
        let copy = staging.appendingPathComponent("Import", isDirectory: false)
        try FileManager.default.copyItem(at: file, to: copy)
        let handle = try FileHandle(forReadingFrom: copy)
        defer { try? handle.close() }
        var hash = SHA256()
        var head = Data()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            if head.isEmpty { head = chunk.prefix(16) }
            hash.update(data: chunk)
        }
        return ImportedFile(copy: copy, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), head: head)
    }
}
