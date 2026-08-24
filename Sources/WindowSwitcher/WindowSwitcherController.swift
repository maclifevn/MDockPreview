import AppKit

/// Orchestrates the ⌥Tab window switcher: owns the hotkey tap and the panel,
/// builds the window list on demand, fills thumbnails asynchronously, and raises
/// the chosen window on commit. Reuses `DockAXWorker` for the AX raise.
@MainActor
final class WindowSwitcherController {
    private let settings: AppSettings
    private let panel = SwitcherPanelController()
    private let axWorker = DockAXWorker()
    private var hotkey: SwitcherHotkeyMonitor?
    private var active = false
    private var captureTask: Task<Void, Never>?

    /// Notifies when the switcher opens/closes so the Dock preview can suspend.
    var onActiveChanged: ((Bool) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func applySettings() {
        if settings.windowSwitcherEnabled { start() } else { stop() }
    }

    func stop() {
        hotkey?.stop()
        hotkey = nil
        hide()
    }

    private func start() {
        guard hotkey == nil else { return }
        let monitor = SwitcherHotkeyMonitor(
            onStep: { [weak self] forward in self?.step(forward: forward) },
            onCommit: { [weak self] in self?.commit() },
            onCancel: { [weak self] in self?.cancel() }
        )
        hotkey = monitor
        monitor.start()
    }

    // MARK: - Hotkey actions (main actor)

    private func step(forward: Bool) {
        if active { advance(forward: forward) } else { present(forward: forward) }
    }

    private func present(forward: Bool) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let windows = SwitcherWindowLister.currentWindows(excluding: selfPID)
        guard !windows.isEmpty else { return }

        panel.model.windows = windows
        let count = windows.count
        // Alt-Tab lands on the previous window first, not the current one.
        panel.model.selectedIndex = count > 1 ? (forward ? 1 : count - 1) : 0

        active = true
        onActiveChanged?(true)
        panel.show(on: screenForSwitcher())
        startCapturing()
    }

    private func advance(forward: Bool) {
        let count = panel.model.windows.count
        guard count > 0 else { return }
        let current = panel.model.selectedIndex
        panel.model.selectedIndex = ((current + (forward ? 1 : -1)) % count + count) % count
    }

    private func commit() {
        guard active else { return }
        let index = panel.model.selectedIndex
        if panel.model.windows.indices.contains(index) {
            let window = panel.model.windows[index]
            let pid = window.processIdentifier
            let windowID = window.id
            axWorker.submitRaise(processIdentifier: pid, windowID: windowID) {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            }
        }
        hide()
    }

    private func cancel() {
        hide()
    }

    private func hide() {
        guard active else { return }
        active = false
        captureTask?.cancel()
        captureTask = nil
        panel.hide()
        onActiveChanged?(false)
    }

    // MARK: - Thumbnails

    private func startCapturing() {
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let shareable = await SwitcherThumbnailer.shareableWindows()
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

    /// Capture the highlighted tile first so it looks instant, then the rest.
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
