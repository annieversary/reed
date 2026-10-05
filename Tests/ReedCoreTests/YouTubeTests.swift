import Foundation
import Testing
@testable import ReedCore

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/" + name, withExtension: "json")!)
}

@Test func videoLinksSaveAsTheirWatchPage() throws {
    let watch = "https://www.youtube.com/watch?v=aircAruvnKk"
    for link in ["youtu.be/aircAruvnKk?t=30", "https://m.youtube.com/watch?v=aircAruvnKk&list=PLZ", "youtube.com/shorts/aircAruvnKk",
                 "https://www.youtube.com/live/aircAruvnKk", "https://www.youtube-nocookie.com/embed/aircAruvnKk", "music.youtube.com/watch?v=aircAruvnKk"] {
        #expect(try ArticleURL.parse(link).absoluteString == watch)
    }
    for link in ["https://www.youtube.com/@3blue1brown", "https://www.youtube.com/watch?v=short", "https://notyoutube.com/watch?v=aircAruvnKk"] {
        #expect(YouTube.videoID(in: try ArticleURL.parse(link)) == nil)
    }
}

@Test func captionsWrittenByPeopleAreChosenInTheReadersLanguage() {
    let tracks = [YouTube.Track(baseUrl: "a-en", languageCode: "en", kind: "asr"), YouTube.Track(baseUrl: "de", languageCode: "de", kind: nil),
                  YouTube.Track(baseUrl: "en", languageCode: "en-GB", kind: nil), YouTube.Track(baseUrl: "a-fr", languageCode: "fr", kind: "asr")]
    #expect(YouTube.track(among: tracks, languages: ["en"])?.baseUrl == "en")
    #expect(YouTube.track(among: tracks, languages: ["fr", "en"])?.baseUrl == "a-fr")
    #expect(YouTube.track(among: tracks, languages: ["ja"])?.baseUrl == "de")
    #expect(YouTube.track(among: [], languages: ["en"]) == nil)
}

@Test func playerResponsesGiveTheVideoOrWhyNot() throws {
    let video = try YouTube.video(from: Data("""
        {"playabilityStatus":{"status":"OK"},"videoDetails":{"title":"Me at the zoo","author":"jawed","shortDescription":"",
         "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/big.webp","width":640},{"url":"https://i.ytimg.com/small.jpg","width":120}]}},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?v=x","languageCode":"en"}]}}}
        """.utf8))
    #expect(video.title == "Me at the zoo" && video.author == "jawed" && video.thumbnail == "https://i.ytimg.com/big.webp" && video.tracks.count == 1)
    #expect(throws: (any Error).self) {
        try YouTube.video(from: Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm your age"}}"#.utf8))
    }
}

@Test func captionsBecomeWords() throws {
    let manual = try YouTube.words(from: fixture("youtube-captions"))
    #expect(manual.prefix(5).map(\.text) == ["This", "is", "a", "3.", "It's"])
    #expect(manual[4].start == 6060)
    let automatic = try YouTube.words(from: fixture("youtube-captions-asr"))
    #expect(automatic.first?.text == "This" && !automatic.contains { $0.text.contains("Music") })
    #expect(automatic.prefix(4).map(\.start) == [4400, 4799, 4960, 5200])
    // A word split across segments is put back together.
    let split = try YouTube.words(from: Data(#"{"events":[{"tStartMs":0,"segs":[{"utf8":"super"},{"utf8":"cali","tOffsetMs":5},{"utf8":" fragile"}]},{"tStartMs":9,"segs":[{"utf8":">> next"}]}]}"#.utf8))
    #expect(split.map(\.text) == ["supercali", "fragile", ">>", "next"])
}

@Test func descriptionsListChapters() {
    let description = "Intro text.\n0:00 - Introduction example\n1:07 Series preview\n1:02:42: Late\nNot a chapter 3:00"
    #expect(YouTube.chapters(in: description) == [.init(start: 0, title: "Introduction example"), .init(start: 67_000, title: "Series preview"),
                                                   .init(start: 3_762_000, title: "Late")])
    // Not chapters unless the first starts the video.
    #expect(YouTube.chapters(in: "0:30 First\n1:00 Second").isEmpty)
    #expect(YouTube.excerpt(of: "What are neurons?\nHelp fund future projects: https://patreon.com/x\nAnd layers?\n\nMore") == "What are neurons? And layers?")
}

@Test func transcriptsReadAsParagraphsUnderChapters() throws {
    let words = try YouTube.words(from: fixture("youtube-captions"))
    let chapters = [YouTube.Chapter(start: 0, title: "Introduction & example"), YouTube.Chapter(start: 67_000, title: "Series preview")]
    let html = YouTube.html(id: "aircAruvnKk", words: words, chapters: chapters, thumbnail: "thumbnail.webp")
    #expect(html.hasPrefix(#"<figure><img src="thumbnail.webp" alt=""></figure>"#))
    #expect(html.contains(#"<h2><a href="https://www.youtube.com/watch?v=aircAruvnKk&amp;t=67s">Series preview</a></h2>"#))
    #expect(html.contains("Introduction &amp; example"))
    let passages = ArticleSpeech.passages(title: "Neural networks", html: "<main>\(html)</main>")
    #expect(passages.count > 4)
    #expect(passages.dropFirst().allSatisfy { $0.split(separator: " ").count <= 160 })
    // Long captions without punctuation still break.
    let unpunctuated = (0..<400).map { YouTube.Word(text: "word", start: $0 * 300) }
    #expect(YouTube.html(id: "x", words: unpunctuated, chapters: [], thumbnail: nil).components(separatedBy: "<p>").count == 4)
}
