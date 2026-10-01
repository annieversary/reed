import AVFoundation
import FluidAudio
import MediaPlayer
import Observation
#if SWIFT_PACKAGE
import ReedCore
#endif

/// Reads saved articles aloud with Kokoro, synthesized on device.
///
/// Each passage is synthesized once, cached as a small audio file beside the article, and queued for
/// gapless playback as soon as it's ready. Synthesis runs ahead of playback to the end of the article,
/// so replaying or skipping back never waits.
@MainActor @Observable
final class Narrator {
    static let voice = KokoroAneConstants.defaultVoice

    private(set) var articleID: UUID?
    private(set) var title = ""
    private(set) var domain = ""
    private(set) var passageCount = 0
    /// The passage being heard, or waited for.
    private(set) var current = 0
    /// The last passage queued on the player.
    private(set) var scheduled = -1
    private(set) var isPlaying = false
    private(set) var isLoadingVoice = false
    /// Why synthesis stopped. Passages already made keep playing.
    private(set) var errorMessage: String?

    /// Playback has reached a passage that isn't synthesized yet.
    var isWaiting: Bool { articleID != nil && scheduled < current && errorMessage == nil }

    @ObservationIgnored private var passages: [String] = []
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var kokoro: KokoroAneManager?
    @ObservationIgnored private var loadingKokoro: Task<KokoroAneManager, any Error>?
    @ObservationIgnored private var generator: Task<Void, Never>?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    /// Bumped whenever the player is flushed, so callbacks from discarded buffers are ignored.
    @ObservationIgnored private var epoch = 0

    private static let lookahead = 3
    nonisolated private static let sampleRate = Double(KokoroAneConstants.sampleRate)
    /// A beat of silence after each passage, so paragraphs don't run together.
    nonisolated private static let pause = 0.35
    nonisolated private static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        observeAudioChanges()
        installRemoteCommands()
    }

    func play(_ article: Article, in library: Library) {
        if article.id == articleID { resume(); return }
        guard let version = article.contentVersion, let url = library.contentURL(for: article) else { return }
        let html: String
        do { html = try String(contentsOf: url, encoding: .utf8) } catch { library.errorMessage = error.localizedDescription; return }
        stop()
        articleID = article.id
        title = article.title
        domain = article.domain
        passages = ArticleSpeech.passages(title: article.title, html: html)
        passageCount = passages.count
        directory = library.storage.audioDirectory(article.id, version: version, voice: Self.voice)
        start(at: 0)
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard articleID != nil, !isPlaying else { return }
        if engine.isRunning {
            isPlaying = true
            player.play()
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
        articleID = nil
        passages = []
        passageCount = 0
        current = 0
        scheduled = -1
        isPlaying = false
        errorMessage = nil
        directory = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        updateNowPlaying()
    }

    private func start(at index: Int) {
        epoch += 1
        player.stop()
        current = index
        scheduled = index - 1
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
        scheduleReady()
        generate(from: index)
        updateNowPlaying()
    }

    /// Queues synthesized passages until the player holds a few ahead of the one being heard.
    private func scheduleReady() {
        guard let directory else { return }
        while scheduled + 1 < passageCount, scheduled + 1 < current + Self.lookahead,
              let buffer = Self.buffer(at: Self.audioURL(scheduled + 1, in: directory)) {
            scheduled += 1
            let index = scheduled, epoch = epoch
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.finished(index, epoch: epoch) }
            }
        }
    }

    private func finished(_ index: Int, epoch: Int) {
        guard epoch == self.epoch, index == current else { return }
        if current + 1 >= passageCount { stop(); return }
        current += 1
        scheduleReady()
    }

    private func generate(from start: Int) {
        generator?.cancel()
        guard let directory else { return }
        let passages = passages
        errorMessage = nil
        generator = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for index in start..<passages.count {
                    let url = Self.audioURL(index, in: directory)
                    guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                    guard let kokoro = try await self?.loadKokoro() else { return }
                    let samples = try await kokoro.synthesizeDetailed(text: passages[index], voice: Self.voice).samples
                    try Task.checkCancellation()
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
            let manager = KokoroAneManager()
            try await manager.initialize()
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
            (commands.previousTrackCommand, { $0.skip(by: -1) }),
        ]
        for (command, action) in actions {
            command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
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
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: domain,
                                 MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
    }
}
