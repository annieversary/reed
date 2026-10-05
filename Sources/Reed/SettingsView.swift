import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

struct SettingsView: View {
    @Environment(Narrator.self) private var narrator
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var showingSubstackSignIn = false

    var body: some View {
        @Bindable var narrator = narrator
        Form {
            Section {
                Picker("Voice", selection: $narrator.voice) {
                    ForEach(Narrator.Voice.Accent.allCases, id: \.self) { accent in
                        Section(accent.rawValue) {
                            ForEach(Narrator.Voice.all.filter { $0.accent == accent }) { voice in
                                Text(voice.name).tag(voice.id)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    if narrator.previewVoice == nil {
                        Button("Play Sample", systemImage: "play.fill") { narrator.preview(narrator.voice) }
                    } else {
                        Button("Stop Sample", systemImage: "stop.fill") { narrator.stopPreview() }
                        if !narrator.isPreviewPlaying {
                            ProgressView().controlSize(.small)
                            Text(narrator.isLoadingVoice ? "Getting the voice ready…" : "Preparing sample…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = narrator.previewError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Reading Aloud")
            } footer: {
                Text("Each voice downloads the first time it reads.")
            }
            Section {
                if SubstackAccount.shared.isSignedIn {
                    LabeledContent("Signed in") {
                        Button("Sign Out") { SubstackAccount.shared.signOut() }
                    }
                } else {
                    Button("Sign In to Substack…") { showingSubstackSignIn = true }
                }
            } header: {
                Text("Substack")
            } footer: {
                Text("Once you're signed in, the posts Substack picks for you appear under Discover.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingSubstackSignIn) { SubstackSignInView() }
        .onChange(of: narrator.voice) { if narrator.previewVoice != nil { narrator.stopPreview() } }
        .onDisappear { narrator.stopPreview() }
        #if os(macOS)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        #else
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        #endif
    }
}
