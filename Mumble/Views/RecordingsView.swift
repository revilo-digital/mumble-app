import AVFoundation
import SwiftUI

/// The last few dictations: play them back, mark each right or wrong, and say what was meant.
struct RecordingsView: View {
    let recordings: RecordingList
    let customWords: CustomWords
    let speech: SpeechEngines
    @AppStorage(Recordings.settingKey) private var keepRecordings = false
    @State private var selection: SavedRecording.ID?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Toggle(isOn: $keepRecordings) {
                    Text("Keep recordings")
                    Text("Saves your last \(Recordings.limit) dictations on this Mac, with the app and nearby text. Mark the wrong ones to see which speech engine suits your voice.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 92)
            Divider()
            if recordings.items.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform",
                    description: Text(keepRecordings ? "Dictate something and it shows up here." : "Turn on Keep recordings, then dictate something.")
                )
            } else {
                HSplitView {
                    List(recordings.items, selection: $selection) { item in
                        RecordingRow(item: item)
                    }
                    .frame(minWidth: 200, idealWidth: 230)
                    Group {
                        if let item = recordings.items.first(where: { $0.id == selection }) {
                            RecordingDetail(item: item, recordings: recordings, customWords: customWords, speech: speech)
                                .id(item.id)
                        } else {
                            Text("Choose a recording").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            recordings.reload()
            if selection == nil { selection = recordings.items.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: Recordings.saved)) { _ in recordings.reload() }
    }
}

private struct RecordingRow: View {
    let item: SavedRecording

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.info.inserted.isEmpty ? "(nothing went in)" : item.info.inserted)
                    .lineLimit(2)
                    .foregroundStyle(item.info.inserted.isEmpty ? .secondary : .primary)
                Text("\(item.info.date.formatted(date: .omitted, time: .shortened)) · \(item.info.context.app ?? "Unknown app")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            switch item.info.rating {
            case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .wrong: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case nil: EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RecordingDetail: View {
    let item: SavedRecording
    let recordings: RecordingList
    let customWords: CustomWords
    let speech: SpeechEngines
    @State private var whisperResult: String?
    @State private var trying = false
    @State private var meant: String
    @State private var editing: Bool
    @State private var player = Player()

    init(item: SavedRecording, recordings: RecordingList, customWords: CustomWords, speech: SpeechEngines) {
        self.item = item
        self.recordings = recordings
        self.customWords = customWords
        self.speech = speech
        _meant = State(initialValue: item.info.meant ?? item.info.inserted)
        _editing = State(initialValue: item.info.rating == .wrong)
    }

    private var suggestions: [String] {
        guard item.info.rating == .wrong, let meant = item.info.meant else { return [] }
        return RecordingList.suggestedWords(meant: meant, heard: item.info.heard, existing: customWords.words.map(\.word))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("When", value: item.info.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Where", value: [item.info.context.app, item.info.context.windowTitle].compactMap { $0 }.joined(separator: " · "))
                LabeledContent("Length", value: String(format: "%.1f s", item.info.seconds))
                HStack {
                    Button {
                        player.toggle(item.audioURL)
                    } label: {
                        Label(player.isPlaying ? "Stop" : "Play", systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        player.stop()
                        recordings.delete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section(item.info.engine == "whisper" ? "What Whisper heard" : "What it heard") {
                Text(item.info.heard.isEmpty ? "(nothing)" : item.info.heard).textSelection(.enabled)
            }
            if let alsoHeard = item.info.alsoHeard {
                Section("What Apple heard") {
                    Text(alsoHeard.isEmpty ? "(nothing)" : alsoHeard).textSelection(.enabled)
                }
            }
            if item.info.engine != "whisper" {
                Section {
                    if let whisperResult {
                        Text(whisperResult).textSelection(.enabled)
                    }
                    HStack {
                        if trying { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(whisperResult == nil ? "Try Whisper" : "Try Again", action: tryWhisper)
                            .disabled(trying || speech.whisperStatus != .ready)
                            .help(speech.whisperStatus == .ready ? "Run Whisper on this recording, with the context it would have had" : "Whisper isn't ready (Settings › Speech Engine)")
                    }
                } header: {
                    Text("What Whisper hears")
                }
            }
            Section("What went in") {
                Text(item.info.inserted.isEmpty ? "(nothing)" : item.info.inserted).textSelection(.enabled)
            }
            Section {
                HStack {
                    Button {
                        editing = false
                        recordings.markGood(item)
                    } label: {
                        Label("Right", systemImage: item.info.rating == .good ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    Button {
                        editing = true
                    } label: {
                        Label("Wrong", systemImage: item.info.rating == .wrong ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                    Spacer()
                }
                if editing {
                    TextField("What you said", text: $meant, axis: .vertical)
                        .lineLimit(2...6)
                    HStack {
                        Spacer()
                        Button("Save") { recordings.markWrong(item, meant: meant) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(meant.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                ForEach(suggestions, id: \.self) { word in
                    HStack {
                        Text("Add “\(word)” to custom words?")
                        Spacer()
                        Button("Add") { _ = customWords.add(word) }
                    }
                }
            } header: {
                Text("Was it right?")
            } footer: {
                Text("Type exactly what you said. It's used to score speech engines on your voice, and names it missed can be added as custom words.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onDisappear { player.stop() }
    }
}

extension RecordingDetail {
    private func tryWhisper() {
        trying = true
        Task {
            defer { trying = false }
            do {
                let (text, seconds) = try await speech.tryWhisper(
                    on: item.audioURL, words: customWords.words.map(\.word), context: item.info.context,
                    earlier: recordings.earlier(than: item), date: item.info.date
                )
                whisperResult = "\(text.isEmpty ? "(nothing)" : text)  (\(String(format: "%.1f", seconds)) s)"
            } catch {
                whisperResult = "Couldn't run Whisper: \(error.localizedDescription)"
            }
        }
    }
}

/// Plays one recording at a time.
@MainActor
@Observable
private final class Player: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if isPlaying {
            stop()
            return
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        isPlaying = player?.play() ?? false
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}
