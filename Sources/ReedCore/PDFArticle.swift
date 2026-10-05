import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
#if canImport(AppKit)
import AppKit
private typealias PlatformFont = NSFont
#else
import UIKit
private typealias PlatformFont = UIFont
#endif

/// PDFs, reflowed into an article. The text layer gives the words and Vision's document layout gives the
/// reading order; paragraphs, headings, captions and code are found from how the lines sit on the page.
/// Figures, tables and displayed equations, which don't reflow, are cropped from the page as pictures.
@available(macOS 26, iOS 26, *)
enum PDFArticle {
    /// The article, and the pictures it refers to, by file name.
    static func extract(_ data: Data, url: URL) async throws -> (ExtractedArticle, [String: Data]) {
        let work = Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw ReedError.unreadablePDF }
            let reflow = PDFReflow(document: document, url: url)
            let article = try await reflow.article()
            return (article, reflow.images)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

// MARK: - Model

struct PDFLine {
    /// In page space, whose origin is at the bottom left.
    var rect: CGRect
    var text: String
    var fontSize: CGFloat
    /// The share of its characters set in a maths font.
    var mathFraction: Double = 0
    var bold = false
    var mono = false
}

struct PDFBlock {
    enum Kind { case body, heading, caption, label, equation, code, footnote, furniture, figure }
    var rows: [[PDFLine]]
    var kind: Kind = .body
    /// The picture of a figure or equation, once cropped.
    var image: String?

    init(rows: [[PDFLine]], kind: Kind = .body) { self.rows = rows; self.kind = kind }
    /// A figure covering `rect`.
    init(figure rect: CGRect) { self.init(rows: [[PDFLine(rect: rect, text: "", fontSize: 0)]], kind: .figure) }

    var lines: [PDFLine] { rows.flatMap { $0 } }
    var rect: CGRect { lines.map(\.rect).reduce(CGRect.null) { $0.union($1) } }
    var fontSize: CGFloat { median(lines.map(\.fontSize)) }
    var mathFraction: Double { lines.map(\.mathFraction).reduce(0, +) / Double(max(lines.count, 1)) }
    var rowTexts: [String] { rows.map { $0.map(\.text).joined(separator: " ") } }
}

private func median(_ values: [CGFloat]) -> CGFloat { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
private func overlapX(_ a: CGRect, _ b: CGRect) -> CGFloat { min(a.maxX, b.maxX) - max(a.minX, b.minX) }
private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }
private func isMath(_ row: [PDFLine]) -> Bool { row.map(\.mathFraction).reduce(0, +) / Double(max(row.count, 1)) > 0.35 }

// MARK: - Text

enum PDFText {
    static var caption: some RegexComponent { /^(Figure|Fig\.|Table|Listing|Algorithm)\s*[0-9IVX]+[.:]/ }
    static var numbered: some RegexComponent { /^(\d+(\.\d+)*\.?|[A-Z]\.|[IVX]+\.)\s+\S/ }
    /// A numbered section heading, as opposed to a label such as "18 layers".
    static var section: some RegexComponent { /^(\d+(\.\d+)*\.?|[A-Z]\.)\s+[A-Z]/ }

    /// Joins wrapped lines, rejoining words hyphenated at a line break unless the document spells them
    /// with the hyphen elsewhere.
    static func join(_ rows: [String], vocabulary: Set<String> = [], hyphenated: Set<String> = []) -> String {
        var out = ""
        for row in rows.map({ $0.trimmingCharacters(in: .whitespaces) }) where !row.isEmpty {
            if out.hasSuffix("-"), let next = row.first, next.isLowercase {
                let stem = (out.split(separator: " ").last.map(String.init) ?? "").dropLast().trimmingCharacters(in: .punctuationCharacters)
                let word = (row.split(separator: " ").first.map(String.init) ?? "").trimmingCharacters(in: .punctuationCharacters)
                let joined = (stem + word).lowercased()
                let keepHyphen = !vocabulary.contains(joined) && (hyphenated.contains((stem + "-" + word).lowercased()) || stem.contains(where: \.isNumber))
                if !keepHyphen { out.removeLast() }
                out += row
                continue
            }
            out += out.isEmpty ? row : " " + row
        }
        return out
    }

    /// A list marker or reference number, set apart from the text it introduces.
    static func isMarker(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\(?[0-9a-zA-Z]{1,3}[\).]|\[\d{1,3}\]|[•–\-∗*]/) != nil
    }

