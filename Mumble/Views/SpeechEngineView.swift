import SwiftUI

/// Choose the speech engine, and download and load Whisper.
struct SpeechEngineView: View {
    let speech: SpeechEngines

    var body: some View {
        Form {
            Section {
                Picker("Speech engine", selection: Binding(get: { speech.choice }, set: { speech.choose($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Whisper")
                        Text("Better with accents and names, and uses what came before as context. About a second slower. Takes 630 MB of disk space.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .tag(SpeechEngineChoice.whisper)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple")
                        Text("Fastest. Works while you talk, so the text is ready as soon as you let go.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .tag(SpeechEngineChoice.apple)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("Speech engine")
            } footer: {
                Text("Both run on this Mac. Nothing you say leaves it.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if speech.choice == .whisper {
                Section("Whisper") {
                    WhisperStatusRow(speech: speech)
                }
                Section {
                    Label("Your custom words", systemImage: "character.book.closed")
                    Label("The window's title", systemImage: "macwindow")
                    Label("What you dictated in the last few minutes (in the same app, or just before switching)", systemImage: "clock.arrow.circlepath")
                    Label("The text just before the cursor, where the app shares it", systemImage: "text.cursor")
                } header: {
                    Text("Context given to Whisper")
                } footer: {
                    Text("Apple's engine listens alongside, so if Whisper isn't ready or fails, Apple's text goes in instead.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WhisperStatusRow: View {
    let speech: SpeechEngines

    var body: some View {
        switch speech.whisperStatus {
        case .notDownloaded:
            HStack {
                Text("Whisper needs a one-off download of \(WhisperEngine.downloadSize).")
                Spacer()
                Button("Download") { speech.loadWhisper() }
            }
        case let .downloading(fraction):
            VStack(alignment: .leading) {
                Text("Downloading… Apple's engine is used until it's ready.")
                ProgressView(value: fraction)
            }
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Getting ready…")
                    Text("The first time, setting it up for this Mac can take a few minutes. Apple's engine is used until then.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(reason):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't load Whisper, so Apple's engine is being used.")
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Try Again") { speech.loadWhisper() }
            }
        }
    }
}
