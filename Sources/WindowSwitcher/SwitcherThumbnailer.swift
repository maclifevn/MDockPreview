import ScreenCaptureKit

/// Self-contained ScreenCaptureKit thumbnailing for the switcher, kept on the
/// main actor so the non-Sendable `SCWindow` descriptors never cross actors.
@MainActor
enum SwitcherThumbnailer {
    /// Maps every on-screen window id to its ScreenCaptureKit descriptor.
    static func shareableWindows() async -> [CGWindowID: SCWindow] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            var map: [CGWindowID: SCWindow] = [:]
            for window in content.windows { map[window.windowID] = window }
            return map
        } catch {
            return [:]
        }
    }

    static func capture(_ window: SCWindow) async -> CGImage? {
        let config = SCStreamConfiguration()
        let scale = min(
            1,
            640 / max(window.frame.width, 1),
            420 / max(window.frame.height, 1)
        )
        config.width = Int(max(1, window.frame.width * scale))
        config.height = Int(max(1, window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config
            )
        } catch {
            return nil
        }
    }
}
