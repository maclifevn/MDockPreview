import AppKit
import os

/// Orchestrates the window switcher: a held modifier (⌘/⌥/⌃) + Tab opens a
/// centered grid of live thumbnails; Tab/Shift+Tab cycles; releasing the
/// modifier raises the selection. A tile can also be clicked. Reuses the theme
/// store, ScreenCaptureKit thumbnailing, and `DockAXWorker` raise.
@MainActor
final class WindowSwitcherController {
    private static let log = Logger(
        subsystem: "com.maclife.mdockpreview",
        category: "window-switcher"
    )

    private let settings: AppSettings
    private let panel = SwitcherPanelController()
    private let axWorker = DockAXWorker()
    private var hotkey: SwitcherHotkeyMonitor?
    private var active = false
    private var captureTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryGeneration: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var cachedOffScreenWindows: [SwitcherWindowDescriptor] = []

    /// Notifies when the switcher opens/closes so the Dock preview can suspend.
    var onActiveChanged: ((Bool) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        panel.model.onSelectIndex = { [weak self] index in self?.select(index: index) }
    }

    /// Rebuilds the hotkey tap so a changed shortcut (⌘/⌥/⌃) takes effect.
    func applySettings() {
        hotkey?.stop()
        hotkey = nil
        hide()
        guard settings.windowSwitcherEnabled else { return }
        let monitor = SwitcherHotkeyMonitor(
            modifier: settings.switcherModifier.flag,
            onStep: { [weak self] forward in self?.step(forward: forward) },
            onCommit: { [weak self] in self?.commit() },
            onCancel: { [weak self] in self?.cancel() }
        )
        hotkey = monitor
        monitor.start()
    }

    func stop() {
        hotkey?.stop()
        hotkey = nil
        hide()
    }

    // MARK: - Actions

    private func step(forward: Bool) {
        if active { advance(forward: forward) } else { present(forward: forward) }
    }

    private func present(forward: Bool) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let onScreen = SwitcherWindowLister.currentWindows(excluding: selfPID)
        let allCandidates = SwitcherWindowLister.allCandidates(excluding: selfPID)
        let initialDescriptors = windowsUsingCache(
            onScreen: onScreen,
            allCandidates: allCandidates
        )
        guard !initialDescriptors.isEmpty else { return }
        let windows = makeWindows(from: initialDescriptors)

        panel.model.windows = windows
        let count = windows.count
        // Land on the previous window first, like a native switcher.
        panel.model.selectedIndex = count > 1 ? (forward ? 1 : count - 1) : 0

        active = true
        onActiveChanged?(true)
        panel.show(on: screenForSwitcher())
        startCapturing(onScreenOnly: initialDescriptors.count == onScreen.count)

