import AVFoundation
import MediaPlayer
import SwiftUI

/// What the system shows and sends about narration: the lock screen and Control Center, remote commands,
/// and changes to the audio route or session.
extension Narrator {
    /// The article's first image, or Reed's own artwork. Built outside the main actor, since the system
    /// asks for the image from a background queue.
    nonisolated static func artwork(from image: URL?) -> MPMediaItemArtwork? {
        #if os(iOS)
        guard let image = image.flatMap({ UIImage(contentsOfFile: $0.path) }) ?? UIImage(named: "NowPlayingArtwork") else { return nil }
        #else
        guard let image = image.flatMap(NSImage.init(contentsOf:)) ?? NSImage(named: "NowPlayingArtwork") else { return nil }
        #endif
        nonisolated(unsafe) let artwork = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in artwork }
    }

    func observeAudioChanges() {
        let center = NotificationCenter.default
        // The engine stops itself when the output device changes; carry on from the same passage.
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.start(at: self.current, offset: self.heard)
            }
        }
        #if os(iOS)
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    self.interruptedWhilePlaying = self.isPlaying
                    self.pause()
                case .ended:
                    if self.interruptedWhilePlaying, options.contains(.shouldResume) { self.resume() }
                    self.interruptedWhilePlaying = false
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

    func installRemoteCommands() {
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

    func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard readableID != nil else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }
        let elapsed = (0..<current).reduce(0) { $0 + duration(of: $1) } + elapsedInPassage
        let total = (0..<passageCount).reduce(0) { $0 + duration(of: $1) }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: source,
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
