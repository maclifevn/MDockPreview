import AppKit
import CoreGraphics
import Foundation
import os

struct DockPointerScreen: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
}

enum DockPointerRegion: Equatable, Sendable {
    case dock
    case panel
    case outside
}

struct DockPointerEvent: Equatable, Sendable {
    let sequence: UInt64
    let region: DockPointerRegion
    let appKitPoint: CGPoint
    let quartzPoint: CGPoint
}

struct DockHoverSample: Equatable, Sendable {
    let appKitPoint: CGPoint
    let quartzPoint: CGPoint
}

/// Fixed-cadence, latest-wins sampling for Dock hover events.
///
/// The first movement arms one deadline. Later movement updates only the
/// position that will be sampled, so trackpad jitter cannot postpone hover
/// indefinitely. After a sample, tiny displacement from the emitted point is
/// ignored to keep hardware jitter from generating a steady stream of AX work.
struct DockHoverSampler {
    private let sampleInterval: CFTimeInterval
    private let minimumDisplacementSquared: CGFloat
    private(set) var deadline: CFAbsoluteTime?
    private var latestSample: DockHoverSample?
    private var lastEmittedPoint: CGPoint?

    init(
        sampleInterval: CFTimeInterval,
        minimumDisplacement: CGFloat
    ) {
        self.sampleInterval = sampleInterval
        minimumDisplacementSquared =
            minimumDisplacement * minimumDisplacement
    }

    mutating func record(
        appKitPoint: CGPoint,
        quartzPoint: CGPoint,
        now: CFAbsoluteTime
    ) -> CFAbsoluteTime? {
        let sample = DockHoverSample(
            appKitPoint: appKitPoint,
            quartzPoint: quartzPoint
        )
        if deadline != nil {
            latestSample = sample
            return nil
        }
        if let lastEmittedPoint {
            let dx = appKitPoint.x - lastEmittedPoint.x
            let dy = appKitPoint.y - lastEmittedPoint.y
            guard (dx * dx) + (dy * dy) >= minimumDisplacementSquared else {
                latestSample = nil
                return nil
            }
        }

        latestSample = sample
        let deadline = now + sampleInterval
        self.deadline = deadline
        return deadline
    }

    mutating func consumeLatest() -> DockHoverSample? {
        guard deadline != nil, let latestSample else {
            deadline = nil
            self.latestSample = nil
            return nil
        }
        deadline = nil
        self.latestSample = nil
        lastEmittedPoint = latestSample.appKitPoint
        return latestSample
    }

    mutating func reset() {
        deadline = nil
        latestSample = nil
        lastEmittedPoint = nil
    }
}

/// Observes mouse movement without putting it on AppKit's main event path.
///
/// A physical mouse can generate hundreds of events per second. Installing
/// `NSEvent` monitors for those events makes MDock Preview participate in every
/// main-thread menu-tracking iteration, even when the pointer is nowhere near
/// the Dock. This listen-only event tap lives on its own run loop instead.
///
/// Dock hit-testing is deliberately cadence-limited: the first movement arms
/// one persistent timer, while later movement only replaces the sampled
/// position. Region transitions are still emitted immediately so moving from
/// the Dock into the preview cancels its hide timer.
final class DockPointerMonitor: @unchecked Sendable {
    typealias MoveHandler = @MainActor @Sendable (DockPointerEvent) -> Void

    private static let log = Logger(
        subsystem: "com.maclife.mdockpreview",
        category: "dock-pointer"
    )
    private static let hoverSampleInterval: CFTimeInterval = 0.08
    private static let minimumHoverDisplacement: CGFloat = 3
    /// A positive interval keeps the CF timer valid after it fires. The timer
    /// is explicitly parked after every callback, and this long repeat period
    /// is a fail-safe against an accidental probe loop.
    private static let reusableTimerInterval: CFTimeInterval = 24 * 60 * 60
    private static let dormantTimerDate = CFAbsoluteTime.greatestFiniteMagnitude

    private let moveHandler: MoveHandler
    private let installsEventTap: Bool
    private let lock = NSLock()

