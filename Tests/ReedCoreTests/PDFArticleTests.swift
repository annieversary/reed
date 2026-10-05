import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ReedCore

@Test func wrappedLinesRejoinWordsBrokenAtTheEnd() {
    #expect(PDFText.join(["the residual func-", "tions are learned"]) == "the residual functions are learned")
    // Spelled with its hyphen elsewhere in the document, it keeps it.
    #expect(PDFText.join(["a user-", "specified map"], hyphenated: ["user-specified"]) == "a user-specified map")
    #expect(PDFText.join(["our 34-", "layer net"]) == "our 34-layer net")
    #expect(PDFText.join(["ends here -", "Then"]) == "ends here - Then")
}

@Test func linesAreToldApartByWhatTheySay() {
    #expect(PDFText.isMarker("1)") && PDFText.isMarker("[12]") && PDFText.isMarker("•"))
    #expect(!PDFText.isMarker("Abstract"))
    #expect(PDFText.looksLikeCode(["int main() {", "  return 0;", "}"]))
    #expect(!PDFText.looksLikeCode(["The map function emits pairs; the reduce", "function merges them."]))
    #expect(PDFText.looksLikeMath("λ = z q/p"))
    #expect(!PDFText.looksLikeMath("1) 2)") && !PDFText.looksLikeMath("Owner 1's Signature"))
}

@Test func arxivPapersWithoutHTMLAreReadFromTheirPDF() throws {
    let abstract = try #require(URL(string: "https://arxiv.org/abs/1512.03385"))
    #expect(ArticleDownloader.arxivPDF(for: abstract, extracted: "<h2>Abstract</h2><p>We present</p>")?.absoluteString == "https://arxiv.org/pdf/1512.03385")
    #expect(ArticleDownloader.arxivPDF(for: abstract, extracted: "<h2>Abstract</h2><p>We present</p><h2>Paper</h2>") == nil)
    #expect(ArticleDownloader.arxivPDF(for: try #require(URL(string: "https://example.com/abs/1")), extracted: "") == nil)
}

@Test func aPDFReflowsIntoParagraphsHeadingsAndCode() async throws {
    guard #available(macOS 26, iOS 26, *) else { return }
    let lorem = "Reading a paper laid out for print means following its columns and skipping the running heads. "
    let pdf = drawnPDF([
        .init(text: "Reading Papers Offline", font: "Times-Bold", size: 22, gapAfter: 18),
        .init(text: "1 Introduction", font: "Times-Bold", size: 12, gapAfter: 6),
        .init(text: String(repeating: lorem, count: 5) + "So the text is reflowed.", font: "Times-Roman", size: 10, gapAfter: 10),
        .init(text: String(repeating: lorem, count: 3) + "Here is a listing.", font: "Times-Roman", size: 10, gapAfter: 10),
        .init(text: "int main(int argc, char** argv) {\n    puts(\"hello\");\n    return 0;\n}", font: "Courier", size: 9, gapAfter: 10),
        .init(text: String(repeating: lorem, count: 2) + "That is all.", font: "Times-Roman", size: 10, gapAfter: 0),
    ])
    let (article, images) = try await PDFArticle.extract(pdf, url: try #require(URL(string: "https://example.com/papers/offline.pdf")))
    #expect(article.title == "Reading Papers Offline")
    #expect(article.html.contains("<h2>1 Introduction</h2>"))
    #expect(article.html.components(separatedBy: "<p>").count - 1 == 3)
    #expect(article.html.contains("<pre>int main(int argc, char** argv) {\n    puts(&quot;hello&quot;);\n    return 0;\n}</pre>"))
    #expect(article.excerpt.hasPrefix("Reading a paper laid out"))
    #expect(article.wordCount > 150)
    #expect(images.isEmpty && article.images.isEmpty)
}

private struct Paragraph {
    let text: String, font: String, size: CGFloat, gapAfter: CGFloat
}

/// A one-page PDF with each paragraph set in its own frame, top to bottom.
private func drawnPDF(_ paragraphs: [Paragraph]) -> Data {
    let data = NSMutableData()
    var page = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &page, nil)!
    context.beginPDFPage(nil)
    var top: CGFloat = 720
    for paragraph in paragraphs {
        let font = CTFontCreateWithName(paragraph.font as CFString, paragraph.size, nil)
        let text = NSAttributedString(string: paragraph.text, attributes: [.init(kCTFontAttributeName as String): font])
        let setter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: 468, height: CGFloat.greatestFiniteMagnitude), nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: 72, y: top - size.height, width: 468, height: size.height), transform: nil), nil)
        CTFrameDraw(frame, context)
        top -= size.height + paragraph.gapAfter
    }
    context.endPDFPage()
    context.closePDF()
    return data as Data
}
