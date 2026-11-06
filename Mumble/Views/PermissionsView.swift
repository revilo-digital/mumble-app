import SwiftUI

struct PermissionsView: View {
    let permissions: Permissions

    var body: some View {
        PermissionRow(
            title: "Microphone",
            detail: "To hear you while you hold the shortcut. The audio stays on your Mac.",
            granted: permissions.microphone == .authorized,
            action: permissions.microphone == .notDetermined ? "Allow…" : "Open Settings…"
        ) {
            permissions.requestMicrophone()
        }
        PermissionRow(
            title: "Accessibility",
            detail: "To put the text into the box you're typing in.",
            granted: permissions.accessibility,
            action: "Open Settings…"
        ) {
            permissions.requestAccessibility()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(action, action: perform)
            }
        }
    }
}