    private var screens: [DockPointerScreen] = []
    private var primaryDisplayHeight: CGFloat = 0
    private var panelFrame: CGRect?
    private var probeGate = DockProbeGate()
    private var hoverSampler = DockHoverSampler(
        sampleInterval: DockPointerMonitor.hoverSampleInterval,
        minimumDisplacement: DockPointerMonitor.minimumHoverDisplacement
    )
    private var currentRegion = DockPointerRegion.outside
    private var sequence: UInt64 = 0
    private var isEnabled = false
    private var isSuspended = false
    private var isTerminated = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dwellTimer: CFRunLoopTimer?
    private var eventRunLoop: CFRunLoop?
    private var eventThread: Thread?

    init(
        installsEventTap: Bool = true,
        onMove: @escaping MoveHandler
    ) {
        self.installsEventTap = installsEventTap
        moveHandler = onMove
    }

    deinit {
        shutdown()
    }

    func start(
        screens: [DockPointerScreen],
        primaryDisplayHeight: CGFloat
    ) {
        var threadToStart: Thread?
        var tapToEnable: CFMachPort?
        lock.lock()
        self.screens = screens
        self.primaryDisplayHeight = primaryDisplayHeight
        isEnabled = true
        isSuspended = false
        isTerminated = false
        probeGate.reset()
        hoverSampler.reset()
        currentRegion = .outside
        if installsEventTap, eventThread == nil {
            let thread = Thread { [weak self] in
                self?.runEventLoop()
            }
            thread.name = "MDock Preview Dock Pointer"
            thread.qualityOfService = .userInteractive
            eventThread = thread
            threadToStart = thread
        } else {
            tapToEnable = eventTap
        }
        lock.unlock()
        if let tapToEnable {
            CGEvent.tapEnable(tap: tapToEnable, enable: true)
        }
        threadToStart?.start()
    }

    func stop() {
        var tapToDisable: CFMachPort?
        lock.lock()
        isEnabled = false
        isSuspended = false
        resetLocked()
        tapToDisable = eventTap
        lock.unlock()
        if let tapToDisable {
            CGEvent.tapEnable(tap: tapToDisable, enable: false)
        }
    }

    func setSuspended(_ suspended: Bool) {
        var tap: CFMachPort?
        var shouldEnable = false
        lock.lock()
        isSuspended = suspended
        if suspended {
            resetLocked()
        }
        tap = eventTap
        shouldEnable = isEnabled && !suspended
        lock.unlock()
        if let tap {
            // During NSMenu tracking even the background callback is disabled,
            // not merely ignored. The menu's main run loop receives no work
            // originating from Dock Preview until tracking has ended.
            CGEvent.tapEnable(tap: tap, enable: shouldEnable)
        }
    }

    func updateScreens(
        _ screens: [DockPointerScreen],
        primaryDisplayHeight: CGFloat
    ) {
        lock.lock()
        self.screens = screens
        self.primaryDisplayHeight = primaryDisplayHeight
        probeGate.reset()
        hoverSampler.reset()
        currentRegion = .outside
        setDwellTimerLocked(Self.dormantTimerDate)
        lock.unlock()
    }

    func updatePanelFrame(_ frame: CGRect?) {
        lock.lock()
        panelFrame = frame
        lock.unlock()
    }

    private func shutdown() {
        var runLoop: CFRunLoop?
        var tap: CFMachPort?
        lock.lock()
        isEnabled = false
        isTerminated = true
        resetLocked()
        runLoop = eventRunLoop
        tap = eventTap
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func runEventLoop() {
        autoreleasepool {
            let eventMask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: dockPointerEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                Self.log.error("Could not create listen-only mouse event tap")
                lock.lock()
                eventThread = nil
                isEnabled = false
                lock.unlock()
                return
            }

            let source = CFMachPortCreateRunLoopSource(
                kCFAllocatorDefault,
                tap,
                0
            )
            guard let timer = Self.makeReusableDwellTimer(
                info: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                Self.log.error("Could not create Dock hover dwell timer")
                lock.lock()
                eventThread = nil
                isEnabled = false
                lock.unlock()
                return
            }

            let runLoop = CFRunLoopGetCurrent()
            lock.lock()
            let shouldRun = !isTerminated
            let shouldEnable = isEnabled && !isSuspended
            if shouldRun {
                eventTap = tap
                runLoopSource = source
                dwellTimer = timer
                eventRunLoop = runLoop
            }
            lock.unlock()
            guard shouldRun else { return }

            CFRunLoopAddSource(runLoop, source, .commonModes)
            CFRunLoopAddTimer(runLoop, timer, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: shouldEnable)
            CFRunLoopRun()

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveTimer(runLoop, timer, .commonModes)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            lock.lock()
            eventTap = nil
            runLoopSource = nil
            dwellTimer = nil
            eventRunLoop = nil
            eventThread = nil
            lock.unlock()
        }
    }

