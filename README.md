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
- Share a link to Reed from Safari or any other app's share sheet.
- Extract readable HTML using bundled Mozilla Readability, sanitize with DOMPurify, and download images.
- Read saved articles in a local WebKit reader with light/dark appearance and adjustable type.
- Search titles, authors, websites, and excerpts; favorite articles and mark them finished.
- Save reading position and restore it when reopening an article.
- Listen to saved articles, read aloud on device by Kokoro (see below).
- Write notes beside each paragraph: swipe from right to left (or sideways on a trackpad) to slide the article over for a margin of notes. A note longer than its paragraph parts the article below it, so it stays beside what it's about.
- Distinguish queued, downloading, saved, partially saved, and failed downloads.
- Retry failures, recover interrupted downloads on launch, and delete saved articles.
- Deduplicate normalized URLs without stripping meaningful query parameters.

The library starts empty. Test fixtures are kept separate from the user's library.

## Sharing to Reed

The `ReedShare` extension (`Sources/ReedShare`) appears in the share sheet for a single web link. It doesn't download anything, since extensions are short-lived and memory-capped. It writes the link as a file into an inbox in the App Group container (`group.town.versary.reed` on iOS, `KR4TU3GTWZ.town.versary.reed` on macOS) and posts a Darwin notification. Reed adds inbox links to the library on launch, when it becomes active, and immediately on that notification if it's running. Downloads then proceed as usual, so a shared article is saved the next time Reed is open.

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
Articles/<id>/Audio/<version>/<voice>/
  0.m4a, 1.m4a, …               Narration, one file per passage
Staging/                        Incomplete downloads, cleaned after restart
```

Article packages are assembled in staging and moved into place before metadata points to them. A failed replacement leaves the earlier package intact. Saved articles are durable files, not a browser cache. On iOS this directory is inside the app container.

The extractor runs bundled JavaScript against an inert DOM in a network-blocked WebKit shell. When the served HTML holds almost no text, as with pages that assemble their article in the browser, `PageRenderer` loads the page once in a throwaway WebKit view (no stored data, no images, media, frames or new windows), lets its scripts run until the text settles, and extracts from the result the same way. Publisher scripts never run in the reader. The reader uses sanitized HTML, disabled page JavaScript, a restrictive content security policy, and local files only; following a link explicitly opens the system browser.

Downloads are sequential and bounded: 8 MiB of HTML, 12 MiB per image, up to 40 images and 64 MiB of image data per article. Image failures preserve the text and display a partial-save status. Images may be raster or SVG files, and drawings inlined in the page as SVG are kept too (without icons); remote embeds are excluded.

## Validation

```sh
swift test
python3 scripts/smoke_test.py
```

The integration script requires a built Debug Mac app. It starts a temporary local website, launches Reed with an isolated library, verifies extraction, sanitization, redirects, image downloads and failure handling, then stops the website and relaunches Reed to verify actual offline rendering of text and images. It writes JSON reports and a reader screenshot into a temporary directory. It does not launch a simulator or alter the normal library.

After adding source or resource files, run `python3 scripts/generate_project.py` to regenerate the checked-in Xcode project. FluidAudio is the only Swift package dependency, pinned to an exact version in both `Package.swift` and the generator.

## Prototype boundaries

- Keep the app open while saving. The queue is persistent, but this version does not implement iOS background transfers, so shared links wait until Reed is opened.
- Public HTML articles are supported. Pages that require JavaScript rendering, login, or a paywall may fail extraction or only expose a preview; Reed does not bypass those restrictions.
- PDFs, video, audio, multi-page articles, accounts, cloud sync, tags, and full-text search are not implemented.
- The Mac app is not sandboxed or notarized; only its share extension is sandboxed. App Store packaging, app icons, distribution signing, and iPhone interaction testing are follow-up work.
- HTTP URLs are allowed for user-selected article sources. The reader itself blocks remote loading.

## Third-party code

- Mozilla Readability **0.6.0**, Apache-2.0: `Sources/ReedCore/Resources/Readability.js` and `Readability-LICENSE.md`.
- DOMPurify **3.4.15**, Apache-2.0 OR MPL-2.0: `Sources/ReedCore/Resources/purify.min.js` and `DOMPurify-LICENSE`.
- Temml **0.13.5**, MIT, which converts TeX left for MathJax or KaTeX into MathML: `Sources/ReedCore/Resources/temml.min.js` and `Temml-LICENSE`.
- Speech Rule Engine **4.1.4**, Apache-2.0, which words formulas for narration: `Sources/ReedCore/Resources/SpeechRuleEngine.js`, its English rules `SpeechRuleEngine-en.json` and `SpeechRuleEngine-base.json`, and `SpeechRuleEngine-LICENSE`.

These libraries and their licenses are bundled for reproducible offline operation.

- FluidAudio **0.17.5**, Apache-2.0, as a Swift package. The Kokoro-82M weights (Apache-2.0) are downloaded at runtime.
