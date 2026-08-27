import AppKit

/// Sendable Window Server metadata used while Accessibility validates
/// candidates away from the main actor. AppKit images are attached only when
/// the descriptor becomes a `SwitcherWindow` on the main actor.
struct SwitcherWindowDescriptor: Identifiable, Sendable {
    let id: CGWindowID
    let processIdentifier: pid_t
    let appName: String
    let title: String
    let aspectRatio: CGFloat
}

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
    private struct AXValidation: Sendable {
        let processIdentifier: pid_t
        let windows: [DockAXWindow]
    }

    /// Fast first pass used to present the switcher without waiting on AX.
    static func currentWindows(excluding selfPID: pid_t) -> [SwitcherWindowDescriptor] {
        candidates(
            options: [.optionOnScreenOnly, .excludeDesktopElements],
            excluding: selfPID
        )
    }

    /// Window Server's complete candidate set, including other Spaces and
    /// minimized windows. This intentionally still contains helper windows;
    /// `switchableWindows` removes them using the application's AX tree.
    static func allCandidates(excluding selfPID: pid_t) -> [SwitcherWindowDescriptor] {
        candidates(options: [.excludeDesktopElements], excluding: selfPID)
    }

    /// Keeps the fast on-screen ordering, removes visible helper windows when
    /// AX for that app answers successfully, and appends only off-screen
    /// candidates identified as real standard (or minimized) windows. This
    /// function is safe to run away from the main actor.
    static func switchableWindows(
        onScreenWindows: [SwitcherWindowDescriptor],
        allCandidates: [SwitcherWindowDescriptor]
    ) async -> [SwitcherWindowDescriptor] {
        let onScreenIDs = Set(onScreenWindows.map(\.id))
        let offScreen = allCandidates.filter { !onScreenIDs.contains($0.id) }
        let grouped = Dictionary(grouping: allCandidates, by: \.processIdentifier)

        // AX servers are isolated per process. Validate apps concurrently so a
        // slow/unresponsive app cannot delay a healthy Chrome profile behind
        // several serial timeout budgets while the modifier is being held.
        let validations = await withTaskGroup(of: AXValidation.self) { group in
            for (pid, candidates) in grouped {
                let candidateIDs = Set(candidates.map(\.id))
                group.addTask {
                    AXValidation(
                        processIdentifier: pid,
                        windows: DockAXResolver.switchableWindows(
                            processIdentifier: pid,
                            matching: candidateIDs
                        )
                    )
                }
            }
            var results: [AXValidation] = []
            for await validation in group { results.append(validation) }
            return results
        }
        let matches = validations.flatMap(\.windows)
        let matchesByPID = Dictionary(
            uniqueKeysWithValues: validations.map {
                ($0.processIdentifier, $0.windows)
            }
        )
        let axWindowsByID = Dictionary(
            uniqueKeysWithValues: matches.map { ($0.windowID, $0) }
        )

        let validatedOnScreen = onScreenWindows.compactMap {
            candidate -> SwitcherWindowDescriptor? in
            // An empty result can mean an app's AX server timed out. Keep its
            // on-screen Window Server entries as a fail-soft fallback; never
            // apply that fallback to off-screen candidates.
            guard let appMatches = matchesByPID[candidate.processIdentifier],
                  !appMatches.isEmpty else { return candidate }
            guard let axWindow = axWindowsByID[candidate.id] else { return nil }
            return descriptor(candidate, axWindow: axWindow)
        }
        let extras = offScreen.compactMap { candidate -> SwitcherWindowDescriptor? in
            guard let axWindow = axWindowsByID[candidate.id] else { return nil }
            return descriptor(candidate, axWindow: axWindow)
        }
        return validatedOnScreen + extras
    }

    private static func descriptor(
        _ candidate: SwitcherWindowDescriptor,
        axWindow: DockAXWindow
    ) -> SwitcherWindowDescriptor {
        SwitcherWindowDescriptor(
            id: candidate.id,
            processIdentifier: candidate.processIdentifier,
            appName: candidate.appName,
            title: candidate.title.isEmpty ? (axWindow.title ?? "") : candidate.title,
            aspectRatio: candidate.aspectRatio
        )
    }

    private static func candidates(
        options: CGWindowListOption,
        excluding selfPID: pid_t
    ) -> [SwitcherWindowDescriptor] {
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [] }

        var appCache: [pid_t: NSRunningApplication?] = [:]
        var windows: [SwitcherWindowDescriptor] = []
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
            windows.append(SwitcherWindowDescriptor(
                id: windowID,
                processIdentifier: pid,
                appName: appName,
                title: title,
                aspectRatio: aspect
            ))
        }
        return windows
    }
}
