import AppKit

/// The menu-bar presence for the app. Owns the `NSStatusItem` (which can be
/// hidden from Settings), builds a minimal menu, and reports menu tracking so
/// the dock preview can suspend itself while this menu is open.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    /// Called with `true` when the menu opens and `false` when it closes.
    var onMenuTrackingChanged: (Bool) -> Void = { _ in }
    /// Called when the user opens Settings.
    var onOpenSettings: () -> Void = {}

    override init() {
        super.init()
        menu.delegate = self
    }

    /// Creates the menu-bar item, or removes it when hidden from Settings.
    func setVisible(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.variableLength
            )
            if let button = item.button {
                button.image = NSImage(
                    systemSymbolName: "rectangle.stack",
                    accessibilityDescription: "Dock Preview"
                )
                button.image?.isTemplate = true
                button.toolTip = "MDock Preview"
            }
            item.menu = menu
            statusItem = item
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuTrackingChanged(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        onMenuTrackingChanged(false)
    }

    // MARK: - Menu construction

    private func rebuild() {
        menu.removeAllItems()

        let settings = NSMenuItem(
            title: NSLocalizedString("Settings…", comment: "menu"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: NSLocalizedString("Quit MDock Preview", comment: "menu"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
