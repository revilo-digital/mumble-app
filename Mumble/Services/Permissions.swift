import AppKit
import ApplicationServices
import AVFoundation
import Observation

/// The microphone (to hear you) and Accessibility (to put text into other apps).
@MainActor
@Observable
final class Permissions {
    private(set) var microphone: AVAuthorizationStatus = .notDetermined
    private(set) var accessibility = false
    @ObservationIgnored private var timer: Timer?

    var allGranted: Bool { microphone == .authorized && accessibility }

    init() {
        refresh()
        // macOS doesn't announce Accessibility changes, so check now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility { accessibility = trusted }
    }

    func requestMicrophone() {
        if microphone == .notDetermined {
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refresh()
            }
        } else {
            open("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        // The first time, macOS's own prompt adds Mumble to the list; after that, go straight to the pane.
        let key = "didPromptForAccessibility"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { return }
        }
        open("Privacy_Accessibility")
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
