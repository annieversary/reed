import SwiftUI

/// Controls for the article being read aloud, along the bottom of the window wherever you are in the library.
struct NarrationBar: View {
    @Bindable var narrator: Narrator
    /// Shown just above the controls, so the reader running beneath them can't hide it.
    var narrationReturn: NarrationReturn?
    /// Narrow windows put the title on a row of its own above larger controls.
    var compact = false
    var onOpen: () -> Void

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 6) {
                    heading
                    HStack(spacing: 0) {
                        speedMenu.frame(maxWidth: .infinity, alignment: .leading)
                        transport.font(.title3)
                        HStack(spacing: 16) {
                            retryButton
                            stopButton
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                HStack(spacing: 16) {
                    heading
                    retryButton
                    transport
                    speedMenu
                    stopButton
                }
            }
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .top) {
            if let narrationReturn { returnButton(narrationReturn).offset(y: -54) }
        }
    }

    private func returnButton(_ narrationReturn: NarrationReturn) -> some View {
        Button("Back to the Paragraph Being Read", systemImage: narrationReturn.direction == .up ? "arrow.up" : "arrow.down",
               action: narrationReturn.follow)
            .labelStyle(.iconOnly).buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(ReedStyle.accent, in: Circle())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .transition(.opacity.combined(with: .offset(y: 8)))
            .help("Back to the Paragraph Being Read")
    }

    private var heading: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 2) {
                Text(narrator.book.map { "\($0) · \(narrator.title)" } ?? narrator.title).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                status.font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(narrator.book == nil ? "Open Article" : "Open Chapter")
    }

    private var transport: some View {
        HStack(spacing: compact ? 4 : 16) {
            Button("Previous Paragraph", systemImage: "backward.fill") { narrator.previous() }
                .frame(width: compact ? 48 : nil, height: compact ? 44 : nil)
            Button(narrator.isPlaying ? "Pause" : "Play", systemImage: narrator.isPlaying ? "pause.fill" : "play.fill") {
                narrator.togglePlayback()
            }
            .font(compact ? .title : .title2).frame(width: compact ? 56 : 28, height: compact ? 44 : nil)
            Button("Next Paragraph", systemImage: "forward.fill") { narrator.skip(by: 1) }
                .frame(width: compact ? 48 : nil, height: compact ? 44 : nil)
                .disabled(narrator.current + 1 >= narrator.passageCount)
        }
    }

    @ViewBuilder private var retryButton: some View {
        if narrator.errorMessage != nil {
            Button("Retry") { narrator.retry() }.foregroundStyle(ReedStyle.accent)
        }
    }

    private var stopButton: some View {
        Button("Stop Listening", systemImage: "xmark") { narrator.stop() }.foregroundStyle(.secondary)
    }

    @ViewBuilder private var status: some View {
        if let error = narrator.errorMessage {
            Text(error)
        } else if narrator.isWaiting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(narrator.isLoadingVoice ? "Getting the voice ready. The first time, this downloads about 120 MB." : "Preparing audio…")
            }
        } else {
            // The player's position isn't observed, so this redraws on a timer to keep the time left moving.
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                Text("Paragraph \(narrator.current + 1) of \(narrator.passageCount) · \(Self.timeLeft(narrator.remaining))")
                    .monospacedDigit()
            }
        }
    }

    private static func timeLeft(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes > 1 else { return "1 min left" }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " left"
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: $narrator.rate) {
                ForEach(Narrator.rates, id: \.self) { Text(Self.label($0)).tag($0) }
            }
        } label: {
            Text(Self.label(narrator.rate)).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .menuIndicator(.hidden).fixedSize()
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .help("Playback Speed")
    }

    private static func label(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...1))) + "×"
    }
}

/// A way back to the paragraph being read, from a reader scrolled away from it.
struct NarrationReturn {
    let direction: NarrationDirection
    let follow: () -> Void
}

extension EnvironmentValues {
    /// Shows, or with nil hides, the way back to the paragraph being read.
    @Entry var showNarrationReturn: (NarrationReturn?) -> Void = { _ in }
}
