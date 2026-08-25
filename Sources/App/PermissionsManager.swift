import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// The dock preview needs two macOS privacy grants, both requested at runtime:
///
/// - **Accessibility** — for the `CGEvent` mouse tap (`DockPointerMonitor`) and
///   for reading / raising / closing other apps' windows via the Accessibility
///   tree (`DockAXWorker`).
/// - **Screen Recording** — for the ScreenCaptureKit window thumbnails.
///
/// Neither can be granted programmatically; the user flips them in System
/// Settings. This type only detects the current state, triggers the system
/// prompts, and deep-links to the right settings pane.
enum PermissionsManager {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var allGranted: Bool {
        hasAccessibility && hasScreenRecording
    }

    /// Shows the system Accessibility prompt if the app is not yet trusted.
    @discardableResult
    static func requestAccessibility() -> Bool {
        // Use the literal key string rather than the imported C global
        // `kAXTrustedCheckOptionPrompt`, which Swift 6 flags as non-concurrency-safe
        // shared mutable state. The value is stable public API.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Shows the system Screen Recording prompt and, crucially, registers the app
    /// in the Screen Recording list. `CGRequestScreenCaptureAccess()` alone does
    /// not always surface the app there, so we also touch ScreenCaptureKit —
    /// the same TCC grant our thumbnails use — which reliably lists (and prompts
    /// for) the app.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
        }
        return granted
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
