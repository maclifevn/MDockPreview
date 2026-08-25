import AppKit

/// One switchable window in the Alt-Tab-style window switcher.
struct SwitcherWindow: Identifiable {
    let id: CGWindowID
    let processIdentifier: pid_t
    let appName: String
    let appIcon: NSImage?
    let title: String
    var thumbnail: CGImage?
    let aspectRatio: CGFloat

    var displayTitle: String { title.isEmpty ? appName : title }
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selectedIndex: Int = 0
    @Published var columns: Int = 1

    /// Clicking a tile (and Return in custom mode) selects that index.
    var onSelectIndex: ((Int) -> Void)?

    var selectedAppName: String {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex].appName : ""
    }
    var selectedTitle: String {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex].displayTitle : ""
    }
}

/// Builds the ordered window list straight from the window server. CGWindowList
/// returns windows front-to-back, which approximates most-recently-used order,
/// so the second entry is the window Alt-Tab should land on first. Filters to
/// real, regular-app windows and drops our own panels.
enum SwitcherWindowLister {
    static func currentWindows(excluding selfPID: pid_t) -> [SwitcherWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [] }

        var appCache: [pid_t: NSRunningApplication?] = [:]
        var windows: [SwitcherWindow] = []
        var seen = Set<CGWindowID>()

        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let idInt = info[kCGWindowNumber as String] as? Int,
                  let pidInt = info[kCGWindowOwnerPID as String] as? Int else { continue }
            let windowID = CGWindowID(idInt)
            let pid = pid_t(pidInt)
            guard pid != selfPID, !seen.contains(windowID) else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= 80, frame.height >= 60 else { continue }

            let app: NSRunningApplication?
            if let cached = appCache[pid] {
                app = cached
            } else {
                let resolved = NSRunningApplication(processIdentifier: pid)
                appCache[pid] = resolved
                app = resolved
            }
            guard let app, app.activationPolicy == .regular else { continue }

            let appName = app.localizedName
                ?? (info[kCGWindowOwnerName as String] as? String ?? "")
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let aspect = frame.height > 0 ? frame.width / frame.height : 1.6

            seen.insert(windowID)
            windows.append(SwitcherWindow(
                id: windowID,
                processIdentifier: pid,
                appName: appName,
                appIcon: app.icon,
                title: title,
                thumbnail: nil,
                aspectRatio: aspect
            ))
        }
        return windows
    }
}
