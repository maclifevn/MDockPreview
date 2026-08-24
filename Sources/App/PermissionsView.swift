import SwiftUI

/// Two permission cards with a live Granted/Needed status that refreshes while
/// on screen. Shared by the Welcome window and the Settings › Permissions tab.
struct PermissionsView: View {
    /// Reports whether both permissions are granted, on appear and on change.
    var onStatusChange: ((Bool) -> Void)? = nil

    @State private var hasAccessibility = PermissionsManager.hasAccessibility
    @State private var hasScreenRecording = PermissionsManager.hasScreenRecording

    private let pollTimer = Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()

    private var allGranted: Bool { hasAccessibility && hasScreenRecording }

    var body: some View {
        VStack(spacing: 12) {
            PermissionCard(
                symbol: "cursorarrow.rays",
                title: "Accessibility",
                detail: "Lets the app notice the pointer over the Dock and switch or close windows you pick.",
                granted: hasAccessibility
            ) {
                PermissionsManager.requestAccessibility()
                PermissionsManager.openAccessibilitySettings()
            }
            PermissionCard(
                symbol: "rectangle.on.rectangle",
                title: "Screen Recording",
                detail: "Lets the app render the live thumbnail of each window in the preview.",
                granted: hasScreenRecording
            ) {
                PermissionsManager.requestScreenRecording()
                PermissionsManager.openScreenRecordingSettings()
            }
        }
        .onAppear { onStatusChange?(allGranted) }
        .onReceive(pollTimer) { _ in
            hasAccessibility = PermissionsManager.hasAccessibility
            hasScreenRecording = PermissionsManager.hasScreenRecording
            onStatusChange?(allGranted)
        }
    }
}

struct PermissionCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    statusPill
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if !granted {
                Button("Grant", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(granted ? Color.green.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(granted ? "Granted" : "Needed")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(granted ? .green : .orange)
    }
}