        discoveryGeneration &+= 1
        startExtendedDiscovery(
            onScreen: onScreen,
            allCandidates: allCandidates,
            generation: discoveryGeneration
        )
    }

    private func advance(forward: Bool) {
        let count = panel.model.windows.count
        guard count > 0 else { return }
        let current = panel.model.selectedIndex
        panel.model.selectedIndex = ((current + (forward ? 1 : -1)) % count + count) % count
    }

    private func select(index: Int) {
        guard active, panel.model.windows.indices.contains(index) else { return }
        panel.model.selectedIndex = index
        commit()
    }

    private func commit() {
        guard active else { return }
        let index = panel.model.selectedIndex
        if panel.model.windows.indices.contains(index) {
            let window = panel.model.windows[index]
            let pid = window.processIdentifier
            let windowID = window.id
            axWorker.submitRaise(processIdentifier: pid, windowID: windowID) { raised in
                let activated = NSRunningApplication(processIdentifier: pid)?
                    .activate(options: []) ?? false
                if !raised || !activated {
                    Self.log.error(
                        "Window selection incomplete pid=\(pid) window=\(windowID) raised=\(raised) activated=\(activated)"
                    )
                }
            }
        }
        hide()
    }

    private func cancel() { hide() }

    private func hide() {
        discoveryGeneration &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        captureTask?.cancel()
        captureTask = nil
        guard active else { return }
        active = false
        panel.hide()
        onActiveChanged?(false)
    }

    // MARK: - Window discovery

    private func startExtendedDiscovery(
        onScreen: [SwitcherWindowDescriptor],
        allCandidates: [SwitcherWindowDescriptor],
        generation: UInt64
    ) {
        discoveryTask?.cancel()
        discoveryTask = Task { @MainActor [weak self] in
            let descriptors = await Task.detached(priority: .userInitiated) {
                await SwitcherWindowLister.switchableWindows(
                    onScreenWindows: onScreen,
                    allCandidates: allCandidates
                )
            }.value

            guard let self else { return }
            let onScreenIDs = Set(onScreen.map(\.id))
            self.updateDiscoveryCache(
                with: descriptors.filter { !onScreenIDs.contains($0.id) },
                allCandidates: allCandidates,
                generation: generation
            )

            guard !Task.isCancelled,
                  self.active,
                  self.discoveryGeneration == generation else { return }
            guard !descriptors.isEmpty else {
                self.hide()
                return
            }

            let existingIDs = self.panel.model.windows.map(\.id)
            guard descriptors.map(\.id) != existingIDs else { return }

            let selectedID = self.panel.model.windows.indices
                .contains(self.panel.model.selectedIndex)
                ? self.panel.model.windows[self.panel.model.selectedIndex].id
                : nil
            let thumbnails = Dictionary(
                uniqueKeysWithValues: self.panel.model.windows.compactMap { window in
                    window.thumbnail.map { (window.id, $0) }
                }
            )
            self.panel.model.windows = self.makeWindows(
                from: descriptors,
                thumbnails: thumbnails
            )
            if let selectedID,
               let selectedIndex = descriptors.firstIndex(where: { $0.id == selectedID }) {
                self.panel.model.selectedIndex = selectedIndex
            } else {
                self.panel.model.selectedIndex = min(
                    self.panel.model.selectedIndex,
                    max(0, descriptors.count - 1)
                )
            }

            self.panel.show(on: self.screenForSwitcher())
            self.startCapturing(onScreenOnly: false)
        }
    }

    /// Reuses windows that AX has already validated so a quick press/release
    /// still includes other Spaces on subsequent invocations. The current
    /// Window Server snapshot removes cache entries as soon as their ID/PID no
    /// longer exists.
    private func windowsUsingCache(
        onScreen: [SwitcherWindowDescriptor],
        allCandidates: [SwitcherWindowDescriptor]
    ) -> [SwitcherWindowDescriptor] {
        let onScreenIDs = Set(onScreen.map(\.id))
        let currentByID = Dictionary(
            uniqueKeysWithValues: allCandidates.map { ($0.id, $0) }
        )
        let cached = cachedOffScreenWindows.compactMap { old -> SwitcherWindowDescriptor? in
            guard !onScreenIDs.contains(old.id),
                  let current = currentByID[old.id],
                  current.processIdentifier == old.processIdentifier else { return nil }
            return descriptor(current, usingTitleFrom: old)
        }
        return onScreen + cached
    }

    private func updateDiscoveryCache(
        with fresh: [SwitcherWindowDescriptor],
        allCandidates: [SwitcherWindowDescriptor],
        generation: UInt64
    ) {
        guard generation >= cacheGeneration else { return }
        let currentByID = Dictionary(
            uniqueKeysWithValues: allCandidates.map { ($0.id, $0) }
        )
        var merged = fresh
        var seen = Set(fresh.map(\.id))
        for old in cachedOffScreenWindows where !seen.contains(old.id) {
            guard let current = currentByID[old.id],
                  current.processIdentifier == old.processIdentifier else { continue }
            merged.append(descriptor(current, usingTitleFrom: old))
            seen.insert(old.id)
        }
        cachedOffScreenWindows = merged
        cacheGeneration = generation
    }

    private func descriptor(
        _ current: SwitcherWindowDescriptor,
        usingTitleFrom cached: SwitcherWindowDescriptor
    ) -> SwitcherWindowDescriptor {
        SwitcherWindowDescriptor(
            id: current.id,
            processIdentifier: current.processIdentifier,
            appName: current.appName,
            title: current.title.isEmpty ? cached.title : current.title,
            aspectRatio: current.aspectRatio
        )
    }

    private func makeWindows(
        from descriptors: [SwitcherWindowDescriptor],
        thumbnails: [CGWindowID: CGImage] = [:]
    ) -> [SwitcherWindow] {
        var iconCache: [pid_t: NSImage] = [:]
        return descriptors.map { descriptor in
            let icon: NSImage?
            if let cached = iconCache[descriptor.processIdentifier] {
                icon = cached
            } else {
                icon = NSRunningApplication(
                    processIdentifier: descriptor.processIdentifier
                )?.icon
                if let icon { iconCache[descriptor.processIdentifier] = icon }
            }
            return SwitcherWindow(
                id: descriptor.id,
                processIdentifier: descriptor.processIdentifier,
                appName: descriptor.appName,
                appIcon: icon,
                title: descriptor.title,
                thumbnail: thumbnails[descriptor.id],
                aspectRatio: descriptor.aspectRatio
            )
        }
    }

    // MARK: - Thumbnails

    private func startCapturing(onScreenOnly: Bool) {
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let shareable = await SwitcherThumbnailer.shareableWindows(
                onScreenOnly: onScreenOnly
            )
            if Task.isCancelled { return }
            for index in self.captureOrder() {
                if Task.isCancelled { return }
                guard self.panel.model.windows.indices.contains(index) else { continue }
                let window = self.panel.model.windows[index]
                guard let scWindow = shareable[window.id] else { continue }
                let image = await SwitcherThumbnailer.capture(scWindow)
                if Task.isCancelled { return }
                if let image,
                   self.panel.model.windows.indices.contains(index),
                   self.panel.model.windows[index].id == window.id {
                    self.panel.model.windows[index].thumbnail = image
                }
            }
        }
    }

    private func captureOrder() -> [Int] {
        let count = panel.model.windows.count
        let selected = panel.model.selectedIndex
        var order: [Int] = []
        if panel.model.windows.indices.contains(selected) { order.append(selected) }
        order.append(contentsOf: (0..<count).filter { $0 != selected })
        return order
    }

    private func screenForSwitcher() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