    func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            let shouldEnable = isEnabled && !isSuspended && !isTerminated
            lock.unlock()
            if shouldEnable, let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let quartzPoint = event.location
        var emittedMove: DockPointerEvent?

        lock.lock()
        guard isEnabled, !isSuspended, !isTerminated else {
            lock.unlock()
            return
        }
        let appKitPoint = CGPoint(
            x: quartzPoint.x,
            y: primaryDisplayHeight - quartzPoint.y
        )
        let region = classifyLocked(appKitPoint)

        switch type {
        case .mouseMoved:
            switch region {
            case .dock:
                if let deadline = hoverSampler.record(
                    appKitPoint: appKitPoint,
                    quartzPoint: quartzPoint,
                    now: CFAbsoluteTimeGetCurrent()
                ) {
                    setDwellTimerLocked(deadline)
                }
            case .panel, .outside:
                hoverSampler.reset()
                setDwellTimerLocked(Self.dormantTimerDate)
                if region != currentRegion {
                    emittedMove = makeEventLocked(
                        region: region,
                        appKitPoint: appKitPoint,
                        quartzPoint: quartzPoint
                    )
                }
            }
            currentRegion = region

        default:
            break
        }
        lock.unlock()

        if let emittedMove {
            emitMove(emittedMove)
        }
    }

    func dwellTimerFired() {
        var event: DockPointerEvent?
        lock.lock()
        let sample = hoverSampler.consumeLatest()
        if isEnabled,
           !isSuspended,
           !isTerminated,
           currentRegion == .dock,
           let sample {
            event = makeEventLocked(
                region: .dock,
                appKitPoint: sample.appKitPoint,
                quartzPoint: sample.quartzPoint
            )
        }
        setDwellTimerLocked(Self.dormantTimerDate)
        lock.unlock()

        if let event {
            emitMove(event)
        }
    }

    private func classifyLocked(_ point: CGPoint) -> DockPointerRegion {
        if panelFrame?.insetBy(dx: -8, dy: -8).contains(point) == true {
            return .panel
        }
        guard let screen = screens.first(where: { $0.frame.contains(point) })
            ?? screens.first,
              probeGate.allowsProbe(
                  at: point,
                  screenFrame: screen.frame,
                  visibleFrame: screen.visibleFrame
              ) else {
            return .outside
        }
        return .dock
    }

    private func makeEventLocked(
        region: DockPointerRegion,
        appKitPoint: CGPoint,
        quartzPoint: CGPoint
    ) -> DockPointerEvent {
        sequence &+= 1
        return DockPointerEvent(
            sequence: sequence,
            region: region,
            appKitPoint: appKitPoint,
            quartzPoint: quartzPoint
        )
    }

    private func resetLocked() {
        probeGate.reset()
        hoverSampler.reset()
        currentRegion = .outside
        panelFrame = nil
        setDwellTimerLocked(Self.dormantTimerDate)
    }

    private func setDwellTimerLocked(_ date: CFAbsoluteTime) {
        guard let dwellTimer else { return }
        CFRunLoopTimerSetNextFireDate(dwellTimer, date)
    }

    private func emitMove(_ event: DockPointerEvent) {
        let moveHandler = moveHandler
        Task { @MainActor in
            moveHandler(event)
        }
    }

    static func makeReusableDwellTimer(
        info: UnsafeMutableRawPointer
    ) -> CFRunLoopTimer? {
        var timerContext = CFRunLoopTimerContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        return CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            dormantTimerDate,
            reusableTimerInterval,
            0,
            0,
            dockPointerDwellTimerCallback,
            &timerContext
        )
    }
}

private func dockPointerEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<DockPointerMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    monitor.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private func dockPointerDwellTimerCallback(
    timer: CFRunLoopTimer?,
    info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let monitor = Unmanaged<DockPointerMonitor>
        .fromOpaque(info)
        .takeUnretainedValue()
    monitor.dwellTimerFired()
}
