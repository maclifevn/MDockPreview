import ApplicationServices
import Foundation

/// Maps an AXWindow to its CGWindowID. Private but stable API used by every
/// window switcher (AltTab, yabai…) — the public "AXWindowNumber" attribute
/// is unsupported by most applications.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

struct DockAppTarget: Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let appName: String
    let pointerLocation: CGPoint
}

struct DockRunningApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let appName: String
}

/// A real window of the target app, straight from its accessibility tree —
/// the same list the app's Window menu shows, with no phantom helper windows.
struct DockAXWindow: Sendable {
    let windowID: CGWindowID
    let title: String?
    let isMinimized: Bool
}

/// The AX element never leaves `DockAXWorker`'s serial queue. UI code receives
/// only the Sendable value snapshot above.
struct DockAXWindowResolution: @unchecked Sendable {
    let snapshot: DockAXWindow
    let element: AXUIElement
}

enum DockAXWindowSelectionPolicy {
    /// On macOS 26 the Dock/AX report a minimized window's subrole as
    /// `AXDialog`, not `AXStandardWindow` (measured on 26.5: Excel, Finder and
    /// third-party apps alike). Subrole alone therefore drops every minimized
    /// window from the switcher. A window the user minimized is by definition
    /// a real window, so the minimized flag promotes it regardless of subrole.
    static func selectsAsStandard(
        subrole: String?,
        isMinimized: Bool
    ) -> Bool {
        subrole == kAXStandardWindowSubrole || isMinimized
    }
}

enum DockAXResolver {
    private struct WindowCandidate {
        let element: AXUIElement
        let windowID: CGWindowID
    }

    // Dock is a local system process and normally answers in well under one
    // frame. If it does not, abandon this hover instead of making Dock service
    // a chain of stale requests while it is animating.
    private static let dockHitTestTimeout: Float = 0.03
    private static let applicationTimeout: Float = 0.15
    private static let windowTimeout: Float = 0.03

    /// Hit-tests inside the Dock process only. A system-wide hit-test at a
    /// generously padded screen edge can land in Excel (or any other app under
    /// the pointer), making every parent lookup wait on that app's AX server.
    static func target(
        at quartzPoint: CGPoint,
        pointerLocation: CGPoint,
        dockProcessIdentifier: pid_t,
        runningApplications: [DockRunningApplication]
    ) -> DockAppTarget? {
        guard AccessibilityPermission.isTrusted else { return nil }
        let dockApplication = AXUIElementCreateApplication(dockProcessIdentifier)
        AXUIElementSetMessagingTimeout(dockApplication, dockHitTestTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            dockApplication,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &hit
        ) == .success, var element = hit else { return nil }

        for _ in 0..<4 {
            AXUIElementSetMessagingTimeout(element, dockHitTestTimeout)
            if stringAttribute(element, kAXSubroleAttribute as CFString) == kAXApplicationDockItemSubrole,
               let target = appTarget(
                   from: element,
                   pointer: pointerLocation,
                   runningApplications: runningApplications
               ) {
                return target
            }
            guard let parent = elementAttribute(element, kAXParentAttribute as CFString) else { break }
            element = parent
        }
        return nil
    }

