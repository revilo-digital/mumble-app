import SwiftUI

struct MenuContent: View {
    let app: AppModel

    var body: some View {
        Text(status)
        if let timing = app.controller.lastTiming {
            Text("Last one took \(timing, format: .number.precision(.fractionLength(1))) s")
        }
        if !app.permissions.allGranted {
            Button("Finish Setting Up…") { app.showSetup() }
        }
        Divider()
        Button("Settings…") { app.showSettings() }
            .keyboardShortcut(",")
        Button("Quit Mumble") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var status: String {
        switch app.controller.phase {
        case .listening: "Listening…"
        case .working: "Working…"
        case .idle, .notice: app.triggerHint
        }
    }
}

struct MenuBarIcon: View {
    let controller: DictationController

    var body: some View {
        switch controller.phase {
        case .listening: Image(systemName: "waveform.circle.fill")
        case .working: Image(systemName: "ellipsis.circle")
        case .idle, .notice: Image(systemName: "waveform")
        }
    }
}
