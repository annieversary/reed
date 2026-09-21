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

Requires macOS 15 or later and a Swift 6 toolchain. The same Xcode target supports iOS 17 or later; select your signing team before running on a physical iPhone. iOS simulator testing is intentionally deferred.

## What works

- Paste a URL, or press Command-N on Mac to save an article.
- Extract readable HTML using bundled Mozilla Readability, sanitize with DOMPurify, and download images.
- Read saved articles in a local WebKit reader with light/dark appearance and adjustable type.
- Search titles, authors, websites, and excerpts; favorite articles and mark them finished.
- Save reading position and restore it when reopening an article.
- Distinguish queued, downloading, saved, partially saved, and failed downloads.
- Retry failures, recover interrupted downloads on launch, and delete saved articles.
- Deduplicate normalized URLs without stripping meaningful query parameters.

The library starts empty. Test fixtures are kept separate from the user's library.

## Storage and architecture

`Sources/Reed` contains the shared SwiftUI interface and platform-specific WebKit wrappers. On Mac, an AppKit window hosts these screens and handles launch, reopening, and standard keyboard menus; iOS uses a SwiftUI app scene. `Sources/ReedCore` contains the SwiftData model, persistent queue, downloader, extractor, and file storage. Swift Package Manager exposes `ReedCore` for unit tests; the Xcode app compiles the same sources directly.

The Mac prototype stores its library in `~/Library/Application Support/Reed`:

```text
Library.store                   SwiftData metadata and download states
Articles/<id>/<version>/
  index.html                    Sanitized article and Reed's reader stylesheet
  image-0                       Downloaded image, referenced locally
Staging/                        Incomplete downloads, cleaned after restart
```

Article packages are assembled in staging and moved into place before metadata points to them. A failed replacement leaves the earlier package intact. Saved articles are durable files, not a browser cache. On iOS this directory is inside the app container.

The extractor runs bundled JavaScript against an inert DOM in a network-blocked WebKit shell. Publisher scripts are never loaded into a live page. The reader uses sanitized HTML, disabled page JavaScript, a restrictive content security policy, and local files only; following a link explicitly opens the system browser.

Downloads are sequential and bounded: 8 MiB of HTML, 12 MiB per image, up to 40 images and 64 MiB of image data per article. Image failures preserve the text and display a partial-save status. Supported images are raster formats; SVGs and remote embeds are excluded.

## Validation

```sh
swift test
python3 scripts/smoke_test.py
```

The integration script requires a built Debug Mac app. It starts a temporary local website, launches Reed with an isolated library, verifies extraction, sanitization, redirects, image downloads and failure handling, then stops the website and relaunches Reed to verify actual offline rendering of text and images. It writes JSON reports and a reader screenshot into a temporary directory. It does not launch a simulator or alter the normal library.

After adding source or resource files, run `python3 scripts/generate_project.py` to regenerate the checked-in Xcode project. There are no external Swift package dependencies or build-time network downloads.

## Prototype boundaries

- Keep the app open while saving. The queue is persistent, but this version does not implement iOS background transfers or a Share Extension.
- Public HTML articles are supported. Pages that require JavaScript rendering, login, or a paywall may fail extraction or only expose a preview; Reed does not bypass those restrictions.
- PDFs, video, audio, multi-page articles, accounts, cloud sync, tags, and full-text search are not implemented.
- The Mac development target is not sandboxed or notarized. App Store packaging, app icons, distribution signing, and iPhone interaction testing are follow-up work.
- HTTP URLs are allowed for user-selected article sources. The reader itself blocks remote loading.

## Third-party code

- Mozilla Readability **0.6.0**, Apache-2.0: `Sources/ReedCore/Resources/Readability.js` and `Readability-LICENSE.md`.
- DOMPurify **3.4.15**, Apache-2.0 OR MPL-2.0: `Sources/ReedCore/Resources/purify.min.js` and `DOMPurify-LICENSE`.

Both libraries and their licenses are bundled for reproducible offline operation.
