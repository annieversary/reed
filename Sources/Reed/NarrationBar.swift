import SwiftUI

/// Controls for the article being read aloud, along the bottom of the window wherever you are in the library.
struct NarrationBar: View {
    @Bindable var narrator: Narrator
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(narrator.title).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    status.font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Article")
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
