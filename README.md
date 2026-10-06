# Reed

A native SwiftUI read-later prototype for Mac and iOS. Paste an article URL, save a clean copy with images, and read it without an internet connection.

## Run on this Mac

Open `Reed.xcodeproj`, choose the **Reed** scheme and **My Mac**, then Run. No simulator is needed.

Or build and open from the terminal:

```sh
xcodebuild -project Reed.xcodeproj -scheme Reed -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/Reed.app
```

Requires macOS 15 or later, a Swift 6 toolchain, and an Apple Development certificate for team `KR4TU3GTWZ` in the keychain (the App Group needs team signing; no provisioning profile or network is involved). The same Xcode target supports iOS 17 or later. iOS simulator testing is intentionally deferred.

## Run on an iPhone

```sh
make device                  # the only paired phone
make device DEVICE="dahlia"  # by name, when more than one is around
```

Builds for `generic/platform=iOS`, then installs and launches over `devicectl`. The signing team is set in `scripts/generate_project.py`, so Xcode needn't be open, but the phone must be unlocked, paired with this Mac, and have Developer Mode on (Settings → Privacy & Security). If the launch fails with "profile has not been explicitly trusted", trust the developer under Settings → General → VPN & Device Management, then run `make device` again. `make` lists the other targets.

## What works

- Paste a URL, or press Command-N on Mac to save an article.
- Share a link to Reed from Safari or any other app's share sheet, or a PDF from Files, Mail or anywhere else that shares documents.
- Extract readable HTML using bundled Mozilla Readability, sanitize with DOMPurify, and download images.
- Read saved articles in a local WebKit reader with light/dark appearance and adjustable type.
- Search the full text of saved articles as well as their titles, authors and websites; favorite articles and mark them finished.
- Unread articles are listed oldest first. Articles grey out the further they've been read, in the library, on front pages and in feeds, and each one ends with a card for the next in the list.
- Browse the front pages of Hacker News, Lobste.rs and Substack (the For You feed, once signed in), and subscribe to RSS and Atom feeds. Their stories are downloaded ahead to read offline, and kept outside the library until saved.
- Read the comments on Hacker News, Lobste.rs and Substack beside an article, from its More menu. They're kept to read offline, and other sites are only asked whether they discuss an article when you ask.
- Find a serial's other chapters and save them as a series, read in order.
- Save YouTube videos as their transcripts, in paragraphs under their chapters.
- Pages that assemble their article with JavaScript are rendered once in a throwaway web view, then extracted like any other.
- Save reading position and restore it when reopening an article.
- Listen to saved articles, read aloud on device by Kokoro (see below). Pictures standing on their own are read by their alt text; on macOS 27 or iOS 27, the on-device model describes those that come without any.
- Write notes beside each paragraph: swipe from right to left (or sideways on a trackpad) to slide the article over for a margin of notes. A note longer than its paragraph parts the article below it, so it stays beside what it's about.
- Distinguish queued, downloading, saved, partially saved, and failed downloads.
- Retry failures, recover interrupted downloads on launch, and delete saved articles.
- Deduplicate normalized URLs without stripping meaningful query parameters.
- Save PDFs as articles, reflowed into paragraphs with their headings, captions and code, and their figures, tables and displayed equations cropped from the page (macOS 26 or iOS 26). arXiv papers without an HTML rendering are read from their PDF.
- Add EPUB books to a shelf of their own, from the shelf's add button, by dropping them on it, from the share sheet, or by opening them with Reed from Finder or Files. A book is read a chapter at a time, with the same reader, notes and narration as an article; each chapter ends with a card for the next, and listening carries on into it. Books are favorited whole; chapters are marked finished one by one, and the shelf shows how far through each book you are. Books locked to a store's app can't be read.

The library starts empty. Test fixtures are kept separate from the user's library.

## Sharing to Reed

The `ReedShare` extension (`Sources/ReedShare`) appears in the share sheet for a web link, a PDF or an EPUB. It doesn't download anything, since extensions are short-lived and memory-capped. It writes the link as a file into an inbox in the App Group container (`group.town.versary.reed` on iOS, `KR4TU3GTWZ.town.versary.reed` on macOS) and posts a Darwin notification; a shared PDF or EPUB is copied into the inbox under its own name. Reed adds inbox links, PDFs and EPUBs to the library on launch, when it becomes active, and immediately on that notification if it's running. Downloads then proceed as usual, so a shared article is saved the next time Reed is open. Reed keeps its own copy of a shared PDF beside the article, `Shared.pdf`, to read it again on a retry or refresh, and knows it by its contents, so sharing the same file twice saves it once. A PDF open in Safari is shared as its link instead.

