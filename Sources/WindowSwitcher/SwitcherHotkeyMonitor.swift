import CoreGraphics
import Foundation
import os

/// A global keyboard event tap that implements the ⌥Tab window switcher:
/// while Option is held, Tab steps the selection forward (Shift+Tab backward),
/// releasing Option commits, and Esc cancels. Tab is consumed while engaged so
/// the keystroke never leaks to the focused app. Requires Accessibility.
final class SwitcherHotkeyMonitor: @unchecked Sendable {
    private static let log = Logger(
        subsystem: "com.maclife.mdockpreview",
        category: "switcher-hotkey"
    )

    private let onStep: @MainActor @Sendable (Bool) -> Void
    private let onCommit: @MainActor @Sendable () -> Void
    private let onCancel: @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var thread: Thread?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventRunLoop: CFRunLoop?
    private var terminated = false

    // Touched only on the tap thread.
    private var optionDown = false
    private var engaged = false

    private let tabKeyCode: Int64 = 48
    private let escKeyCode: Int64 = 53

    init(
        onStep: @escaping @MainActor @Sendable (Bool) -> Void,
        onCommit: @escaping @MainActor @Sendable () -> Void,
        onCancel: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onStep = onStep
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func start() {
        lock.lock()
        guard thread == nil, !terminated else { lock.unlock(); return }
        let worker = Thread { [weak self] in self?.runEventLoop() }
        worker.name = "MDockPreview.SwitcherHotkey"
        thread = worker
        lock.unlock()
        worker.start()
    }

    func stop() {
        var runLoop: CFRunLoop?
        var tap: CFMachPort?
        lock.lock()
        runLoop = eventRunLoop
        tap = eventTap
        thread = nil
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop); CFRunLoopWakeUp(runLoop) }
    }

    private func runEventLoop() {
        autoreleasepool {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: switcherEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                Self.log.error("Could not create switcher key event tap")
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let runLoop = CFRunLoopGetCurrent()
            lock.lock()
            eventTap = tap
            runLoopSource = source
            eventRunLoop = runLoop
            let go = !terminated
            lock.unlock()
            guard go else { return }

            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            lock.lock()
            eventTap = nil
            runLoopSource = nil
            eventRunLoop = nil
            lock.unlock()
        }
    }

    /// Runs on the tap thread. Returns `nil` to swallow an event.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let nowOption = event.flags.contains(.maskAlternate)
            if optionDown, !nowOption, engaged {
                engaged = false
                let commit = onCommit
                Task { @MainActor in commit() }
            }
            optionDown = nowOption
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == tabKeyCode, event.flags.contains(.maskAlternate) {
                let forward = !event.flags.contains(.maskShift)
                engaged = true
                optionDown = true
                let step = onStep
                Task { @MainActor in step(forward) }
                return nil
            }
            if code == escKeyCode, engaged {
                engaged = false
                let cancel = onCancel
                Task { @MainActor in cancel() }
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == tabKeyCode, engaged { return nil }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func switcherEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<SwitcherHotkeyMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
