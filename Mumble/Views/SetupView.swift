import SwiftUI

/// Shown at launch until both permissions are allowed.
struct SetupView: View {
    let app: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mumble needs two things")
                .font(.title2.weight(.semibold))
            Form {
                PermissionsView(permissions: app.permissions)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("\(app.triggerHint), then let go and the text goes where your cursor is. You can add shortcuts and mouse buttons in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(app.permissions.allGranted ? "Done" : "Later", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
