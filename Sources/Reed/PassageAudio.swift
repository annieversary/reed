import AVFoundation
import CryptoKit
import FluidAudio

/// A passage's narration as it's kept beside the article: its audio, named by what it says, and when each of its sentences begins.
enum PassageAudio {
    static let sampleRate = Double(KokoroAneConstants.sampleRate)
    /// A beat of silence after each passage, so paragraphs don't run together.
    static let pause = 0.35
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    static func audioURL(_ key: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(key).m4a")
    }

    static func sentencesURL(_ key: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    static func key(for sentences: [String]) -> String {
        SHA256.hash(data: Data(sentences.joined(separator: "\n").utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    @concurrent static func buffer(at url: URL) async -> sending AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        return buffer
    }

    /// The length in seconds of each of `files` that's there, by its place in the list.
    @concurrent static func lengths(of files: [URL]) async -> [Int: Double] {
        var lengths: [Int: Double] = [:]
        for (index, url) in files.enumerated() where FileManager.default.fileExists(atPath: url.path) {
            if let file = try? AVAudioFile(forReading: url) { lengths[index] = Double(file.length) / file.fileFormat.sampleRate }
        }
        return lengths
    }

    /// Written under a temporary name and moved into place, so a passage file is only ever complete. Returns its length in seconds.
    @discardableResult @concurrent static func write(_ samples: [Float], to url: URL) async throws -> Double {
        let padded = samples + [Float](repeating: 0, count: Int(pause * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(padded.count)) else { return 0 }
        buffer.frameLength = buffer.frameCapacity
        padded.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: padded.count) }
        let partial = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: partial) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
        do {
            // The file is finished when it's released, at the end of this scope.
            try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
        }
        // A passage the same as another is made once.
        if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.moveItem(at: partial, to: url) }
        return Double(padded.count) / sampleRate
    }

    static func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard start < buffer.frameLength,
              let rest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - start) else { return nil }
        rest.frameLength = rest.frameCapacity
        rest.floatChannelData![0].update(from: buffer.floatChannelData![0] + Int(start), count: Int(rest.frameLength))
        return rest
    }
}