On macOS, enable the extension once under System Settings → General → Login Items & Extensions → Sharing (or `pluginkit -e use -i town.versary.reed.share`). On iOS it shows in the share sheet's app row, or under More.

## Listening

The headphones button in the reader reads the article aloud with [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), run on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio). The first time, FluidAudio downloads the model (about 120 MB) from Hugging Face into Application Support (`~/.cache/fluidaudio` on macOS); after that, narration works offline.

`ArticleSpeech` splits the saved article into passages: the title, then one per paragraph, heading or list item, leaving out code, tables and figures. `Narrator` synthesizes them in order, ahead of playback, and queues each on an `AVAudioPlayerNode` as soon as it's ready, so listening starts after the first paragraph. Each passage is cached as AAC beside the article, so replaying or skipping back is instant. The reader tints the paragraph being read and scrolls to keep it in view. Scrolling away stops that and shows an arrow back to it; tapping a paragraph reads from there. Listening starts at the paragraph on screen, or where it last stopped, and finishing marks the article read. Speed runs from 0.8× to 2× without re-synthesizing. The controls stay at the bottom of the window anywhere in the library. Playback continues in the background and from the lock screen, which shows the article's first image (or Reed's artwork), the time through the article, and a scrubber. The track buttons skip by paragraph, and going back first restarts the paragraph. On iOS, synthesis avoids the GPU (FluidAudio's `aneTailCpu` routing), since iOS ends apps that use it in the background.