    /// The app's real standard windows, returned in stable creation order so
    /// helper/palette windows never appear and preview tiles do not reshuffle.
    static func windows(
        processIdentifier: pid_t,
        limit: Int
    ) -> [DockAXWindowResolution] {
        guard AccessibilityPermission.isTrusted else { return [] }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, applicationTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success, let axWindows = value as? [AXUIElement] else { return [] }

        var standard: [WindowCandidate] = []
        var others: [WindowCandidate] = []
        // AXWindows can grow without bound during a long Excel session. The
        // panel renders at most `limit` windows, so resolving every window ID
        // first makes latency grow with invisible work. Inspect a bounded
        // allowance for helper windows and stop as soon as the UI is full.
        let inspectionLimit = max(limit * 2, 16)
        var inspected = 0
        for element in axWindows {
            guard inspected < inspectionLimit else { break }
            inspected += 1
            AXUIElementSetMessagingTimeout(element, windowTimeout)
            var windowID: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &windowID) == .success,
                  windowID != 0 else { continue }
            let candidate = WindowCandidate(
                element: element,
                windowID: windowID
            )
            let subrole = stringAttribute(
                element,
                kAXSubroleAttribute as CFString
            )
            // Read the minimized flag only when the subrole alone does not
            // qualify — one extra AX round-trip for dialog-like windows only.
            let isMinimized = subrole != kAXStandardWindowSubrole
                && boolAttribute(
                    element,
                    kAXMinimizedAttribute as CFString
                ) == true
            if DockAXWindowSelectionPolicy.selectsAsStandard(
                subrole: subrole,
                isMinimized: isMinimized
            ) {
                standard.append(candidate)
            } else if others.count < limit {
                others.append(candidate)
            }
            if standard.count == limit {
                break
            }
        }
        // Some apps report no subrole at all; fall back to everything with a
        // resolvable window ID rather than showing an empty panel. Preserve the
        // existing creation-order selection, but read title/minimized metadata
        // only for the windows the UI will actually render.
        return (standard.isEmpty ? others : standard)
            .sorted { $0.windowID < $1.windowID }
            .prefix(limit)
            .map { candidate in
                DockAXWindowResolution(
                    snapshot: DockAXWindow(
                        windowID: candidate.windowID,
                        title: stringAttribute(
                            candidate.element,
                            kAXTitleAttribute as CFString
                        ),
                        isMinimized: boolAttribute(
                            candidate.element,
                            kAXMinimizedAttribute as CFString
                        ) ?? false
                    ),
                    element: candidate.element
                )
            }
    }

    /// Focuses one specific window: un-minimize if needed, raise, mark main.
    @discardableResult
    static func raise(_ window: DockAXWindowResolution) -> Bool {
        guard AccessibilityPermission.isTrusted else { return false }
        AXUIElementSetMessagingTimeout(window.element, applicationTimeout)
        if window.snapshot.isMinimized,
           AXUIElementSetAttributeValue(
               window.element,
               kAXMinimizedAttribute as CFString,
               kCFBooleanFalse
           ) != .success {
            return false
        }
        guard AXUIElementPerformAction(
            window.element,
            kAXRaiseAction as CFString
        ) == .success else { return false }
        _ = AXUIElementSetAttributeValue(
            window.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        return true
    }

    /// Presses the window's real close button. This intentionally does not
    /// terminate the owning process or synthesize Command-W: applications keep
    /// their ordinary unsaved-document confirmation and close veto behavior.
    @discardableResult
    static func close(_ window: DockAXWindowResolution) -> Bool {
        guard AccessibilityPermission.isTrusted else { return false }
        AXUIElementSetMessagingTimeout(window.element, applicationTimeout)
        guard let closeButton = elementAttribute(
            window.element,
            kAXCloseButtonAttribute as CFString
        ) else {
            return false
        }
        AXUIElementSetMessagingTimeout(closeButton, windowTimeout)
        return AXUIElementPerformAction(
            closeButton,
            kAXPressAction as CFString
        ) == .success
    }

    private static func appTarget(
        from element: AXUIElement,
        pointer: CGPoint,
        runningApplications: [DockRunningApplication]
    ) -> DockAppTarget? {
        let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let url = urlAttribute(element, kAXURLAttribute as CFString)
        let bundleIdentifier = url.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let application = runningApplications.first {
            bundleIdentifier != nil && $0.bundleIdentifier == bundleIdentifier
        } ?? runningApplications.first {
            $0.appName.localizedCaseInsensitiveCompare(title) == .orderedSame
        }
        guard let application else { return nil }
        return DockAppTarget(
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            appName: application.appName,
            pointerLocation: pointer
        )
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func urlAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
