import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var dockPreviewController = DockPreviewController(settings: settings)
    private let statusItemController = StatusItemController()
    private let welcomeController = WelcomeWindowController()
    private lazy var settingsController = SettingsWindowController(
        settings: settings,
        onReopenWelcome: { [weak self] in self?.welcomeController.show() }
    )

    /// A menu-bar (LSUIElement) utility: no main window, no Dock tile. AppKit's
    /// classic entry point keeps full control over the activation policy.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        wireSettings()
        wireStatusItem()
        wireWelcome()

        applyTheme()
        statusItemController.setVisible(settings.showMenuBarIcon)
        maybeShowWelcome()
        dockPreviewController.applySettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockPreviewController.stop()
    }

    /// Relaunching the app (e.g. from Finder/Spotlight) reopens Settings — the
    /// way back in when the menu-bar icon is hidden.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        settingsController.show()
        return true
    }

    // MARK: - Wiring

    private func wireSettings() {
        settings.onDockPreviewConfigChanged = { [weak self] in
            self?.dockPreviewController.applySettings()
        }
        settings.onPreviewThemeChanged = { [weak self] in
            self?.applyTheme()
        }
        settings.onMenuBarVisibilityChanged = { [weak self] in
            guard let self else { return }
            self.statusItemController.setVisible(self.settings.showMenuBarIcon)
        }
    }

    private func wireStatusItem() {
        // Suspend discovery while our own menu owns event tracking, exactly as
        // MFinder suspends it while its status menu is open.
        statusItemController.onMenuTrackingChanged = { [weak self] isTracking in
            self?.dockPreviewController.setSuspended(isTracking)
        }
        statusItemController.onOpenSettings = { [weak self] in
            self?.settingsController.show()
        }
    }

    private func wireWelcome() {
        welcomeController.onFinished = { [weak self] in
            self?.settings.hasCompletedWelcome = true
        }
    }

    // MARK: - Theme

    private func applyTheme() {
        DockPreviewThemeStore.shared.theme = settings.previewTheme
    }

    // MARK: - Onboarding

    /// Show the guide on the very first launch, and on any later launch where a
    /// required permission is still missing (so the app can't work silently).
    private func maybeShowWelcome() {
        guard !settings.hasCompletedWelcome || !PermissionsManager.allGranted else {
            return
        }
        welcomeController.show()
    }
}
