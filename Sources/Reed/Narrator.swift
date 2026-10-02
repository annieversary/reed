import AVFoundation
import FluidAudio
import MediaPlayer
import Observation
import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// Reads saved articles aloud with Kokoro, synthesized on device.
///
/// Each passage is synthesized once, a sentence at a time so the one being heard can be followed, cached as
/// a small audio file beside the article, and queued for gapless playback as soon as it's ready. Synthesis runs ahead of playback to the end of the article,
/// so replaying or skipping back never waits.
@MainActor @Observable
final class Narrator {
    private(set) var articleID: UUID?
    private(set) var title = ""
    private(set) var domain = ""
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
            guard let article, let library, let version = article.contentVersion else { return }
            directory = library.storage.audioDirectory(article.id, version: version, voice: voice)
            durations = [:]
            sentenceStarts = [:]
            let wasPlaying = isPlaying
            start(at: current)
            if !wasPlaying { pause() }
        }
    }

    /// The voice whose sample is being prepared or played.
    private(set) var previewVoice: String?
    private(set) var isPreviewPlaying = false
    private(set) var previewError: String?

    /// Playback has reached a passage that isn't synthesized yet.
    var isWaiting: Bool { articleID != nil && scheduled < current && errorMessage == nil }

    @ObservationIgnored private var passages: [String] = []
    @ObservationIgnored private var sentences: [[String]] = []
    @ObservationIgnored private var article: Article?
    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var kokoro: KokoroAneManager?
    @ObservationIgnored private var loadingKokoro: Task<KokoroAneManager, any Error>?
    @ObservationIgnored private var generator: Task<Void, Never>?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    /// Bumped whenever the player is flushed, so callbacks from discarded buffers are ignored.
    @ObservationIgnored private var epoch = 0
    /// Where each queued passage starts on the player's timeline, which restarts whenever the player is flushed.
    @ObservationIgnored private var startFrames: [Int: AVAudioFramePosition] = [:]
    @ObservationIgnored private var nextFrame: AVAudioFramePosition = 0
    /// How far into the current passage playback began, after seeking.
    @ObservationIgnored private var startOffset: AVAudioFramePosition = 0
    /// Lengths of synthesized passages, in seconds.
    @ObservationIgnored private var durations: [Int: Double] = [:]
    /// When each sentence of a synthesized passage begins, in seconds into it.
    @ObservationIgnored private var sentenceStarts: [Int: [Double]] = [:]
    /// Keeps `sentence` in step with playback.
    @ObservationIgnored private var tracker: Task<Void, Never>?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var previewPlayer: AVAudioPlayer?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    private static let sample = "This is how articles will sound when Reed reads them aloud."
    private static let lookahead = 3
    nonisolated private static let sampleRate = Double(KokoroAneConstants.sampleRate)
    /// A beat of silence after each passage, so paragraphs don't run together.
    nonisolated private static let pause = 0.35
    /// The shorter beat between sentences of a passage.
    nonisolated private static let sentencePause = 0.15
    nonisolated private static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
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
        engine.connect(player, to: timePitch, format: Self.format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: Self.format)
        timePitch.rate = rate
        observeAudioChanges()
        installRemoteCommands()
    }

    /// Reads `article` from `passage`, or from where it was last left off.
    func play(_ article: Article, from passage: Int? = nil, in library: Library) {
        if article.id == articleID {
            if let passage, passage != current { start(at: min(max(passage, 0), passageCount - 1)) } else { resume() }
            return
        }
        guard let version = article.contentVersion, let passages = library.passages(for: article), !passages.isEmpty else {
            library.errorMessage = ReedError.damagedArticle.localizedDescription
            return
        }
        stop()
        self.article = article
        self.library = library
        articleID = article.id
        title = article.title
        domain = article.domain
        self.passages = passages
        sentences = passages.map(ArticleSpeech.sentences(in:))
        passageCount = passages.count
        directory = library.storage.audioDirectory(article.id, version: version, voice: voice)
        artwork = Self.artwork(from: library.leadImage(for: article))
        start(at: min(max(passage ?? article.narrationPassage ?? 0, 0), passages.count - 1))
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        stopTracking()
        updateNowPlaying()
    }

    func resume() {
        guard articleID != nil, !isPlaying else { return }
        if engine.isRunning {
            isPlaying = true
            player.play()
            track()
            updateNowPlaying()
        } else {
            start(at: current)
        }
        if generator == nil { generate(from: current) }
    }

    func togglePlayback() { isPlaying ? pause() : resume() }

    func skip(by offset: Int) {
        guard articleID != nil else { return }
        start(at: min(max(current + offset, 0), passageCount - 1))
    }

    /// Back to the start of the passage, or to the one before if it has only just begun.
    func previous() {
        guard articleID != nil else { return }
        if elapsedInPassage > Self.restartThreshold || current == 0 { start(at: current) } else { skip(by: -1) }
    }

    /// Jumps to a point in the whole article, as when scrubbing on the lock screen.
    func seek(to time: Double) {
        guard articleID != nil else { return }
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
        guard articleID != nil else { return }
        errorMessage = nil
        if generator == nil { generate(from: current) }
    }

    func stop() {
        epoch += 1
        generator?.cancel()
        generator = nil
        player.stop()
        engine.stop()
        stopTracking()
        articleID = nil
        passages = []
        sentences = []
        passageCount = 0
        current = 0
        sentence = 0
        scheduled = -1
        isPlaying = false
        errorMessage = nil
        directory = nil
        article = nil
        library = nil
        artwork = nil
        durations = [:]
        sentenceStarts = [:]
        startFrames = [:]
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        updateNowPlaying()
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
                    try await Self.write(samples, to: url)
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
        previewPlayer?.stop()
        previewPlayer = nil
        previewVoice = nil
        isPreviewPlaying = false
    }

    private func start(at index: Int, offset: Double = 0) {
        epoch += 1
        player.stop()
        current = index
        scheduled = index - 1
        startFrames = [:]
        nextFrame = 0
        startOffset = AVAudioFramePosition(offset * Self.sampleRate)
        sentence = sentenceIndex(at: offset)
        rememberPosition()
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
            #endif
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

    /// Queues synthesized passages until the player holds a few ahead of the one being heard.
    private func scheduleReady() {
        guard let directory else { return }
        while scheduled + 1 < passageCount, scheduled + 1 < current + Self.lookahead,
              var buffer = Self.buffer(at: Self.audioURL(scheduled + 1, in: directory)) {
            scheduled += 1
            let index = scheduled, epoch = epoch
            durations[index] = Double(buffer.frameLength) / Self.sampleRate
            var skipped: AVAudioFramePosition = 0
            if index == current, startOffset > 0, let rest = Self.slice(buffer, from: AVAudioFrameCount(startOffset)) {
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
    }

    private var playerFrame: AVAudioFramePosition? {
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return time.sampleTime
    }

    private var elapsedInPassage: Double {
        guard let begins = startFrames[current], let now = playerFrame else { return Double(startOffset) / Self.sampleRate }
        return max(0, Double(now - begins) / Self.sampleRate)
    }

    /// Exact once a passage is synthesized, estimated from its words until then.
    private func duration(of index: Int) -> Double {
        if let known = durations[index] { return known }
        if let directory, let file = try? AVAudioFile(forReading: Self.audioURL(index, in: directory)) {
            durations[index] = Double(file.length) / file.fileFormat.sampleRate
            return durations[index]!
        }
        return Double(passages[index].split(whereSeparator: \.isWhitespace).count) / Self.wordsPerSecond + Self.pause
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
        if let directory, let data = try? Data(contentsOf: Self.sentencesURL(index, in: directory)),
           let starts = try? JSONDecoder().decode([Double].self, from: data), starts.count == parts.count {
            sentenceStarts[index] = starts
            return starts
        }
        guard durations[index] != nil || (directory.map { FileManager.default.fileExists(atPath: Self.audioURL(index, in: $0).path) } ?? false)
        else { return [0] }
        let lengths = parts.map { Double($0.count) }
        let spoken = max(duration(of: index) - Self.pause, 0)
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
                    let heard = sentenceIndex(at: elapsedInPassage)
                    if heard != sentence { sentence = heard }
                } else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopTracking() {
        tracker?.cancel()
        tracker = nil
    }

    private func finished(_ index: Int, epoch: Int) {
        guard epoch == self.epoch, index == current else { return }
        guard current + 1 < passageCount else {
            if let article, let library {
                article.narrationPassage = nil
                library.updateProgress(article, value: 1)
            }
            stop()
            return
        }
        current += 1
        sentence = 0
        startOffset = 0
        rememberPosition()
        scheduleReady()
        updateNowPlaying()
    }

    /// Kept on the article, so listening resumes there next time, even after relaunching.
    private func rememberPosition() {
        guard let article, let library else { return }
        article.narrationPassage = current
        library.save()
    }

    private func generate(from start: Int) {
        generator?.cancel()
        guard let directory else { return }
        let sentences = sentences, voice = voice
        errorMessage = nil
        generator = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for index in start..<sentences.count {
                    let url = Self.audioURL(index, in: directory)
                    guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                    guard let kokoro = try await self?.loadKokoro() else { return }
                    var samples: [Float] = [], starts: [Double] = []
                    for (number, sentence) in sentences[index].enumerated() {
                        if number > 0 { samples += [Float](repeating: 0, count: Int(Self.sentencePause * Self.sampleRate)) }
                        starts.append(Double(samples.count) / Self.sampleRate)
                        samples += try await kokoro.synthesizeDetailed(text: ArticleSpeech.spoken(sentence), voice: voice).samples
                        try Task.checkCancellation()
                    }
                    // Written first, so a passage's audio is never there without its sentence times.
                    try JSONEncoder().encode(starts).write(to: Self.sentencesURL(index, in: directory), options: .atomic)
                    try await Self.write(samples, to: url)
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

    private static func audioURL(_ index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("\(index).m4a")
    }

    private static func sentencesURL(_ index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("\(index).json")
    }

    private static func buffer(at url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        return buffer
    }

    /// Written under a temporary name and moved into place, so a passage file is only ever complete.
    @concurrent nonisolated private static func write(_ samples: [Float], to url: URL) async throws {
        let padded = samples + [Float](repeating: 0, count: Int(pause * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(padded.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        padded.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: padded.count) }
        let partial = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
            // The file is finished when it's released, at the end of this scope.
            try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    nonisolated private static func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard start < buffer.frameLength,
              let rest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - start) else { return nil }
        rest.frameLength = rest.frameCapacity
        rest.floatChannelData![0].update(from: buffer.floatChannelData![0] + Int(start), count: Int(rest.frameLength))
        return rest
    }

    /// The article's first image, or Reed's own artwork. Built outside the main actor, since the system
    /// asks for the image from a background queue.
    nonisolated private static func artwork(from image: URL?) -> MPMediaItemArtwork? {
        #if os(iOS)
        guard let image = image.flatMap({ UIImage(contentsOfFile: $0.path) }) ?? UIImage(named: "NowPlayingArtwork") else { return nil }
        #else
        guard let image = image.flatMap(NSImage.init(contentsOf:)) ?? NSImage(named: "NowPlayingArtwork") else { return nil }
        #endif
        nonisolated(unsafe) let artwork = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in artwork }
    }

    private func observeAudioChanges() {
        let center = NotificationCenter.default
        // The engine stops itself when the output device changes; carry on from the same passage.
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.start(at: self.current)
            }
        }
        #if os(iOS)
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.pause()
                case .ended where options.contains(.shouldResume): self?.resume()
                default: break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            // Unplugged headphones pause rather than switching to the speaker.
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
        #endif
    }

    private func installRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, @MainActor (Narrator) -> Void)] = [
            (commands.playCommand, { $0.resume() }),
            (commands.pauseCommand, { $0.pause() }),
            (commands.togglePlayPauseCommand, { $0.togglePlayback() }),
            (commands.nextTrackCommand, { $0.skip(by: 1) }),
            (commands.previousTrackCommand, { $0.previous() }),
        ]
        for (command, action) in actions {
            command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard articleID != nil else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }
        let elapsed = (0..<current).reduce(0) { $0 + duration(of: $1) } + elapsedInPassage
        let total = (0..<passageCount).reduce(0) { $0 + duration(of: $1) }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: domain,
                                   MPMediaItemPropertyPlaybackDuration: total,
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: min(elapsed, total),
                                   MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
                                   MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate)]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
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