FluidAudio documents an intermittent Core ML crash in Kokoro on iOS 26.6 and 27 during long sessions ([#889](https://github.com/FluidInference/FluidAudio/issues/889)). Cached passages survive it; reopen the article and press play to carry on.
## Storage and architecture

`Sources/Reed` contains the shared SwiftUI interface and platform-specific WebKit wrappers. On Mac, an AppKit window hosts these screens and handles launch, reopening, and standard keyboard menus; iOS uses a SwiftUI app scene. `Sources/ReedCore` contains the SwiftData model, persistent queue, downloader, extractor, and file storage. Swift Package Manager exposes `ReedCore` for unit tests; the Xcode app compiles the same sources directly.

The Mac prototype stores its library in `~/Library/Application Support/Reed`:

```text
Library.store                   SwiftData metadata and download states
Articles/<id>/<version>/
  index.html                    Sanitized article and Reed's reader stylesheet
  image-0                       Downloaded image, referenced locally
Articles/<id>/Notes.json        Notes, each anchored to its paragraph's opening text
Articles/<id>/Shared.pdf        A PDF shared as a file, kept to read it again
Articles/<id>/Discussions/<site>.json
                                Comments last fetched from each site
Articles/<id>/Audio/<version>/<voice>/
  0.m4a, 1.m4a, …               Narration, one file per passage
Books/<id>/Book.epub            The EPUB a book was added from, kept to convert it again
Books/<id>/<version>/
  0.html, 1.html, …             One reader document per chapter
  book-OEBPS_Images_cover.jpg   Images, shared by the chapters, named after their place in the EPUB
Books/<id>/Notes/<chapter>.json
Books/<id>/Audio/<version>/<voice>/<chapter>/
Feeds.json                      Subscribed feeds and their latest entries
Series.json                     Series and their parts, in reading order
FrontPages/<source>.json        The front page last fetched from each source
Search.sqlite                   Full-text index, rebuilt from the articles if damaged
Staging/                        Incomplete downloads, cleaned after restart
```

A `Feeds.json` or `Series.json` that can't be read is moved aside to `<name>.unreadable` rather than overwritten.

Article packages are assembled in staging and moved into place before metadata points to them. A failed replacement leaves the earlier package intact. Saved articles are durable files, not a browser cache. On iOS this directory is inside the app container.

The extractor runs bundled JavaScript against an inert DOM in a network-blocked WebKit shell. When the served HTML holds almost no text, as with pages that assemble their article in the browser, `PageRenderer` loads the page once in a throwaway WebKit view (no stored data, no images, media, frames or new windows), lets its scripts run until the text settles, and extracts from the result the same way. Publisher scripts never run in the reader. The reader uses sanitized HTML, disabled page JavaScript, a restrictive content security policy, and local files only; following a link explicitly opens the system browser.

Articles and book chapters are both `Readable`: the reader, narration, notes and reading position work on either, and `ReadableLocation` says where each one's files are.

`EPUB` reads a book's package file for its title, author, cover and reading order, and its table of contents (EPUB 3 navigation, or an EPUB 2 NCX) for its chapters. A chapter may run across several files, or share a file with others, as Project Gutenberg's do, and is then cut out of it at the element its entry points to; entries nested under one for the same file are sections, not chapters. Pages before the first entry are kept only if they have something to read, so a cover page isn't a chapter. Each chapter goes through the extraction script without Readability, since it's already only the text: it's sanitized the same way, its images are copied out of the book, links to other chapters point at their saved files, and a heading repeating the chapter's title is dropped, keeping any illustration in it. A book is converted whole into one version and committed at once, so it's never half there. `ZipArchive` reads the EPUB itself, which needs only stored and deflated files.

`PDFArticle` turns a PDF into the same kind of article. PDFKit's text layer gives the exact words, line by line, with their fonts; Vision's `RecognizeDocumentsRequest` gives the reading order, so two-column papers read down one column and then the next. Lines become paragraphs by their spacing, indents and short last lines, and become headings, captions, code or running heads by their size, weight and wording. What doesn't reflow (drawings, charts, tables and displayed equations) is cropped from the page at four times its size: drawings are found as ink between the text, and a caption claims the cells or labels beside it. Scanned pages are read with Vision's own text recognition.

Downloads are sequential and bounded: 8 MiB of HTML, 12 MiB per image, up to 40 images and 64 MiB of image data per article, and 64 MiB per PDF. Image failures preserve the text and display a partial-save status. Images may be raster or SVG files, and drawings inlined in the page as SVG are kept too (without icons); remote embeds are excluded.

## Validation

```sh
swift test
python3 scripts/smoke_test.py
```

The integration script requires a built Debug Mac app. It starts a temporary local website, launches Reed with an isolated library, verifies extraction, sanitization, redirects, image downloads, failure handling and converting an EPUB, then stops the website and relaunches Reed to verify actual offline rendering of text and images. It writes JSON reports and screenshots of the reader, the library, a book and one of its chapters into a temporary directory. It does not launch a simulator or alter the normal library.

After adding source or resource files, run `python3 scripts/generate_project.py` to regenerate the checked-in Xcode project. FluidAudio is the only Swift package dependency, pinned to an exact version in both `Package.swift` and the generator.

## Prototype boundaries

- Keep the app open while saving. The queue is persistent, but this version does not implement iOS background transfers, so shared links wait until Reed is opened.
- Public HTML articles are supported. Pages that require a login or a paywall may fail extraction or only expose a preview; Reed does not bypass those restrictions.
- Video beyond YouTube transcripts, audio, articles split across pages, accounts (other than signing in to Substack), cloud sync, and tags are not implemented.
- The Mac app is not sandboxed or notarized; only its share extension is sandboxed. App Store packaging, distribution signing, and iPhone interaction testing are follow-up work.
- HTTP URLs are allowed for user-selected article sources. The reader itself blocks remote loading.

## Third-party code

- Mozilla Readability **0.6.0**, Apache-2.0: `Sources/ReedCore/Resources/Readability.js` and `Readability-LICENSE.md`.
- DOMPurify **3.4.15**, Apache-2.0 OR MPL-2.0: `Sources/ReedCore/Resources/purify.min.js` and `DOMPurify-LICENSE`.
- Temml **0.13.5**, MIT, which converts TeX left for MathJax or KaTeX into MathML: `Sources/ReedCore/Resources/temml.min.js` and `Temml-LICENSE`.
- Speech Rule Engine **4.1.4**, Apache-2.0, which words formulas for narration: `Sources/ReedCore/Resources/SpeechRuleEngine.js`, its English rules `SpeechRuleEngine-en.json` and `SpeechRuleEngine-base.json`, and `SpeechRuleEngine-LICENSE`.

These libraries and their licenses are bundled for reproducible offline operation.

- FluidAudio **0.17.5**, Apache-2.0, as a Swift package. The Kokoro-82M weights (Apache-2.0) are downloaded at runtime.
