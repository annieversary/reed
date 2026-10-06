import Foundation
import ImageIO
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Alt text for the pictures of a saved article or book that came without any, written by the on-device model,
/// so narration can say what each one shows.
enum ImageDescriptions {
    /// Pictures smaller than this on either side are taken for icons or spacers and left undescribed.
    static let smallestSide = 96

    /// Whether this device's model can describe pictures.
    static var available: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 27, iOS 27, *) else { return false }
        let model = SystemLanguageModel.default
        return model.isAvailable && model.capabilities.contains(.vision)
        #else
        return false
        #endif
    }

    /// The file names of the first `limit` pictures in `html` saved in `directory` with no alt text, in order,
    /// leaving out drawings, equations, and anything too small to be more than an icon.
    static func undescribed(in html: String, directory: URL, limit: Int) async -> [String] {
        var names: [String] = []
        let equations = #/<figure class="equation">.*?</figure\s*>/#.dotMatchesNewlines().ignoresCase()
        for tag in html.replacing(equations, with: "").matches(of: ArticleHTML.imageTag()) {
            guard let name = ArticleHTML.savedImage(String(tag.output)), ArticleHTML.alt(of: String(tag.output)).isEmpty,
                  !names.contains(name), !name.hasSuffix(".svg"),
                  let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  min(width, height) >= smallestSide else { continue }
            names.append(name)
            if names.count == limit { break }
        }
        return names
    }

    /// Descriptions `previous` gave the same pictures, by file name in `directory`, so refreshing doesn't describe them again.
    /// A picture is the same when its file is: names can move as an article changes.
    static func carried(_ names: [String], in directory: URL, from previous: (html: String, directory: URL)) async -> [String: String] {
        var earlier: [Data: String] = [:]
        for tag in previous.html.matches(of: ArticleHTML.imageTag()) {
            let alt = ArticleHTML.alt(of: String(tag.output))
            guard !alt.isEmpty, let name = ArticleHTML.savedImage(String(tag.output)),
                  let data = try? Data(contentsOf: previous.directory.appendingPathComponent(name)) else { continue }
            earlier[data] = ArticleText.plain(alt)
        }
        guard !earlier.isEmpty else { return [:] }
        var carried: [String: String] = [:]
        for name in names {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)), let alt = earlier[data] { carried[name] = alt }
        }
        return carried
    }

    /// `html` with `descriptions` as the alt text of each picture, by file name, that has none.
    static func applying(_ descriptions: [String: String], to html: String) async -> String {
        guard !descriptions.isEmpty else { return html }
        return html.replacing(ArticleHTML.imageTag()) { tag in
            let whole = String(tag.output)
            guard let name = ArticleHTML.savedImage(whole), let description = descriptions[name], ArticleHTML.alt(of: whole).isEmpty else { return whole }
            let attribute = " alt=\"\(ArticleHTML.escape(description))\""
            if let empty = whole.firstRange(of: #/\salt\s*=\s*"\s*"/#.ignoresCase()) { return whole.replacingCharacters(in: empty, with: attribute) }
            return "<img" + attribute + whole.dropFirst("<img".count)
        }
    }

    /// The model's description of the picture at `url`, from `source`, like `an article titled "…"`, or nil if it couldn't give one.
    static func describe(_ url: URL, from source: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 27, iOS 27, *) else { return nil }
        // A session each, so one picture's description doesn't colour the next.
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let prompt = "This picture is from \(source). Write its alt text."
        guard let response = try? await session.respond(options: GenerationOptions(temperature: 0.2), prompt: {
            prompt
            Attachment(imageURL: url)
        }) else { return nil }
        let description = response.content.trimmingCharacters(in: .whitespacesAndNewlines.union(["\""]))
        return description.contains(where: \.isLetter) ? description : nil
        #else
        return nil
        #endif
    }

    private static let instructions = """
        You write alt text for pictures in articles and books, for someone listening to the article read aloud. \
        Say what the picture shows in one plain sentence of at most 25 words. If it's a chart or diagram, say what it shows \
        and its main takeaway. Include any short text in the picture that matters. \
        Don't begin with "An image of" or "A picture of", and don't guess at things you can't see.
        """
}
