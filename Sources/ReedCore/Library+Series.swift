import Foundation
import SwiftData

/// Articles gathered into series, read in order.
extension Library {
    public func series(of article: Article) -> Series? {
        series.first { $0.parts.contains(article.id) }
    }

    /// The series' articles, in reading order.
    public func parts(of series: Series) -> [Article] {
        let byID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })
        let current = self.series.first { $0.id == series.id } ?? series
        return current.parts.compactMap { byID[$0] }
    }

    /// Gathers articles into a new series, taking them out of any other, ordered by the part numbers in
    /// their titles if every one has one, and otherwise by when they were published, then saved.
    @discardableResult public func makeSeries(named name: String, of parts: [Article]) -> Series? {
        guard !parts.isEmpty else { return nil }
        let numbers = parts.map { SeriesTitle.partNumber(in: $0.title) }
        let ordered = if numbers.allSatisfy({ $0 != nil }) {
            zip(parts, numbers).sorted { $0.1! < $1.1! }.map(\.0)
        } else {
            parts.sorted { ($0.publishedAt ?? $0.savedAt, $0.savedAt) < ($1.publishedAt ?? $1.savedAt, $1.savedAt) }
        }
        let new = Series(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parts: ordered.map(\.id))
        updateSeries { all in
            for index in all.indices { all[index].parts.removeAll(where: new.parts.contains) }
            all.removeAll { $0.parts.isEmpty }
            all.append(new)
        }
        return new
    }

    /// Adds an article to a series, after the parts numbered before it, or at the end.
    public func add(_ article: Article, to series: Series) {
        let id = article.id
        updateSeries { all in
            for index in all.indices { all[index].parts.removeAll { $0 == id } }
            guard let target = all.firstIndex(where: { $0.id == series.id }) else { return }
            var position = all[target].parts.endIndex
            let byID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })
            let numbers = all[target].parts.map { byID[$0].flatMap { SeriesTitle.partNumber(in: $0.title) } }
            if let number = SeriesTitle.partNumber(in: article.title), numbers.allSatisfy({ $0 != nil }) {
                position = numbers.firstIndex { $0! > number } ?? position
            }
            all[target].parts.insert(id, at: position)
            all.removeAll { $0.parts.isEmpty }
        }
    }

    /// Puts articles into one series in the order given: the series one of them is in already, or else a new
    /// one. Parts already in that series but not given stay, after them.
    @discardableResult public func gather(_ parts: [Article], named name: String) -> Series? {
        guard !parts.isEmpty else { return nil }
        let ids = parts.map(\.id)
        var gathered = series.first { $0.parts.contains(where: ids.contains) }
            ?? Series(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parts: [])
        gathered.parts = ids + gathered.parts.filter { !ids.contains($0) }
        updateSeries { all in
            for index in all.indices where all[index].id != gathered.id { all[index].parts.removeAll(where: ids.contains) }
            all.removeAll { $0.parts.isEmpty }
            if let index = all.firstIndex(where: { $0.id == gathered.id }) { all[index] = gathered } else { all.append(gathered) }
        }
        return gathered
    }

    /// The chapters of the serial the article is a chapter of, found from the links between them. `found` hears
    /// of them as they're found.
    public func findChapters(around article: Article, found: ([Chapter]) -> Void) async throws -> ChapterSearch {
        guard let url = article.sourceURL else { throw ReedError.invalidURL }
        // Its own, so finding chapters doesn't wait on an article being saved.
        let extractor = ArticleExtractor()
        let finder = ChapterFinder { [downloader] url in
            let page = try await downloader.page(at: url)
            return (page.url, try await extractor.pageLinks(html: page.html, url: page.url))
        }
        return try await finder.chapters(around: url, found: found)
    }

    /// Saves the chapters not saved yet, and gathers them all into one series in the order given.
    @discardableResult public func save(_ chapters: [Chapter], asSeriesNamed name: String) throws -> Series? {
        gather(try chapters.map { try add($0.url.absoluteString) }, named: name)
    }

    /// Takes an article out of its series, which goes once it has no parts left.
    public func removeFromSeries(_ article: Article) {
        guard series(of: article) != nil else { return }
        updateSeries { all in
            for index in all.indices { all[index].parts.removeAll { $0 == article.id } }
            all.removeAll { $0.parts.isEmpty }
        }
    }

    public func moveParts(of series: Series, from offsets: IndexSet, to destination: Int) {
        updateSeries { all in
            guard let index = all.firstIndex(where: { $0.id == series.id }) else { return }
            let parts = all[index].parts
            let moved = offsets.map { parts[$0] }
            var rest = parts.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
            rest.insert(contentsOf: moved, at: destination - offsets.count { $0 < destination })
            all[index].parts = rest
        }
    }

    public func rename(_ series: Series, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        updateSeries { all in
            guard let index = all.firstIndex(where: { $0.id == series.id }) else { return }
            all[index].name = name
        }
    }

    /// Ends a series, keeping its articles.
    public func ungroup(_ series: Series) {
        updateSeries { $0.removeAll { $0.id == series.id } }
    }

    func updateSeries(_ change: (inout [Series]) -> Void) {
        let previous = series
        change(&series)
        do { try JSONEncoder().encode(series).write(to: Self.seriesURL(root: storage.root), options: .atomic) }
        catch { series = previous; errorMessage = error.localizedDescription }
    }

    static func seriesURL(root: URL) -> URL { root.appendingPathComponent("Series.json") }
}
