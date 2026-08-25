import AppKit
import SwiftUI

/// Hosts the first-launch onboarding window that walks the user through the two
/// required privacy grants and offers to launch at login. Reopenable from
/// Settings › Permissions.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings

    /// Called when the window is dismissed, so the shell can remember that the
    /// welcome flow has been seen.
    var onFinished: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = WelcomeView(settings: settings) { [weak self] in self?.window?.close() }
        let hosting = NSHostingController(rootView: root)
        // Size the window to the content's natural height so nothing is clipped.
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onFinished?()
    }
}

// MARK: - SwiftUI content

private struct WelcomeView: View {
    let settings: AppSettings
    let onDone: () -> Void

    @State private var allGranted = PermissionsManager.allGranted
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled
    @State private var overrideCmdTab: Bool

    init(settings: AppSettings, onDone: @escaping () -> Void) {
        self.settings = settings
        self.onDone = onDone
        _overrideCmdTab = State(initialValue: settings.switcherModifier == .command)
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 20) {
                section(
                    number: 1,
                    title: "Grant two permissions",
                    subtitle: "Both are needed for previews to work."
                ) {
                    PermissionsView { granted in allGranted = granted }
                }

                section(
                    number: 2,
                    title: "Window switcher",
                    subtitle: "Flip through all open windows with a keyboard shortcut."
                ) {
                    overrideCard
                }

                section(
                    number: 3,
                    title: "Start automatically",
                    subtitle: "Optional — keep previews always on hand."
                ) {
                    launchCard
                }
            }
            .padding(24)
            footer
        }
        .frame(width: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.top, 36)

            Text("Welcome to MDock Preview")
                .font(.system(size: 24, weight: .bold))
            Text("Live window previews when you hover a Dock icon.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    // MARK: Sections

    @ViewBuilder
    private func section<Content: View>(
        number: Int,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(number)")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            content()
                .padding(.leading, 2)
        }
    }

    private var overrideCard: some View {
        Toggle(isOn: Binding(
            get: { overrideCmdTab },
            set: { newValue in
                overrideCmdTab = newValue
                settings.switcherModifier = newValue ? .command : .option
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Override ⌘Tab").font(.body.weight(.medium))
                Text("Use ⌘Tab for the window switcher instead of the macOS app switcher. Turn off to use ⌥Tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35))
        )
    }

    private var launchCard: some View {
        Toggle(isOn: Binding(
            get: { launchAtLogin },
            set: { newValue in
                LaunchAtLoginManager.setEnabled(newValue)
                launchAtLogin = LaunchAtLoginManager.isEnabled
                if newValue, LaunchAtLoginManager.requiresApproval {
                    LaunchAtLoginManager.openLoginItemsSettings()
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at login").font(.body.weight(.medium))
                Text("Open MDock Preview automatically when you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35))
        )
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if allGranted {
                Label("All set — previews are ready.", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Text("You can grant permissions now or later from Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Relaunch App", action: relaunch)
                    .controlSize(.large)
                Button(allGranted ? "Start Using MDock Preview" : "Continue", action: onDone)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4))
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
