import Foundation

public enum ArticleSpeech {
    /// The passages of a saved reader document to read aloud, one per block, starting with the title.
    /// Code, tables and figures are left out, since they don't make sense spoken.
    public static func passages(title: String, html: String) -> [String] {
        var body = Substring(html)
        if let start = body.range(of: "<main>"), let end = body.range(of: "</main>", options: .backwards), start.upperBound <= end.lowerBound {
            body = body[start.upperBound..<end.lowerBound]
        }
        let unspoken = #/<(pre|table|figure|script|style)\b.*?</\1\s*>|<span class="missing-image">.*?</span>/#
            .dotMatchesNewlines().ignoresCase()
        let block = #/</?(?:p|div|h[1-6]|li|ul|ol|dl|dt|dd|blockquote|section|article|header|footer|aside|hr)\b[^>]*>|<br\s*/?>/#
            .ignoresCase()
        // Source line breaks fall inside paragraphs, so blocks are separated with a character HTML text never contains.
        let blocks = String(body).replacing(unspoken, with: "\u{1}").replacing(block, with: "\u{1}").split(separator: "\u{1}")
        return ([title] + blocks.map { ArticleText.plain(String($0)) })
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
    }
}
