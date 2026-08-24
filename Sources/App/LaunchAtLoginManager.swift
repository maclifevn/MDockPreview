import ServiceManagement
import os

/// Wraps `SMAppService.mainApp` — the modern (macOS 13+) login-item API. No
/// helper bundle or entitlement is needed; macOS registers the main app itself.
enum LaunchAtLoginManager {
    private static let log = Logger(
        subsystem: "com.maclife.mdockpreview",
        category: "login-item"
    )

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The user disabled the item in System Settings, so it cannot be turned on
    /// again programmatically — they have to re-enable it there.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled {
                try service.unregister()
            }
            return true
        } catch {
            log.error(
                "Could not update login item: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
