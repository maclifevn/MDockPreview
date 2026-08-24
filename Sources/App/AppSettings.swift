import Foundation

/// Minimal settings store for the standalone app. Backed by `UserDefaults` and
/// notifies the app shell when a value the shell reacts to changes.
final class AppSettings {
    private let defaults: UserDefaults
    private enum Key {
        static let dockPreviewEnabled = "dockPreviewEnabled"
        static let previewTheme = "previewTheme"
        static let hasCompletedWelcome = "hasCompletedWelcome"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let windowSwitcherEnabled = "windowSwitcherEnabled"
    }

    /// Fired on the main actor after `dockPreviewEnabled` changes.
    var onDockPreviewConfigChanged: (() -> Void)?
    /// Fired on the main actor after `previewTheme` changes.
    var onPreviewThemeChanged: (() -> Void)?
    /// Fired on the main actor after `showMenuBarIcon` changes.
    var onMenuBarVisibilityChanged: (() -> Void)?
    /// Fired on the main actor after `windowSwitcherEnabled` changes.
    var onWindowSwitcherConfigChanged: (() -> Void)?

    var dockPreviewEnabled: Bool {
        didSet {
            guard dockPreviewEnabled != oldValue else { return }
            defaults.set(dockPreviewEnabled, forKey: Key.dockPreviewEnabled)
            onDockPreviewConfigChanged?()
        }
    }

    var previewTheme: DockPreviewTheme {
        didSet {
            guard previewTheme != oldValue else { return }
            defaults.set(previewTheme.rawValue, forKey: Key.previewTheme)
            onPreviewThemeChanged?()
        }
    }

    var showMenuBarIcon: Bool {
        didSet {
            guard showMenuBarIcon != oldValue else { return }
            defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon)
            onMenuBarVisibilityChanged?()
        }
    }

    var windowSwitcherEnabled: Bool {
        didSet {
            guard windowSwitcherEnabled != oldValue else { return }
            defaults.set(windowSwitcherEnabled, forKey: Key.windowSwitcherEnabled)
            onWindowSwitcherConfigChanged?()
        }
    }

    /// Whether the first-launch welcome flow has been dismissed at least once.
    var hasCompletedWelcome: Bool {
        didSet {
            guard hasCompletedWelcome != oldValue else { return }
            defaults.set(hasCompletedWelcome, forKey: Key.hasCompletedWelcome)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Enabled by default — showing dock previews is the whole point of the app.
        self.dockPreviewEnabled =
            defaults.object(forKey: Key.dockPreviewEnabled) as? Bool ?? true
        self.previewTheme =
            DockPreviewTheme(rawValue: defaults.string(forKey: Key.previewTheme) ?? "")
            ?? .system
        self.showMenuBarIcon =
            defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        self.windowSwitcherEnabled =
            defaults.object(forKey: Key.windowSwitcherEnabled) as? Bool ?? true
        self.hasCompletedWelcome = defaults.bool(forKey: Key.hasCompletedWelcome)
    }
}
