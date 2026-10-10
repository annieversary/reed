import SwiftUI

/// Controls for the article being read aloud, along the bottom of the window wherever you are in the library.
struct NarrationBar: View {
    @Bindable var narrator: Narrator
    /// Shown just above the controls, so the reader running beneath them can't hide it.
    var narrationReturn: NarrationReturn?
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 16) {
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
            if narrator.errorMessage != nil {
                Button("Retry") { narrator.retry() }.foregroundStyle(ReedStyle.accent)
            }
            Button("Previous Paragraph", systemImage: "backward.fill") { narrator.previous() }
            Button(narrator.isPlaying ? "Pause" : "Play", systemImage: narrator.isPlaying ? "pause.fill" : "play.fill") {
                narrator.togglePlayback()
            }
            .font(.title2).frame(width: 28)
            Button("Next Paragraph", systemImage: "forward.fill") { narrator.skip(by: 1) }
                .disabled(narrator.current + 1 >= narrator.passageCount)
            speedMenu
            Button("Stop Listening", systemImage: "xmark") { narrator.stop() }.foregroundStyle(.secondary)
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

    @ViewBuilder private var status: some View {
        if let error = narrator.errorMessage {
            Text(error)
        } else if narrator.isWaiting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(narrator.isLoadingVoice ? "Getting the voice ready. The first time, this downloads about 120 MB." : "Preparing audio…")
            }
        } else {
            Text("Paragraph \(narrator.current + 1) of \(narrator.passageCount)").monospacedDigit()
        }
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