    /// Source code, even in an ordinary font: most of its lines end or open the way code lines do.
    static func looksLikeCode(_ rows: [String]) -> Bool {
        let rows = rows.map { $0.trimmingCharacters(in: .whitespaces) }
        let code = rows.filter { row in
            row.contains(/[;{}]$|^\/\/|^#(include|define|import)\b|^[{}()\[\];, ]+$/)
                || row.contains(/^(if|for|while|return|class|struct|public|private|virtual|const|int|void|def|let|var|func|fn)\b.*[(){=;:]/)
        }.count
        return code * 2 > rows.count && !rows.joined(separator: " ").contains(caption)
    }

    static func looksLikeMath(_ text: String) -> Bool {
        if text.split(separator: " ").allSatisfy({ isMarker(String($0)) }) { return false }
        let visible = text.filter { !$0.isWhitespace }
        guard !visible.isEmpty, !text.hasSuffix("."), !text.contains(caption) else { return false }
        return text.contains(/[=∑Σ≤≥∫√±∞]/) || Double(visible.filter(\.isLetter).count) / Double(visible.count) < 0.5
    }
}

// MARK: - Reflow

@available(macOS 26, iOS 26, *)
final class PDFReflow {
    private let document: PDFDocument
    private let url: URL
    private var pages: [[PDFBlock]] = []
    private var bodySize: CGFloat = 10
    private var vocabulary: Set<String> = [], hyphenated: Set<String> = []
    private(set) var images: [String: Data] = [:]
    /// Pages are drawn at this many pixels a point to look for ink, and cropped at `cropScale`.
    private let scale: CGFloat = 2, cropScale: CGFloat = 4
    private var drawn: (page: Int, image: CGImage)?

    init(document: PDFDocument, url: URL) {
        self.document = document
        self.url = url
    }

    func article() async throws -> ExtractedArticle {
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            pages.append(await blocks(on: index))
        }
        learnDocument()
        for index in pages.indices {
            try Task.checkCancellation()
            arrange(page: index)
        }
        return output()
    }

    private func page(_ index: Int) -> PDFPage { document.page(at: index)! }
    private func box(_ index: Int) -> CGRect { page(index).bounds(for: .mediaBox) }
    private func text(_ block: PDFBlock) -> String { PDFText.join(block.rowTexts, vocabulary: vocabulary, hyphenated: hyphenated) }

    // MARK: Lines and paragraphs

    private func blocks(on index: Int) async -> [PDFBlock] {
        let page = page(index), box = box(index)
        let layout = try? await RecognizeDocumentsRequest().perform(on: render(index)).first?.document
        func toPage(_ r: NormalizedRect) -> CGRect {
            CGRect(x: box.minX + r.cgRect.minX * box.width, y: box.minY + r.cgRect.minY * box.height,
                   width: r.cgRect.width * box.width, height: r.cgRect.height * box.height)
        }
        var lines: [PDFLine]
        if isScanned(page) {
            // Vision reads a scan better than the OCR some scanners leave in it.
            lines = (layout?.text.lines ?? []).map { line in
                let r = toPage(line.boundingRegion.boundingBox)
                return PDFLine(rect: r, text: line.transcript, fontSize: r.height * 0.75)
            }
        } else {
            // The text layer's lines, in the order of the Vision paragraph each falls in. Lines outside
            // every paragraph keep their place after the line before them.
            var regions = (layout?.paragraphs ?? []).enumerated().map { (rect: toPage($0.element.boundingRegion.boundingBox), order: Double($0.offset)) }
            for list in layout?.lists ?? [] {
                let r = toPage(list.boundingRegion.boundingBox)
                let above = regions.filter { $0.rect.midY > r.maxY - 2 && overlapX($0.rect, r) > 0 }.min { $0.rect.minY < $1.rect.minY }
                regions.append((r, (above?.order ?? -1) + 0.5))
            }
            var region = -1.0
            var keyed: [(order: Double, index: Int, line: PDFLine)] = []
            for (n, selection) in (page.selection(for: box)?.selectionsByLine() ?? []).enumerated() {
                guard let line = Self.line(selection, on: page) else { continue }
                if let best = regions.max(by: { $0.rect.intersection(line.rect).area < $1.rect.intersection(line.rect).area }),
                   best.rect.intersection(line.rect).area > 0.3 * line.rect.area { region = best.order }
                keyed.append((region, n, line))
            }
            lines = keyed.sorted { ($0.order, $0.index) < ($1.order, $1.index) }.map(\.line)
                .filter { $0.rect.height < $0.rect.width * 2 || $0.text.count < 3 } // rotated margin stamps
        }
        // List markers and reference numbers join the text beside them, wherever reading order put them.
        for m in lines.indices.reversed() where PDFText.isMarker(lines[m].text) {
            let marker = lines[m]
            guard let k = lines.indices.filter({ $0 != m && abs(lines[$0].rect.midY - marker.rect.midY) < 0.4 * min(lines[$0].fontSize, marker.fontSize)
                    && lines[$0].rect.minX > marker.rect.maxX - 1 && lines[$0].rect.minX - marker.rect.maxX < max(marker.fontSize, 8) * 3 })
                .min(by: { lines[$0].rect.minX < lines[$1].rect.minX }) else { continue }
            lines[k].text = marker.text + " " + lines[k].text
            lines[k].rect = lines[k].rect.union(marker.rect)
            lines.remove(at: m)
        }
        return paragraphs(of: rows(of: lines))
    }

    /// Pieces of one printed line, joined, wherever reading order put them.
    private func rows(of lines: [PDFLine]) -> [[PDFLine]] {
        var rows: [[PDFLine]] = []
        for line in lines {
            let row = rows.indices.last { r in
                let last = rows[r].last!
                let gap = line.rect.minX - last.rect.maxX
                // Wide enough for a gap between sentences, too narrow for a gutter between columns.
                let widest = max(line.fontSize, 8) * (PDFText.isMarker(last.text) ? 3 : 1.2)
                return abs(line.rect.midY - last.rect.midY) < 0.4 * min(line.fontSize, last.fontSize) && gap > -2 && gap < widest
            }
            if let row { rows[row].append(line) } else { rows.append([line]) }
        }
        return rows
    }

    private func paragraphs(of rows: [[PDFLine]]) -> [PDFBlock] {
        func rect(_ row: [PDFLine]) -> CGRect { row.map(\.rect).reduce(CGRect.null) { $0.union($1) } }
        // Columns: left edges at least three rows share, each with the usual right edge of those rows.
        var lefts: [(left: CGFloat, rights: [CGFloat])] = []
        for r in rows.map(rect) {
            if let k = lefts.firstIndex(where: { abs($0.left - r.minX) < 3 }) { lefts[k].rights.append(r.maxX) }
            else { lefts.append((r.minX, [r.maxX])) }
        }
        let columns = lefts.filter { $0.rights.count >= 3 }.map { (left: $0.left, right: median($0.rights)) }
        func column(_ r: CGRect) -> (left: CGFloat, right: CGFloat) {
            guard let c = columns.filter({ $0.left <= r.minX + 3 && $0.right > r.minX }).max(by: { $0.left < $1.left }) else { return (r.minX, r.maxX) }
            return (c.left, max(c.right, r.maxX))
        }
        var blocks: [PDFBlock] = []
        for row in rows {
            let r = rect(row), size = median(row.map(\.fontSize))
            if var block = blocks.last {
                let previous = block.rows.last!, pr = rect(previous)
                let (left, right) = column(pr)
                let step = pr.midY - r.midY
                let code = previous.allSatisfy(\.mono) && row.allSatisfy(\.mono)
                if code, step > size * 0.5, step < size * 1.8, overlapX(block.rect, r) > 0 || r.minX >= block.rect.minX {
                    block.rows.append(row)
                    blocks[blocks.count - 1] = block
                    continue
                }
                let sameColumn = overlapX(pr, r) > 0.5 * min(pr.width, r.width)
                // A paragraph ends at a short line or a vertical gap; the next may start indented.
                let previousShort = pr.maxX < right - max((right - left) * 0.1, size * 2.5)
                let indented = r.minX > left + size * 0.8 && r.minX < left + size * 4 && r.minX > pr.minX + size * 0.8
                let alike = abs(size - block.fontSize) < 0.8 && previous.allSatisfy(\.bold) == row.allSatisfy(\.bold)
                    && isMath(previous) == isMath(row) && previous.allSatisfy(\.mono) == row.allSatisfy(\.mono)
                if sameColumn, step > size * 0.5, step < size * 1.55, !previousShort, !indented, alike {
                    block.rows.append(row)
                    blocks[blocks.count - 1] = block
                    continue
                }
            }
            blocks.append(PDFBlock(rows: [row]))
        }
        return blocks
    }

    private static var mathFonts: some RegexComponent { /CMMI|CMSY|CMEX|MSBM|MSAM|Math|Symbol|rsfs|esint/ }
    private static var monoFonts: some RegexComponent { /Courier|Mono|Consol|Menlo|CMTT|Inconsolata|Code/ }

    private static func line(_ selection: PDFSelection, on page: PDFPage) -> PDFLine? {
        guard let string = selection.attributedString else { return nil }
        var sizes: [CGFloat: Int] = [:], math = 0, bold = 0, mono = 0, total = 0
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let font = value as? PlatformFont else { return }
            let count = (string.string as NSString).substring(with: range).filter { !$0.isWhitespace }.count
            sizes[font.pointSize.rounded(), default: 0] += count
            total += count
            let name = font.fontName
            if name.contains(mathFonts) { math += count }
            if name.contains(monoFonts) { mono += count }
            if name.localizedCaseInsensitiveContains("bold") || name.contains("CMBX") || name.contains("Medi") { bold += count }
        }
        guard total > 0 else { return nil }
        return PDFLine(rect: selection.bounds(for: page),
                       text: string.string.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces),
                       fontSize: sizes.max { $0.value < $1.value }!.key, mathFraction: Double(math) / Double(total),
                       bold: bold * 2 > total, mono: mono * 10 > total * 9)
    }

    /// A page that's a picture of text, whose text layer, if any, is someone else's OCR.
    private func isScanned(_ page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return false }
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var pageSizedImage = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let info = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?, width: CGPDFInteger = 0, height: CGPDFInteger = 0
            if CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image",
               CGPDFDictionaryGetInteger(info, "Width", &width), CGPDFDictionaryGetInteger(info, "Height", &height), width * height > 1_500_000 {
                pageSizedImage = true
            }
            return true
        }, nil)
        return pageSizedImage
    }

    // MARK: The whole document

    private func learnDocument() {
        var sizes: [CGFloat: Int] = [:]
        for line in pages.joined().flatMap(\.lines) {
            sizes[line.fontSize.rounded(), default: 0] += line.text.count
            // A line's last word may be broken off; the rest show how the document spells its words.
            for word in line.text.split(separator: " ").dropLast() {
                let word = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
                if word.dropFirst().dropLast().contains("-") { hyphenated.insert(word) } else { vocabulary.insert(word) }
            }
        }
        bodySize = sizes.max { $0.value < $1.value }?.key ?? 10
    }

    /// How often text near the top or bottom of pages recurs: running headers and footers.
    private lazy var edgeCounts: [String: Int] = {
        var counts: [String: Int] = [:]
        for (index, blocks) in pages.enumerated() {
            for block in blocks where block.rows.count <= 2 && isAtEdge(block, page: index) { counts[letters(text(block)), default: 0] += 1 }
        }
        return counts
    }()

    private func letters(_ text: String) -> String { text.lowercased().filter(\.isLetter) }
    private func isAtEdge(_ block: PDFBlock, page: Int) -> Bool {
        let box = box(page), y = block.rect.midY
        return y < box.minY + box.height * 0.1 || y > box.minY + box.height * 0.9
    }

    // MARK: A page's parts

    private func arrange(page index: Int) {
        classify(page: index)
        findDrawings(page: index)
        gatherLabels(page: index)
        mergeEquations(page: index)
        claimForCaptions(page: index)
        mergeCode(page: index)
        for b in pages[index].indices where [.figure, .equation].contains(pages[index][b].kind) {
            pages[index][b].image = crop(pages[index][b].rect, page: index)
        }
        drawn = nil
    }

    /// The left and right edges of the column a block sits in.
    private func column(of block: PDFBlock, in blocks: [PDFBlock]) -> (left: CGFloat, right: CGFloat) {
        let peers = blocks.filter { overlapX($0.rect, block.rect) > 0.6 * min($0.rect.width, block.rect.width) && $0.rows.count > 2 }
        return (peers.map(\.rect.minX).min() ?? block.rect.minX, peers.map(\.rect.maxX).max() ?? block.rect.maxX)
    }

    private func classify(page index: Int) {
        let blocks = pages[index], box = box(index)
        for j in blocks.indices {
            var block = blocks[j]
            let text = text(block), words = text.split(separator: " ").count
            let lastMark = text.last.map { ".:?!".contains($0) } ?? false
            if isAtEdge(block, page: index) && block.rows.count <= 2
                && (text.allSatisfy { $0.isNumber || $0.isWhitespace } || (edgeCounts[letters(text)] ?? 0) >= max(3, document.pageCount / 3)) {
                block.kind = .furniture
            } else if text.contains(PDFText.caption) {
                block.kind = .caption
            } else if block.lines.allSatisfy(\.mono) || PDFText.looksLikeCode(block.rowTexts) {
                block.kind = .code
            } else if block.rows.count <= 3 && words <= 15 && PDFText.looksLikeMath(text) {
                block.kind = .label
            } else if block.mathFraction > 0.35 && words < 40
                        || block.rows.count <= 2 && text.contains(/\(\d+[a-z]?\)$/) && block.rect.minX > column(of: block, in: blocks).left + bodySize * 2 {
                block.kind = .equation
            } else if block.fontSize >= bodySize * 1.15 && words <= 20 {
                block.kind = .heading
            } else if block.rows.count == 1 && words <= 12 && (text.contains(PDFText.numbered) || block.lines.allSatisfy(\.bold)) && !text.hasSuffix(".")
                        || block.rows.count == 1 && words <= 8 && block.lines.allSatisfy(\.bold) {
                block.kind = .heading
            } else if block.fontSize < bodySize * 0.88 && block.rect.midY < box.minY + box.height * 0.2
                        && (text.first.map { $0.isNumber || "*†‡§".contains($0) } ?? false) {
                block.kind = .footnote
            } else if words <= 4 && block.rows.count <= 2 && !lastMark || block.fontSize < bodySize * 0.8 && words < 15 {
                // Too short to be a paragraph: a label in a drawing, unless it turns out to stand alone.
                block.kind = .label
            }
            pages[index][j] = block
        }
    }

    /// Drawings show as inked space between the text: labels inside them were set aside as labels.
    private func findDrawings(page index: Int) {
        let blocks = pages[index]
        let kept = blocks.filter { ![.label, .furniture].contains($0.kind) }
        let content = blocks.filter { $0.kind != .furniture }
        guard !kept.isEmpty else { return }
        let top = content.map(\.rect.maxY).max()!, bottom = content.map(\.rect.minY).min()!
        let left = content.map(\.rect.minX).min()!, right = content.map(\.rect.maxX).max()!
        let solid = kept.filter { $0.kind != .figure }.map { $0.rect.insetBy(dx: 1, dy: 1) }
        let labels = blocks.filter { $0.kind == .label }.map(\.rect)
        var found: [(rect: CGRect, before: Int)] = []
        func consider(_ region: CGRect, before position: Int) {
            guard region.height > 24, !solid.contains(where: { $0.intersects(region.insetBy(dx: 0, dy: 1)) }) else { return }
            // Across the gutter, when nothing else on the page is in the way.
            let wide = CGRect(x: left, y: region.minY, width: right - left, height: region.height)
            let area = solid.contains(where: { $0.intersects(wide) }) ? region : wide
            guard let inked = ink(in: area.insetBy(dx: 0, dy: 1), page: index), !found.contains(where: { $0.rect.intersects(inked) }) else { return }
            // Ink that's mostly short lines of text, such as a title page's authors, isn't a drawing.
            let lettered = labels.map { $0.intersection(inked).area }.reduce(0, +)
            guard lettered < inked.area * 0.5 else { return }
            found.append((inked, position))
        }
        // Each column's blocks in reading order, and the space above, between and below them.
        var tails: [CGRect] = []
        for b in blocks.indices where ![.label, .furniture].contains(blocks[b].kind) {
            let r = blocks[b].rect
            if let c = tails.firstIndex(where: { overlapX($0, r) > 0.4 * min($0.width, r.width) && $0.minY > r.maxY - 2 }) {
                let previous = tails[c]
                if previous.minY - r.maxY > bodySize * 2.5 {
                    consider(CGRect(x: min(previous.minX, r.minX), y: r.maxY + 1, width: max(previous.maxX, r.maxX) - min(previous.minX, r.minX),
                                    height: previous.minY - r.maxY - 2), before: b)
                }
                tails[c] = r
            } else {
                if top - r.maxY > bodySize * 2.5 { consider(CGRect(x: r.minX, y: r.maxY + 1, width: r.width, height: top - r.maxY - 1), before: b) }
                tails.append(r)
            }
        }
        for tail in tails where tail.minY - bottom > bodySize * 2.5 {
            consider(CGRect(x: tail.minX, y: bottom, width: tail.width, height: tail.minY - bottom - 1), before: blocks.count)
        }
        // A drawing found in pieces is one, unless joining them would cover text.
        var merged = true
        while merged {
            merged = false
            search: for a in found.indices {
                for b in found.indices where a < b {
                    let union = found[a].rect.union(found[b].rect)
                    if found[a].rect.insetBy(dx: -bodySize, dy: -bodySize).intersects(found[b].rect), !solid.contains(where: { $0.intersects(union) }) {
                        found[a] = (union, min(found[a].before, found[b].before))
                        found.remove(at: b)
                        merged = true
                        break search
                    }
                }
            }
        }
        for figure in found.sorted(by: { $0.before > $1.before }) {
            pages[index].insert(PDFBlock(figure: figure.rect), at: min(figure.before, pages[index].count))
        }
    }

    /// Labels outside drawings: runs of them are maths set in pieces, or a chart whose drawing wasn't found,
    /// and a lone one is just a short line.
    private func gatherLabels(page index: Int) {
        let figures = pages[index].filter { $0.kind == .figure }.map { $0.rect.insetBy(dx: -3, dy: -3) }
        var out: [PDFBlock] = [], run: [PDFBlock] = []
        func endRun() {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let mathy = run.contains { text($0).contains(/[=+−×∑Σλπ∫√≤≥∞]/) || $0.mathFraction > 0 }
            guard run.count >= 2 && mathy || run.contains(where: { PDFText.looksLikeMath(text($0)) }) else {
                out += run.map { var block = $0; block.kind = .body; return block }
                return
            }
            var block = PDFBlock(rows: run.flatMap(\.rows), kind: .equation)
            if block.rect.height > bodySize * 5 {
                block = PDFBlock(figure: ink(in: clear(block.rect.insetBy(dx: -bodySize, dy: -bodySize), around: block.rect, page: index), page: index) ?? block.rect)
            }
            out.append(block)
        }
        for block in pages[index] {
            guard block.kind == .label, !figures.contains(where: { $0.contains(CGPoint(x: block.rect.midX, y: block.rect.midY)) }) else {
                endRun()
                out.append(block)
                continue
            }
            let reach = run.map(\.rect).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -bodySize * 2, dy: -bodySize * 2)
            if !run.isEmpty && !reach.intersects(block.rect) { endRun() }
            run.append(block)
        }
        endRun()
        pages[index] = out
    }

    /// An equation set in pieces is cropped whole, with the stray bits beside it; equations touching a
    /// drawing are its labels.
    private func mergeEquations(page index: Int) {
        func isFragment(_ block: PDFBlock) -> Bool {
            guard [.body, .heading, .code].contains(block.kind), block.rows.count <= 2 else { return false }
            let text = text(block).trimmingCharacters(in: .whitespaces)
            return text.split(separator: " ").count <= 6 && !text.hasSuffix(".") && !text.hasSuffix(":")
        }
        var blocks = pages[index]
        var merged = true
        while merged {
            merged = false
            search: for a in blocks.indices where blocks[a].kind == .equation {
                let reach = blocks[a].rect.insetBy(dx: -bodySize * 2, dy: -bodySize * 0.8)
                for b in blocks.indices where b != a && (blocks[b].kind == .equation || isFragment(blocks[b])) && reach.intersects(blocks[b].rect) {
                    let (keep, drop) = (min(a, b), max(a, b))
                    blocks[keep].rows = (blocks[keep].rows + blocks[drop].rows).sorted { $0[0].rect.midY > $1[0].rect.midY }
                    blocks[keep].kind = .equation
                    blocks.remove(at: drop)
                    merged = true
                    break search
                }
            }
        }
        for f in blocks.indices where blocks[f].kind == .figure {
            let near = blocks.indices.filter { blocks[$0].kind == .equation && blocks[$0].rect.intersects(blocks[f].rect.insetBy(dx: -bodySize, dy: -bodySize)) }
            guard !near.isEmpty else { continue }
            let union = near.map { blocks[$0].rect }.reduce(blocks[f].rect) { $0.union($1) }
            blocks[f] = PDFBlock(figure: ink(in: clear(union.insetBy(dx: -2, dy: -2), around: union, page: index), page: index) ?? union)
            for n in near { blocks[n].kind = .label }
        }
        pages[index] = blocks
    }

    private func isProse(_ block: PDFBlock) -> Bool {
        guard block.kind == .body, block.rows.count >= 2 else { return false }
        let tokens = text(block).split(separator: " ")
        let numeric = tokens.filter { $0.contains(where: \.isNumber) }.count
        return Double(tokens.count) / Double(block.rows.count) >= 6 && Double(numeric) < Double(tokens.count) * 0.3
    }

    /// A caption claims everything beside it that isn't prose, its table's cells or its figure's labels,
    /// and they're cropped as one picture beside it.
    private func claimForCaptions(page index: Int) {
        let blocks = pages[index]
        var claimed = Set<Int>()
        var figures: [(caption: Int, below: Bool, block: PDFBlock)] = []
        /// The blocks running away from a caption, nearest first, until prose, a section heading, another
        /// caption, or something another caption claimed.
        func claim(_ c: Int, below: Bool) -> [Int] {
            let caption = blocks[c]
            let band = caption.rect.insetBy(dx: -bodySize * 3, dy: 0)
            let side = blocks.indices.filter { i in
                let r = blocks[i].rect
                return i != c && overlapX(r, band) > min(r.width * 0.75, band.width * 0.5) && (below ? r.maxY <= caption.rect.minY + 2 : r.minY >= caption.rect.maxY - 2)
            }.sorted { below ? blocks[$0].rect.maxY > blocks[$1].rect.maxY : blocks[$0].rect.minY < blocks[$1].rect.minY }
            var taken: [Int] = []
            var edge = below ? caption.rect.minY : caption.rect.maxY
            for i in side {
                let block = blocks[i]
                if block.kind == .furniture { continue }
                let gap = below ? edge - block.rect.maxY : block.rect.minY - edge
                let section = block.kind == .heading && (text(block).contains(PDFText.section) || block.rect.width > band.width * 0.5)
                if gap > bodySize * 2.5 || claimed.contains(i) || section || [.caption, .footnote].contains(block.kind) || isProse(block) { break }
                taken.append(i)
                edge = below ? min(edge, block.rect.minY) : max(edge, block.rect.maxY)
            }
            // A side holding only a line or two of ordinary text isn't the caption's.
            return taken.contains { [.figure, .label, .equation].contains(blocks[$0].kind) } ? taken : []
        }
        func take(_ c: Int, _ taken: [Int], below: Bool) {
            let caption = blocks[c].rect
            let union = taken.map { blocks[$0].rect }.reduce(CGRect.null) { $0.union($1) }
            var search = union.insetBy(dx: -bodySize, dy: -bodySize * 0.4)
            if search.intersects(caption) {
                search = below
                    ? CGRect(x: search.minX, y: search.minY, width: search.width, height: caption.minY - 3 - search.minY)
                    : CGRect(x: search.minX, y: caption.maxY + 3, width: search.width, height: search.maxY - caption.maxY - 3)
            }
            claimed.formUnion(taken)
            figures.append((c, below, PDFBlock(figure: ink(in: clear(search, around: union, page: index), page: index) ?? union)))
        }
        var open = blocks.indices.filter { blocks[$0].kind == .caption }
        // Captions with something on one side only go first, so the rest can't take what's theirs.
        while true {
            let sides = open.map { (c: $0, above: claim($0, below: false), below: claim($0, below: true)) }
            guard let sure = sides.first(where: { $0.above.isEmpty != $0.below.isEmpty }) else {
                for side in sides {
                    let (above, below) = (claim(side.c, below: false), claim(side.c, below: true))
                    if above.isEmpty && below.isEmpty { continue }
                    // Tables are usually captioned above, figures below.
                    let useBelow = text(blocks[side.c]).hasPrefix("Table") ? !below.isEmpty : above.isEmpty
                    take(side.c, useBelow ? below : above, below: useBelow)
                }
                break
            }
            take(sure.c, sure.above.isEmpty ? sure.below : sure.above, below: sure.above.isEmpty)
            open.removeAll { $0 == sure.c }
        }
        for i in claimed { pages[index][i].kind = .label }
        for figure in figures.sorted(by: { $0.caption > $1.caption }) {
            pages[index].insert(figure.block, at: figure.below ? figure.caption + 1 : figure.caption)
        }
    }

    /// Code that reading order split up goes back together, top to bottom.
    private func mergeCode(page index: Int) {
        var out: [PDFBlock] = []
        for block in pages[index] {
            if block.kind == .code, let k = out.lastIndex(where: { $0.kind == .code }),
               out[k].rect.insetBy(dx: -bodySize * 4, dy: -bodySize * 2).intersects(block.rect),
               out[(k + 1)...].allSatisfy({ [.label, .furniture].contains($0.kind) }) {
                out[k].rows = (out[k].rows + block.rows).sorted { $0[0].rect.midY > $1[0].rect.midY }
            } else {
                out.append(block)
            }
        }
        pages[index] = out
    }

    // MARK: Pictures

    private func render(_ index: Int) -> CGImage {
        if let drawn, drawn.page == index { return drawn.image }
        let image = draw(page: index, region: box(index), scale: scale)
        drawn = (index, image)
        return image
    }

    private func draw(page index: Int, region: CGRect, scale: CGFloat) -> CGImage {
        let width = max(Int((region.width * scale).rounded(.up)), 1), height = max(Int((region.height * scale).rounded(.up)), 1)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        page(index).draw(with: .mediaBox, to: context)
        return context.makeImage()!
    }

    /// `region` cut back from text above and below `core`, so looking for ink around a drawing doesn't take
    /// in its caption or the paragraphs beside it.
    private func clear(_ region: CGRect, around core: CGRect, page index: Int) -> CGRect {
        var top = region.maxY, bottom = region.minY
        for block in pages[index] where [.body, .heading, .caption, .footnote, .code].contains(block.kind) {
            let r = block.rect
            guard r.intersects(region), !r.intersects(core), overlapX(r, core) > 0 else { continue }
            if r.minY >= core.maxY - 1 { top = min(top, r.minY - 2) }
            else if r.maxY <= core.minY + 1 { bottom = max(bottom, r.maxY + 2) }
        }
        return CGRect(x: region.minX, y: bottom, width: region.width, height: max(top - bottom, 0))
    }

    /// The bounds of what's drawn within `rect`, if there's enough of it to be a drawing.
    private func ink(in rect: CGRect, page index: Int) -> CGRect? {
        let image = render(index), box = box(index)
        let pixels = CGRect(x: (rect.minX - box.minX) * scale, y: (box.maxY - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width > 4, pixels.height > 4, let crop = image.cropping(to: pixels),
              let data = crop.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let rowBytes = crop.bytesPerRow, pixelBytes = crop.bitsPerPixel / 8
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                let o = y * rowBytes + x * pixelBytes
                if Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2]) < 3 * 235 {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard count > 200, maxX - minX > 30, maxY - minY > 20 else { return nil }
        return CGRect(x: rect.minX + CGFloat(minX) / scale, y: rect.maxY - CGFloat(maxY + 1) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private func crop(_ rect: CGRect, page index: Int) -> String? {
        let region = rect.insetBy(dx: -2, dy: -2).intersection(box(index))
        guard !region.isNull, region.width > 1, region.height > 1 else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, draw(page: index, region: region, scale: cropScale), nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let name = "image-\(images.count).png"
        images[name] = data as Data
        return name
    }

    // MARK: HTML

    private func output() -> ExtractedArticle {
        var html: [String] = [], footnotes: [String] = []
        var title: String?
        /// A paragraph that may go on in the next column or page.
        var pending: String?
        /// Figures that interrupt an unfinished paragraph, which go after it.
        var deferred: [String] = []
        var words = 0, excerpt: String?
        func finished(_ text: String) -> Bool { text.last.map { ".!?:".contains($0) } ?? true }
        func flush() {
            if let text = pending {
                html.append("<p>\(ArticleHTML.escape(text))</p>")
                words += text.split(separator: " ").count
                if excerpt == nil && text.count > 80 { excerpt = text }
            }
            pending = nil
            html += deferred
            deferred = []
        }
        /// Adds a figure or caption, joining a caption to the figure just before or after it.
        func place(figure: String? = nil, caption: String? = nil) {
            if let pending, !finished(pending) {
                add(to: &deferred)
            } else {
                flush()
                add(to: &html)
            }
            func add(to list: inout [String]) {
                if let caption, let last = list.last, last.hasSuffix("</figure>"), !last.contains("<figcaption>") {
                    list[list.count - 1] = String(last.dropLast("</figure>".count)) + "<figcaption>\(ArticleHTML.escape(caption))</figcaption></figure>"
                } else if let figure, let last = list.last, last.hasPrefix("<figure><figcaption>"), !last.contains("<img") {
                    list[list.count - 1] = String(last.dropLast("</figure>".count)) + figure + "</figure>"
                } else if let figure {
                    list.append("<figure>\(figure)</figure>")
                } else if let caption {
                    list.append("<figure><figcaption>\(ArticleHTML.escape(caption))</figcaption></figure>")
                }
            }
        }
        /// Pictures are as wide, relative to the text, as on the page.
        func image(_ block: PDFBlock, alt: String) -> String? {
            block.image.map { "<img src=\"\($0)\" alt=\"\(ArticleHTML.escape(alt))\" style=\"width:\(String(format: "%.1f", (block.rect.width + 4) / bodySize))em\">" }
        }
        for (index, blocks) in pages.enumerated() {
            for block in blocks {
                let text = text(block)
                switch block.kind {
                case .furniture, .label: continue
                case .figure:
                    if let image = image(block, alt: "") { place(figure: image) }
                case .equation:
                    flush()
                    if let image = image(block, alt: text) { html.append("<figure class=\"equation\">\(image)</figure>") }
                case .code:
                    flush()
                    let left = block.rect.minX, character = max(block.fontSize * 0.6, 1)
                    let code = block.rows.map { row in
                        String(repeating: " ", count: max(0, Int(((row[0].rect.minX - left) / character).rounded()))) + row.map(\.text).joined(separator: " ")
                    }
                    html.append("<pre>\(ArticleHTML.escape(code.joined(separator: "\n")))</pre>")
                case .caption:
                    place(caption: text)
                case .footnote:
                    footnotes.append(text)
                case .heading:
                    flush()
                    if title == nil && index == 0 && block.fontSize >= bodySize * 1.3 { title = text }
                    else { html.append("<h2>\(ArticleHTML.escape(text))</h2>") }
                case .body:
                    // A paragraph broken by a column or page goes on lower case.
                    if let previous = pending, !finished(previous), let first = text.first, first.isLowercase || first == "(" {
                        pending = PDFText.join([previous, text], vocabulary: vocabulary, hyphenated: hyphenated)
                        continue
                    }
                    flush()
                    pending = text
                }
            }
        }
        flush()
        if !footnotes.isEmpty {
            html.append("<hr><section class=\"footnotes\">" + footnotes.map { "<p>\(ArticleHTML.escape($0))</p>" }.joined() + "</section>")
        }
        let attributes = document.documentAttributes ?? [:]
        let titled = (attributes[PDFDocumentAttribute.titleAttribute] as? String).flatMap { name -> String? in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.count > 3 && !name.contains(/\.(docx?|tex|pdf)$|^Microsoft Word|^untitled/.ignoresCase()) ? name : nil
        }
        let named = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let created = (attributes[PDFDocumentAttribute.creationDateAttribute] as? Date).map { $0.timeIntervalSince1970 * 1000 }
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = self.images.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ExtractedArticle.Image(url: $0, filename: $0, alt: "") }
        return ExtractedArticle(title: title ?? titled ?? named, author: author?.isEmpty == false ? author : nil, publishedAt: created,
                                excerpt: String((excerpt ?? "").prefix(300)), html: html.joined(separator: "\n"),
                                wordCount: words, images: images, page: PageLinks(title: title ?? named, links: []))
    }
}
