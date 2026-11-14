# reed

vibeslopped offline article reader, with a pretty decent on-device tts.

A native SwiftUI read-later app for Mac and iOS. Save articles, PDFs, EPUBs and YouTube transcripts as clean offline copies, then read or listen to them.

## Features

- Save from a pasted URL, the share sheet, or by opening a PDF/EPUB with Reed. Extraction uses Mozilla Readability and DOMPurify; JavaScript-built pages are rendered once in a throwaway web view.
- Offline reader with notes in the margin, reading position, full-text search, favorites and finished marks.
- Front pages for Hacker News, Lobste.rs, Substack and Wikipedia, plus RSS/Atom feeds, downloaded ahead and kept out of the library until saved. Comments from HN, Lobste.rs and Substack alongside articles.
- PDFs reflowed into paragraphs (figures, tables and equations cropped from the page); EPUBs on a shelf of their own, read a chapter at a time.
- On-device narration with [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) via [FluidAudio](https://github.com/FluidInference/FluidAudio). The model (~120 MB) downloads on first use, then works offline.
- Reading statistics, series, and undo for deletes.

## Build

Requires macOS 15+, Swift 6, and an Apple Development certificate for team `KR4TU3GTWZ` (the App Group needs it). iOS 17+.

```sh
make mac      # build and open the Mac app
make device   # build, install and launch on a paired iPhone (DEVICE="name" to pick one)
make          # list the other targets
```

The phone needs Developer Mode on. If launch fails with "profile has not been explicitly trusted", trust the developer under Settings → General → VPN & Device Management.

After adding source or resource files, regenerate the Xcode project with `make project` (or `python3 scripts/generate_project.py`).

## Test

```sh
make test     # unit tests
make smoke    # end-to-end offline check against the built Mac app
```

## Share extension

On macOS, enable it once under System Settings → General → Login Items & Extensions → Sharing, or:

```sh
pluginkit -e use -i town.versary.reed.share
```

## Layout

- `Sources/Reed` — SwiftUI interface and platform WebKit wrappers.
- `Sources/ReedCore` — SwiftData model, download queue, extraction, PDF/EPUB conversion, storage.
- `Sources/ReedShare` — share extension; drops links and files into an App Group inbox for Reed to pick up.

The library lives in `~/Library/Application Support/Reed` (the app container on iOS).

## Third-party code

Bundled in `Sources/ReedCore/Resources` with their licenses:

- Mozilla Readability 0.6.0 (Apache-2.0)
- DOMPurify 3.4.15 (Apache-2.0 / MPL-2.0)
- Temml 0.13.5 (MIT)
- Speech Rule Engine 4.1.4 (Apache-2.0)

FluidAudio 0.17.5 (Apache-2.0) is the only Swift package dependency. Kokoro-82M weights (Apache-2.0) are downloaded at runtime.
