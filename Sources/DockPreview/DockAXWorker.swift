import ApplicationServices
import Foundation

/// Owns every potentially blocking accessibility request on one serial queue.
///
/// Mouse movement can arrive much faster than another process answers AX.
/// Pending probe/window-list requests are therefore latest-wins: while one
/// request is in flight, intermediate positions are replaced instead of
/// becoming a queue that the main thread observes seconds later.
final class DockAXWorker: @unchecked Sendable {
    typealias TargetResolver = @Sendable (
        CGPoint,
        CGPoint,
        pid_t,
        [DockRunningApplication]
    ) -> DockAppTarget?
    typealias WindowResolver = @Sendable (
        pid_t,
        Int
    ) -> [DockAXWindowResolution]
    typealias WindowRaiser = @Sendable (DockAXWindowResolution) -> Bool
    typealias WindowCloser = @Sendable (DockAXWindowResolution) -> Bool

    typealias TargetCompletion = @MainActor @Sendable (
        UInt64,
        DockAppTarget?
    ) -> Void
    typealias WindowsCompletion = @MainActor @Sendable (
        UInt64,
        [DockAXWindow]
    ) -> Void
    typealias RaiseCompletion = @MainActor @Sendable () -> Void
    typealias CloseCompletion = @MainActor @Sendable (Bool) -> Void

    private struct TargetRequest: @unchecked Sendable {
        let identifier: UInt64
        let quartzPoint: CGPoint
        let pointerLocation: CGPoint
        let dockProcessIdentifier: pid_t
        let runningApplications: [DockRunningApplication]
        let completion: TargetCompletion
    }

    private struct WindowsRequest: @unchecked Sendable {
        let identifier: UInt64
        let processIdentifier: pid_t
        let limit: Int
        let completion: WindowsCompletion
    }

    private struct RaiseRequest: @unchecked Sendable {
        let processIdentifier: pid_t
        let windowID: CGWindowID
        let completion: RaiseCompletion
    }

    private struct CloseRequest: @unchecked Sendable {
        let processIdentifier: pid_t
        let windowID: CGWindowID
        let completion: CloseCompletion
    }

    private enum Job {
        case close(CloseRequest)
        case windows(WindowsRequest)
        case raise(RaiseRequest)
        case pointerTarget(TargetRequest)
    }

    private struct WindowKey: Hashable {
        let processIdentifier: pid_t
        let windowID: CGWindowID
    }

