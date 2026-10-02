import Foundation
import NaturalLanguage

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

    /// The sentences of a passage, in order. Fragments with nothing to say, like a lone dash, stay with the sentence before.
    public static func sentences(in passage: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = passage
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: passage.startIndex..<passage.endIndex) { range, _ in
            let sentence = passage[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.isEmpty { return true }
            if !sentence.contains(where: { $0.isLetter || $0.isNumber }), let last = sentences.popLast() {
                sentences.append(last + " " + sentence)
            } else {
                sentences.append(sentence)
            }
            return true
        }
        return sentences.isEmpty ? [passage] : sentences
    }

    /// A sentence as Kokoro should be given it. Plural initialisms ("LLMs", "APIs") are written as possessives,
    /// which Kokoro spells out letter by letter, where it would otherwise sound them out as a word.
    public static func spoken(_ sentence: String) -> String {
        sentence.replacing(#/\b([A-Z]{2,5})s\b/#) { "\($0.1)'s" }
    }

    /// Misaki IPA for technical terms Kokoro's lexicon lacks or gets wrong. Keys match exactly,
    /// or in lowercase when the key is lowercase, so "macos" covers "macOS" and "MacOS".
    public static let pronunciations: [String: String] = [
        "JSON": "ʤˈAsᵊn",
        "YAML": "jˈæmᵊl",
        "TOML": "tˈɑmᵊl",
        "WASM": "wˈɑzᵊm",
        "OS": "ˌO ˈɛs",
        "macos": "mˈæk ˌO ˈɛs",
        "OAuth": "ˈO ˌɔθ",
        "PhD": "pˌi ˌAʧ dˈi",
        "LaTeX": "lˈAtˌɛk",
        "wifi": "wˈIfˌI",
        "github": "ɡˈɪthˌʌb",
        "gitlab": "ɡˈɪtlˌæb",
        "nginx": "ˈɛnʤənˌɛks",
        "kubernetes": "kˌubəɹnˈɛtiz",
        "postgres": "pˈOstɡɹˌɛs",
        "postgresql": "pˈOstɡɹˌɛs kjˌu ˈɛl",
        "mysql": "mˌI ˌɛs kjˌu ˈɛl",
        "graphql": "ɡɹˈæf kjˌu ˈɛl",
        "chatgpt": "ʧˈæt ʤˌi pˌi tˈi",
        "iphone": "ˈIfˌOn",
        "ipad": "ˈIpˌæd",
        "swiftui": "swˈɪft jˌu ˈI",
        "numpy": "nˈʌmpˌI",
        "pypi": "pˈI pˌi ˈI",
        "jupyter": "ʤˈupəɾəɹ",
        "devops": "dˈɛvˌɑps",
        "npm": "ˌɛn pˌi ˈɛm",
        "zsh": "zˌi ˌɛs ˈAʧ",
        "sudo": "sˈudˌu",
        "emacs": "ˈimˌæks",
    ]
}
