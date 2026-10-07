import AVFoundation
import FluidAudio
import MediaPlayer
import Observation
import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// Reads saved articles and book chapters aloud with Kokoro, synthesized on device.
///
/// Each passage is synthesized once, a sentence at a time so the one being heard can be followed, cached as
/// a small audio file beside the article, and queued for gapless playback as soon as it's ready. Synthesis runs ahead of playback to the end of the article,
/// so replaying or skipping back never waits.
@MainActor @Observable
final class Narrator {
    private(set) var readableID: UUID?
    private(set) var title = ""
    /// What's being read is from, such as its website or book.
    private(set) var source = ""
    /// The book, when a chapter is being read, whose title alone may say little, like "III".
    private(set) var book: String?
    private(set) var passageCount = 0
    /// The passage being heard, or waited for.
    private(set) var current = 0
    /// The sentence being heard, within the current passage.
    private(set) var sentence = 0
    /// The last passage queued on the player.
    private(set) var scheduled = -1
    private(set) var isPlaying = false
    private(set) var isLoadingVoice = false
    /// Why synthesis stopped. Passages already made keep playing.
    private(set) var errorMessage: String?
    /// Playback speed. Speech is stretched without changing pitch, so cached passages are reused at any speed.
    var rate: Float = UserDefaults.standard.object(forKey: "narrationRate") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(rate, forKey: "narrationRate")
            timePitch.rate = rate
            updateNowPlaying()
        }
    }
    static let rates: [Float] = [0.8, 1, 1.2, 1.4, 1.6, 1.8, 2]
    /// The Kokoro voice reading. Each voice keeps its own cached audio, so switching back is instant.
    var voice: String = UserDefaults.standard.string(forKey: "narrationVoice").flatMap { Voice($0) }?.id
        ?? KokoroAneConstants.defaultVoice {
        didSet {
            guard voice != oldValue else { return }
            UserDefaults.standard.set(voice, forKey: "narrationVoice")
            guard let item, let library, let version = item.contentVersion else { return }
            directory = library.storage.audioDirectory(item.location, version: version, voice: voice)
            durations = [:]
            sentenceStarts = [:]
            measure()
            heard = 0
            if isPlaying {
                start(at: current)
            } else {
                // The old voice's queued audio goes; the new one is made and queued on resuming.
                epoch += 1
                player.stop()
                generator?.cancel()
                generator = nil
                needsStart = true
            }
        }
    }

    /// The voice whose sample is being prepared or played.
    private(set) var previewVoice: String?
    private(set) var isPreviewPlaying = false
    private(set) var previewError: String?

    /// Playback has reached a passage that isn't synthesized yet.
    var isWaiting: Bool { readableID != nil && scheduled < current && errorMessage == nil }

    @ObservationIgnored private var passages: [String] = []
    @ObservationIgnored private var sentences: [[String]] = []
    /// Names each passage's audio by what it says, so audio made before the passages were split differently isn't reused.
    @ObservationIgnored private var keys: [String] = []
    @ObservationIgnored private var item: (any Readable)?
    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var kokoro: KokoroAneManager?
    @ObservationIgnored private var loadingKokoro: Task<KokoroAneManager, any Error>?
    @ObservationIgnored private var generator: Task<Void, Never>?
    /// Reads the next passage's audio to queue it.
    @ObservationIgnored private var loader: Task<Void, Never>?
    /// More passages may be ready to queue once the loader finishes.
    @ObservationIgnored private var needsScheduling = false
    @ObservationIgnored let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    /// Bumped whenever the player is flushed, so callbacks from discarded buffers are ignored.
    @ObservationIgnored private var epoch = 0
    /// Where each queued passage starts on the player's timeline, which restarts whenever the player is flushed.
    @ObservationIgnored private var startFrames: [Int: AVAudioFramePosition] = [:]
    @ObservationIgnored private var nextFrame: AVAudioFramePosition = 0
    /// How far into the current passage playback began, after seeking.
    @ObservationIgnored private var startOffset: AVAudioFramePosition = 0
    /// How far into the current passage was last heard. The player's clock is lost when the engine stops.
    @ObservationIgnored var heard: Double = 0
    /// Nothing is queued for the current passage, so resuming must start it afresh.
    @ObservationIgnored private var needsStart = false
    /// An interruption paused playback, so it may carry on once the interruption ends.
    @ObservationIgnored var interruptedWhilePlaying = false
    /// Lengths of synthesized passages, in seconds.
    @ObservationIgnored private var durations: [Int: Double] = [:]
    /// Estimated lengths of every passage, from its words, until it's synthesized.
    @ObservationIgnored private var estimates: [Double] = []
    /// When each sentence of a synthesized passage begins, in seconds into it.
    @ObservationIgnored private var sentenceStarts: [Int: [Double]] = [:]
    /// Keeps `sentence` in step with playback.
    @ObservationIgnored private var tracker: Task<Void, Never>?
    @ObservationIgnored var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var previewPlayer: AVAudioPlayer?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    private static let sample = "This is how articles will sound when Reed reads them aloud."
    private static let lookahead = 3
    /// The shorter beat between sentences of a passage.
    private static let sentencePause = 0.15
    /// Kokoro reads at roughly this pace, to estimate passages not synthesized yet.
    private static let wordsPerSecond = 2.8
    /// "Previous" restarts the passage rather than going back once it's this far in.
    private static let restartThreshold = 3.0
    #if os(iOS)
    /// iOS aborts apps that use the GPU in the background, so synthesis stays on the Neural Engine and CPU,
    /// letting it continue while the phone is locked.
    private static let computeUnits = KokoroAneComputeUnits.aneTailCpu
    #else
    private static let computeUnits = KokoroAneComputeUnits.default
    #endif

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: PassageAudio.format)
        timePitch.rate = rate
        observeAudioChanges()
        installRemoteCommands()
    }

    /// Reads `item` from `passage`, or from where it was last left off.
    func play(_ item: any Readable, from passage: Int? = nil, in library: Library) {
        if item.id == readableID {
            if let passage, passage != current { start(at: min(max(passage, 0), passageCount - 1)) } else { resume() }
            return
        }
        Task {
            guard let version = item.contentVersion, let speech = await library.speech(for: item), !speech.passages.isEmpty else {
                library.errorMessage = ReedError.damagedArticle.localizedDescription
                return
            }
            let artwork = Self.artwork(from: await library.leadImage(for: item))
            reset()
            self.item = item
            self.library = library
            readableID = item.id
            title = item.title
            source = item.source
            book = item is BookChapter ? item.source : nil
            passages = speech.passages
            sentences = speech.sentences
            keys = speech.sentences.map(PassageAudio.key(for:))
            estimates = passages.map { Double($0.split(whereSeparator: \.isWhitespace).count) / Self.wordsPerSecond + PassageAudio.pause }
            passageCount = passages.count
            directory = library.storage.audioDirectory(item.location, version: version, voice: voice)
            self.artwork = artwork
            measure()
            let resumed = item.narrationPassage.map { ArticleNotes.passage(near: $0, anchor: item.narrationAnchor, in: passages) }
            start(at: min(max(passage ?? resumed ?? 0, 0), passages.count - 1))
        }
    }

    func pause() {
        guard isPlaying else { return }
        noteHeard()
        player.pause()
        isPlaying = false
        stopTracking()
        updateNowPlaying()
    }

    func resume() {
        guard readableID != nil, !isPlaying else { return }
        if engine.isRunning, !needsStart {
            isPlaying = true
            player.play()
            track()
            updateNowPlaying()
        } else {
            start(at: current, offset: heard)
        }
        if generator == nil { generate(from: current) }
    }

    func togglePlayback() { isPlaying ? pause() : resume() }

    func skip(by offset: Int) {
        guard readableID != nil else { return }
        start(at: min(max(current + offset, 0), passageCount - 1))
    }

    /// Back to the start of the passage, or to the one before if it has only just begun.
    func previous() {
        guard readableID != nil else { return }
        if elapsedInPassage > Self.restartThreshold || current == 0 { start(at: current) } else { skip(by: -1) }
    }

    /// Jumps to a point in the whole article, as when scrubbing on the lock screen.
    func seek(to time: Double) {
        guard readableID != nil else { return }
        var remaining = max(time, 0)
        for index in 0..<passageCount {
            let length = duration(of: index)
            if remaining < length || index == passageCount - 1 {
                start(at: index, offset: min(remaining, length))
                return
            }
            remaining -= length
        }
    }

    /// Picks synthesis up again after it stopped, from the passage being heard.
    func retry() {
        guard readableID != nil else { return }
        errorMessage = nil
        if generator == nil { generate(from: current) }
    }

    func stop() {
        reset()
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        updateNowPlaying()
    }

    /// Lets go of what's being read, leaving the engine and audio session as they are for whatever's read next.
    private func reset() {
        epoch += 1
        generator?.cancel()
        generator = nil
        player.stop()
        stopTracking()
        readableID = nil
        passages = []
        sentences = []
        keys = []
        passageCount = 0
        current = 0
        sentence = 0
        scheduled = -1
        isPlaying = false
        errorMessage = nil
        directory = nil
        item = nil
        library = nil
        artwork = nil
        durations = [:]
        estimates = []
        sentenceStarts = [:]
        startFrames = [:]
    }

    /// Plays a short sample in `voice`, pausing narration. Samples are kept in the caches, so each is only made once.
    func preview(_ voice: String) {
        stopPreview()
        pause()
        previewVoice = voice
        previewError = nil
        previewTask = Task { [weak self] in
            do {
                let directory = URL.cachesDirectory.appendingPathComponent("VoiceSamples", isDirectory: true)
                let url = directory.appendingPathComponent("\(voice).m4a")
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard let kokoro = try await self?.loadKokoro() else { return }
                    let samples = try await kokoro.synthesizeDetailed(text: Self.sample, voice: voice).samples
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try await PassageAudio.write(samples, to: url)
                }
                try Task.checkCancellation()
                guard let self else { return }
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
                try session.setActive(true)
                #endif
                let player = try AVAudioPlayer(contentsOf: url)
                previewPlayer = player
                player.play()
                isPreviewPlaying = true
                try await Task.sleep(for: .seconds(player.duration))
                stopPreview()
            } catch where !Task.isCancelled {
                self?.stopPreview()
                self?.previewError = "Couldn't play a sample: \(error.localizedDescription)"
            } catch {}
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        #if os(iOS)
        // Other apps' audio the sample paused may carry on, unless narration holds the session.
        if previewPlayer != nil, readableID == nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        previewPlayer?.stop()
        previewPlayer = nil
        previewVoice = nil
        isPreviewPlaying = false
    }

    func start(at index: Int, offset: Double = 0) {
        epoch += 1
        player.stop()
        current = index
        scheduled = index - 1
        startFrames = [:]
        nextFrame = 0
        startOffset = AVAudioFramePosition(offset * PassageAudio.sampleRate)
        heard = offset
        needsStart = false
        sentence = sentenceIndex(at: offset)
        rememberPosition()
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
            #endif
            connectEngine()
            if !engine.isRunning { try engine.start() }
        } catch {
            errorMessage = error.localizedDescription
            isPlaying = false
            return
        }
        player.play()
        isPlaying = true
        track()
        scheduleReady()
        generate(from: index)
        updateNowPlaying()
    }

    /// Connected to the output only once narration starts, since bringing up the engine's output pauses other apps' audio.
    private func connectEngine() {
        guard engine.outputConnectionPoints(for: timePitch, outputBus: 0).isEmpty else { return }
        engine.connect(timePitch, to: engine.mainMixerNode, format: PassageAudio.format)
    }

    /// Queues synthesized passages until the player holds a few ahead of the one being heard.
    /// Each is read from its file away from the main thread, one at a time, in order.
    private func scheduleReady() {
        guard loader == nil else { needsScheduling = true; return }
        needsScheduling = false
        guard let directory, scheduled + 1 < passageCount, scheduled + 1 < current + Self.lookahead else { return }
        let index = scheduled + 1, epoch = epoch, url = PassageAudio.audioURL(keys[index], in: directory)
        loader = Task { [weak self] in
            let buffer = await PassageAudio.buffer(at: url)
            guard let self else { return }
            loader = nil
            if epoch != self.epoch || index != scheduled + 1 {
                needsScheduling = true
            } else if let buffer {
                enqueue(buffer, at: index)
                needsScheduling = true
            }
            if needsScheduling { scheduleReady() }
        }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, at index: Int) {
        var buffer = buffer
        scheduled = index
        let epoch = epoch
        durations[index] = Double(buffer.frameLength) / PassageAudio.sampleRate
        var skipped: AVAudioFramePosition = 0
        if index == current, startOffset > 0, let rest = PassageAudio.slice(buffer, from: AVAudioFrameCount(startOffset)) {
            buffer = rest
            skipped = startOffset
        }
        // The passage being waited for plays as soon as it's queued, wherever the player's clock has got to.
        let begins = index == current ? max(nextFrame, playerFrame ?? 0) : nextFrame
        startFrames[index] = begins - skipped
        nextFrame = begins + AVAudioFramePosition(buffer.frameLength)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(index, epoch: epoch) }
        }
        if index == current { updateNowPlaying() }
    }

    private var playerFrame: AVAudioFramePosition? {
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return time.sampleTime
    }

    var elapsedInPassage: Double {
        guard let begins = startFrames[current], let now = playerFrame else { return Double(startOffset) / PassageAudio.sampleRate }
        return max(0, Double(now - begins) / PassageAudio.sampleRate)
    }

    /// Exact once a passage is synthesized and measured, estimated from its words until then.
    func duration(of index: Int) -> Double {
        durations[index] ?? estimates[index]
    }

    /// Measures the passages already synthesized, away from the main thread.
    private func measure() {
        guard let directory else { return }
        let urls = keys.map { PassageAudio.audioURL($0, in: directory) }
        Task { [weak self] in
            let lengths = await PassageAudio.lengths(of: urls)
            guard let self, self.directory == directory else { return }
            durations.merge(lengths) { known, _ in known }
            updateNowPlaying()
        }
    }

    /// The sentence of the current passage playing `time` seconds into it.
    private func sentenceIndex(at time: Double) -> Int {
        starts(of: current).lastIndex { $0 <= time } ?? 0
    }

    /// Read from beside the passage's audio, or estimated from sentence lengths for audio made before it was recorded.
    private func starts(of index: Int) -> [Double] {
        if let known = sentenceStarts[index] { return known }
        let parts = sentences.indices.contains(index) ? sentences[index] : []
        guard parts.count > 1 else { return [0] }
        if let directory, let data = try? Data(contentsOf: PassageAudio.sentencesURL(keys[index], in: directory)),
           let starts = try? JSONDecoder().decode([Double].self, from: data), starts.count == parts.count {
            sentenceStarts[index] = starts
            return starts
        }
        guard durations[index] != nil || (directory.map { FileManager.default.fileExists(atPath: PassageAudio.audioURL(keys[index], in: $0).path) } ?? false)
        else { return [0] }
        let lengths = parts.map { Double($0.count) }
        let spoken = max(duration(of: index) - PassageAudio.pause, 0)
        var starts: [Double] = [], total = 0.0
        for length in lengths {
            starts.append(total * spoken / lengths.reduce(0, +))
            total += length
        }
        sentenceStarts[index] = starts
        return starts
    }

    private func track() {
        guard tracker == nil else { return }
        tracker = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    noteHeard()
                    let reached = sentenceIndex(at: elapsedInPassage)
                    if reached != sentence { sentence = reached }
                } else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func noteHeard() {
        if playerFrame != nil { heard = elapsedInPassage }
    }

    /// Counts the passage just heard as listened to, by its share of the words.
    private func creditListening(through index: Int) {
        guard let item, let library else { return }
        let words = passages.map { Double($0.split(whereSeparator: \.isWhitespace).count) }
        let total = words.reduce(0, +)
        guard total > 0 else { return }
        library.creditListening(item, through: words[...index].reduce(0, +) / total, share: words[index] / total)
    }

    private func stopTracking() {
        tracker?.cancel()
        tracker = nil
    }

    private func finished(_ index: Int, epoch: Int) {
        guard epoch == self.epoch, index == current else { return }
        creditListening(through: index)
        guard current + 1 < passageCount else {
            guard let item, let library else { stop(); return }
            item.narrationPassage = nil
            item.narrationAnchor = nil
            library.updateProgress(item, value: 1, listening: true)
            // A book carries on into its next chapter, keeping the audio session so it can while the phone is locked.
            if let next = library.next(after: item) {
                isPlaying = false
                stopTracking()
                play(next, from: 0, in: library)
            } else {
                stop()
            }
            return
        }
        current += 1
        sentence = 0
        startOffset = 0
        rememberPosition()
        scheduleReady()
        updateNowPlaying()
    }

    /// Kept on what's being read, so listening resumes there next time, even after relaunching.
    private func rememberPosition() {
        guard let item, let library else { return }
        item.narrationPassage = current
        item.narrationAnchor = ArticleNotes.anchor(for: passages[current])
        library.save()
    }

    private func generate(from start: Int) {
        // The one it replaces finishes the sentence it's on first, so the two never make the same passage.
        let replaced = generator
        replaced?.cancel()
        guard let directory else { return }
        let sentences = sentences, keys = keys, voice = voice
        errorMessage = nil
        generator = Task { [weak self] in
            await replaced?.value
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for index in start..<sentences.count {
                    let url = PassageAudio.audioURL(keys[index], in: directory)
                    guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                    guard let kokoro = try await self?.loadKokoro() else { return }
                    var samples: [Float] = [], starts: [Double] = []
                    for (number, sentence) in sentences[index].enumerated() {
                        try Task.checkCancellation()
                        if number > 0 { samples += [Float](repeating: 0, count: Int(Self.sentencePause * PassageAudio.sampleRate)) }
                        starts.append(Double(samples.count) / PassageAudio.sampleRate)
                        samples += try await kokoro.synthesizeDetailed(text: ArticleSpeech.spoken(sentence), voice: voice).samples
                    }
                    try Task.checkCancellation()
                    // Written first, so a passage's audio is never there without its sentence times.
                    try JSONEncoder().encode(starts).write(to: PassageAudio.sentencesURL(keys[index], in: directory), options: .atomic)
                    let length = try await PassageAudio.write(samples, to: url)
                    if self?.directory == directory { self?.durations[index] = length }
                    self?.scheduleReady()
                }
                if !Task.isCancelled { self?.generator = nil }
            } catch where !Task.isCancelled {
                self?.generator = nil
                self?.errorMessage = "Couldn't synthesize the next part: \(error.localizedDescription)"
            } catch {}
        }
    }

    /// The model downloads (about 120 MB) the first time, then loads from disk.
    private func loadKokoro() async throws -> KokoroAneManager {
        if let kokoro { return kokoro }
        let loading = loadingKokoro ?? Task {
            let manager = KokoroAneManager(computeUnits: Self.computeUnits)
            try await manager.initialize()
            await manager.setEnglishCustomLexicon(ArticleSpeech.pronunciations)
            return manager
        }
        loadingKokoro = loading
        isLoadingVoice = true
        defer { isLoadingVoice = false }
        do {
            let manager = try await loading.value
            kokoro = manager
            return manager
        } catch {
            loadingKokoro = nil
            throw error
        }
    }

}

extension Narrator {
    /// A Kokoro English voice. Its pack is a small download the first time it reads.
    struct Voice: Identifiable, Hashable {
        enum Accent: String, CaseIterable { case american = "American", british = "British" }

        let id: String
        let accent: Accent
        let isFeminine: Bool

        /// Only American and British voices: the others speak English with their own language's accent.
        init?(_ id: String) {
            let prefix = id.prefix(3)
            guard KokoroAneConstants.englishVoices.contains(id), id.count > 3, ["af_", "am_", "bf_", "bm_"].contains(prefix) else { return nil }
            self.id = id
            accent = prefix.first == "a" ? .american : .british
            isFeminine = prefix.dropFirst().first == "f"
        }

        var name: String { id.dropFirst(3).capitalized }

        static let all = KokoroAneConstants.englishVoices.compactMap(Voice.init)
    }
}
