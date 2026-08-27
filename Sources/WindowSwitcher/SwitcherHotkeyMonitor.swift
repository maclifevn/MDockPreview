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

    private let modifierFlag: CGEventFlags
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
    private var modifierDown = false
    private var engaged = false

    private let tabKeyCode: Int64 = 48
    private let escKeyCode: Int64 = 53

    init(
        modifier: CGEventFlags,
        onStep: @escaping @MainActor @Sendable (Bool) -> Void,
        onCommit: @escaping @MainActor @Sendable () -> Void,
        onCancel: @escaping @MainActor @Sendable () -> Void
    ) {
        self.modifierFlag = modifier
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
        // `stop()` can race the worker before it publishes its run loop. Mark
        // this instance terminal so a late-starting worker cannot install a
        // ghost event tap after the controller has already replaced it.
        terminated = true
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
                lock.lock()
                thread = nil
                lock.unlock()
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
            guard go else {
                lock.lock()
                eventTap = nil
                runLoopSource = nil
                eventRunLoop = nil
                lock.unlock()
                return
            }

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
            let shouldCancel = engaged
            engaged = false
            modifierDown = false
            if shouldCancel {
                let cancel = onCancel
                dispatchToMain { cancel() }
            }
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let nowModifier = event.flags.contains(modifierFlag)
            if modifierDown, !nowModifier, engaged {
                engaged = false
                let commit = onCommit
                dispatchToMain { commit() }
            }
            modifierDown = nowModifier
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == tabKeyCode, event.flags.contains(modifierFlag) {
                let forward = !event.flags.contains(.maskShift)
                engaged = true
                modifierDown = true
                let step = onStep
                dispatchToMain { step(forward) }
                return nil
            }
            if code == escKeyCode, engaged {
                engaged = false
                let cancel = onCancel
                dispatchToMain { cancel() }
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

    /// GCD preserves submission order from the event-tap thread. That matters
    /// for a fast press-and-release: the initial step must reach the main actor
    /// before the modifier-release commit, or the commit sees no active panel
    /// and the later step leaves it stuck open.
    private func dispatchToMain(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isActive = !self.terminated
            self.lock.unlock()
            guard isActive else { return }
            action()
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