    private let queue = DispatchQueue(
        label: "com.maclife.mfinder.dock-preview.ax",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let targetResolver: TargetResolver
    private let windowResolver: WindowResolver
    private let windowRaiser: WindowRaiser
    private let windowCloser: WindowCloser

    private var isDraining = false
    private var pendingPointerTarget: TargetRequest?
    private var pendingWindows: WindowsRequest?
    private var pendingRaises: [RaiseRequest] = []
    private var pendingCloses: [CloseRequest] = []
    /// Accessed only on `queue`.
    private var resolvedWindows: [WindowKey: DockAXWindowResolution] = [:]

    init(
        targetResolver: @escaping TargetResolver = {
            DockAXResolver.target(
                at: $0,
                pointerLocation: $1,
                dockProcessIdentifier: $2,
                runningApplications: $3
            )
        },
        windowResolver: @escaping WindowResolver = {
            DockAXResolver.windows(processIdentifier: $0, limit: $1)
        },
        windowRaiser: @escaping WindowRaiser = {
            DockAXResolver.raise($0)
        },
        windowCloser: @escaping WindowCloser = {
            DockAXResolver.close($0)
        }
    ) {
        self.targetResolver = targetResolver
        self.windowResolver = windowResolver
        self.windowRaiser = windowRaiser
        self.windowCloser = windowCloser
    }

    func submitPointerTarget(
        identifier: UInt64,
        quartzPoint: CGPoint,
        pointerLocation: CGPoint,
        dockProcessIdentifier: pid_t,
        runningApplications: [DockRunningApplication],
        completion: @escaping TargetCompletion
    ) {
        let request = TargetRequest(
            identifier: identifier,
            quartzPoint: quartzPoint,
            pointerLocation: pointerLocation,
            dockProcessIdentifier: dockProcessIdentifier,
            runningApplications: runningApplications,
            completion: completion
        )
        enqueue {
            pendingPointerTarget = request
        }
    }

    func submitWindows(
        identifier: UInt64,
        processIdentifier: pid_t,
        limit: Int,
        completion: @escaping WindowsCompletion
    ) {
        let request = WindowsRequest(
            identifier: identifier,
            processIdentifier: processIdentifier,
            limit: limit,
            completion: completion
        )
        enqueue {
            pendingWindows = request
        }
    }

    func submitRaise(
        processIdentifier: pid_t,
        windowID: CGWindowID,
        completion: @escaping RaiseCompletion
    ) {
        let request = RaiseRequest(
            processIdentifier: processIdentifier,
            windowID: windowID,
            completion: completion
        )
        enqueue {
            pendingRaises.append(request)
        }
    }

    func submitClose(
        processIdentifier: pid_t,
        windowID: CGWindowID,
        completion: @escaping CloseCompletion
    ) {
        let request = CloseRequest(
            processIdentifier: processIdentifier,
            windowID: windowID,
            completion: completion
        )
        enqueue {
            pendingCloses.append(request)
        }
    }

    func cancelPendingPointerTargets() {
        lock.lock()
        pendingPointerTarget = nil
        lock.unlock()
    }

    func cancelPendingLoads() {
        lock.lock()
        pendingWindows = nil
        lock.unlock()
    }

    func cancelAllPendingDiscovery() {
        lock.lock()
        pendingPointerTarget = nil
        pendingWindows = nil
        lock.unlock()
    }

    private func enqueue(_ update: () -> Void) {
        var shouldStart = false
        lock.lock()
        update()
        if !isDraining {
            isDraining = true
            shouldStart = true
        }
        lock.unlock()
        if shouldStart {
            queue.async { [weak self] in
                self?.drain()
            }
        }
    }

    private func drain() {
        while let job = nextJob() {
            switch job {
            case .pointerTarget(let request):
                let target = targetResolver(
                    request.quartzPoint,
                    request.pointerLocation,
                    request.dockProcessIdentifier,
                    request.runningApplications
                )
                Task { @MainActor in
                    request.completion(request.identifier, target)
                }

            case .windows(let request):
                let resolutions = windowResolver(
                    request.processIdentifier,
                    request.limit
                )
                resolvedWindows = resolvedWindows.filter {
                    $0.key.processIdentifier != request.processIdentifier
                }
                for resolution in resolutions {
                    resolvedWindows[WindowKey(
                        processIdentifier: request.processIdentifier,
                        windowID: resolution.snapshot.windowID
                    )] = resolution
                }
                let snapshots = resolutions.map(\.snapshot)
                Task { @MainActor in
                    request.completion(request.identifier, snapshots)
                }

            case .raise(let request):
                let key = WindowKey(
                    processIdentifier: request.processIdentifier,
                    windowID: request.windowID
                )
                let resolution = resolvedWindows[key]
                let raise = windowRaiser
                // An AX action against another process is a MIG round trip that
                // process services on its own main thread, so it stays here off
                // the main thread. Against MFinder's own windows there is no
                // round trip: AXUIElementPerformAction dispatches straight into
                // AppKit on the calling thread, and -[NSWindow makeKeyAndOrderFront:]
                // traps on macOS 26 when that thread is not the main one.
                // Raising is a once-per-click action, so the hop costs nothing
                // that the off-main discovery path was protecting.
                if request.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    Task { @MainActor in
                        if let resolution { _ = raise(resolution) }
                        request.completion()
                    }
                } else {
                    if let resolution { _ = raise(resolution) }
                    Task { @MainActor in
                        request.completion()
                    }
                }

            case .close(let request):
                let key = WindowKey(
                    processIdentifier: request.processIdentifier,
                    windowID: request.windowID
                )
                let resolution = resolvedWindows[key]
                let close = windowCloser
                // MFinder owns AppKit objects for its own windows, so their
                // close buttons must be pressed on the main actor. Other apps
                // service AX on their process and stay off our main thread.
                if request.processIdentifier
                    == ProcessInfo.processInfo.processIdentifier {
                    Task { @MainActor in
                        request.completion(resolution.map(close) ?? false)
                    }
                } else {
                    let succeeded = resolution.map(close) ?? false
                    Task { @MainActor in
                        request.completion(succeeded)
                    }
                }
            }
        }
    }

    private func nextJob() -> Job? {
        lock.lock()
        defer { lock.unlock() }
        if !pendingCloses.isEmpty {
            return .close(pendingCloses.removeFirst())
        }
        if !pendingRaises.isEmpty {
            return .raise(pendingRaises.removeFirst())
        }
        if let request = pendingWindows {
            pendingWindows = nil
            return .windows(request)
        }
        if let request = pendingPointerTarget {
            pendingPointerTarget = nil
            return .pointerTarget(request)
        }
        isDraining = false
        return nil
    }
}
