import AppKit
import ScreenCaptureKit
import os

struct DockProbeGate {
    enum Edge: Equatable {
        case bottom
        case left
        case right
    }

    private static let visibleDockPadding: CGFloat = 24
    private static let autoHideRevealStrip: CGFloat = 8
    private static let armedAutoHideBand: CGFloat = 150

    private(set) var armedAutoHideEdge: Edge?
    private var armedScreenFrame: CGRect?

    mutating func reset() {
        armedAutoHideEdge = nil
        armedScreenFrame = nil
    }

    mutating func allowsProbe(
        at point: CGPoint,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> Bool {
        let candidates: [(Edge, CGFloat)] = [
            (.bottom, max(0, visibleFrame.minY - screenFrame.minY)),
            (.left, max(0, visibleFrame.minX - screenFrame.minX)),
            (.right, max(0, screenFrame.maxX - visibleFrame.maxX)),
        ]
        if let visibleDock = candidates
            .filter({ $0.1 > 1 })
            .max(by: { $0.1 < $1.1 }) {
            reset()
            return distance(
                from: point,
                to: visibleDock.0,
                in: screenFrame
            ) <= visibleDock.1 + Self.visibleDockPadding
        }

        // An auto-hidden Dock reserves no visibleFrame inset. Arm a screen edge
        // only after the pointer actually touches its reveal strip; once armed,
        // keep the larger band live while the Dock animates and the pointer
        // travels inward across magnified icons.
        if armedScreenFrame != screenFrame {
            reset()
        }
        if let edge = armedAutoHideEdge {
            if distance(from: point, to: edge, in: screenFrame)
                <= Self.armedAutoHideBand {
                return true
            }
            reset()
        }

        let nearest = candidates
            .map { ($0.0, distance(from: point, to: $0.0, in: screenFrame)) }
            .min(by: { $0.1 < $1.1 })
        guard let nearest, nearest.1 <= Self.autoHideRevealStrip else {
            return false
        }
        armedAutoHideEdge = nearest.0
        armedScreenFrame = screenFrame
        return true
    }

    private func distance(
        from point: CGPoint,
        to edge: Edge,
        in frame: CGRect
    ) -> CGFloat {
        switch edge {
        case .bottom: max(0, point.y - frame.minY)
        case .left: max(0, point.x - frame.minX)
        case .right: max(0, frame.maxX - point.x)
        }
    }
}

struct DockThumbnailCacheDecision: Equatable {
    let displaysCachedImage: Bool
    let needsRefresh: Bool
}

struct DockThumbnailCacheKey: Hashable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let windowID: CGWindowID
}

enum DockThumbnailCachePolicy {
    static func decide(
        capturedAt: TimeInterval?,
        cachedFrame: CGRect?,
        currentFrame: CGRect?,
        now: TimeInterval,
        freshness: TimeInterval,
        retention: TimeInterval,
        canCapture: Bool
    ) -> DockThumbnailCacheDecision {
        guard let capturedAt, let cachedFrame else {
            return DockThumbnailCacheDecision(
                displaysCachedImage: false,
                needsRefresh: canCapture
            )
        }
        let age = max(0, now - capturedAt)
        guard age < retention,
              currentFrame == nil || currentFrame == cachedFrame else {
            return DockThumbnailCacheDecision(
                displaysCachedImage: false,
                needsRefresh: canCapture
            )
        }
        return DockThumbnailCacheDecision(
            displaysCachedImage: true,
            needsRefresh: canCapture && age >= freshness
        )
    }
}

enum DockThumbnailCapturePolicy {
    static func firstDeferredCaptureOffset(
        previewIndices: [Int],
        immediatePreviewCount: Int
    ) -> Int? {
        previewIndices.firstIndex { $0 >= immediatePreviewCount }
    }
}

enum DockPreviewOutsidePolicy {
    static func cancelsLoadImmediately(panelIsVisible: Bool) -> Bool {
        !panelIsVisible
    }
}

enum DockPreviewLoadPolicy {
    static func acceptsResult(
        identifier: UInt64,
        latestIdentifier: UInt64,
        isSuspended: Bool,
        pendingBundleIdentifier: String?,
        targetBundleIdentifier: String
    ) -> Bool {
        identifier == latestIdentifier
            && !isSuspended
            && pendingBundleIdentifier == targetBundleIdentifier
    }
}

enum DockPreviewRetargetPolicy {
    static func cancelsPendingTarget(
        pendingBundleIdentifier: String?,
        hoveredBundleIdentifier: String
    ) -> Bool {
        guard let pendingBundleIdentifier else { return false }
        return pendingBundleIdentifier != hoveredBundleIdentifier
    }
}

/// Keeps a window that was just closed out of the preview while the owning
/// app's accessibility tree catches up. Some document apps accept the close
/// action and remove the real window immediately but continue returning its
/// stale AX element for several hundred milliseconds.
struct DockClosingWindowRegistry {
    private struct Key: Hashable {
        let bundleIdentifier: String
        let processIdentifier: pid_t
        let windowID: CGWindowID
    }

    private var expirationByWindow: [Key: TimeInterval] = [:]

    mutating func markClosing(
        bundleIdentifier: String,
        processIdentifier: pid_t,
        windowID: CGWindowID,
        now: TimeInterval,
        gracePeriod: TimeInterval
    ) {
        expirationByWindow[Key(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            windowID: windowID
        )] = now + gracePeriod
    }

    /// Suppresses a still-reported AX window until the grace period expires.
    /// Seeing it disappear is definitive and clears the tombstone early. If it
    /// remains after the deadline, the close was likely vetoed (for example by
    /// an unsaved-document prompt), so the window is allowed back into the UI.
    mutating func reconciledWindows(
        _ windows: [DockAXWindow],
        bundleIdentifier: String,
        processIdentifier: pid_t,
        now: TimeInterval
    ) -> [DockAXWindow] {
        let reportedWindowIDs = Set(windows.map(\.windowID))
        expirationByWindow = expirationByWindow.filter { key, expiration in
            guard key.bundleIdentifier == bundleIdentifier,
                  key.processIdentifier == processIdentifier else {
                return expiration > now
            }
            return expiration > now
                && reportedWindowIDs.contains(key.windowID)
        }
        return windows.filter { window in
            expirationByWindow[Key(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                windowID: window.windowID
            )] == nil
        }
    }
}

enum DockShareableWindowSnapshotScope: Hashable, Sendable {
    case onScreen
    case all

    var onScreenWindowsOnly: Bool {
        self == .onScreen
    }

    var freshness: TimeInterval {
        switch self {
        case .onScreen: 2
        case .all: 5
        }
    }
}

enum DockShareableWindowLookupPolicy {
    static func missingWindowIDs(
        axWindows: [DockAXWindow],
        onScreenWindowIDs: Set<CGWindowID>
    ) -> Set<CGWindowID> {
        Set(axWindows.map(\.windowID)).subtracting(onScreenWindowIDs)
    }

    static func needsAllWindowsSnapshot(
        axWindows: [DockAXWindow],
        onScreenWindowIDs: Set<CGWindowID>
    ) -> Bool {
        !missingWindowIDs(
            axWindows: axWindows,
            onScreenWindowIDs: onScreenWindowIDs
        ).isEmpty
    }

    static func resolvedWindowIDs(
        axWindows: [DockAXWindow],
        onScreenWindowIDs: Set<CGWindowID>,
        allWindowIDs: Set<CGWindowID>
    ) -> [CGWindowID] {
        let available = onScreenWindowIDs.union(allWindowIDs)
        return axWindows.map(\.windowID).filter(available.contains)
    }

    static func newlyUnresolvedWindowIDs<ID: Hashable>(
        requiredWindowIDs: Set<ID>,
        availableWindowIDs: Set<ID>,
        previouslyUnresolvedWindowIDs: Set<ID>
    ) -> Set<ID> {
        requiredWindowIDs
            .subtracting(availableWindowIDs)
            .subtracting(previouslyUnresolvedWindowIDs)
    }

    static func unresolvedWindowIDs<ID: Hashable>(
        previouslyUnresolvedWindowIDs: Set<ID>,
        requiredWindowIDs: Set<ID>,
        availableWindowIDs: Set<ID>
    ) -> Set<ID> {
        previouslyUnresolvedWindowIDs
            .union(requiredWindowIDs)
            .subtracting(availableWindowIDs)
    }
}

/// Serializes non-cancellable WindowServer work across superseded hover loads.
/// A caller may become cancelled while its operation is running, but the
/// underlying task finishes and releases the gate before the next one starts.
@MainActor
final class DockSerialAsyncGate<Value: Sendable> {
    private struct ActiveOperation {
        let identifier: UInt64
        let task: Task<Value, Never>
    }

    private var activeOperation: ActiveOperation?
    private var latestIdentifier: UInt64 = 0

    func run(
        _ operation: @escaping @MainActor () async -> Value
    ) async throws -> Value {
        while let activeOperation {
            _ = await activeOperation.task.value
            // The creator and any queued waiter can resume in either order.
            // Let the first continuation clear the completed slot; the ID guard
            // prevents an older waiter from clearing a newer operation.
            if self.activeOperation?.identifier
                == activeOperation.identifier {
                self.activeOperation = nil
            }
            try Task.checkCancellation()
        }

        latestIdentifier &+= 1
        let identifier = latestIdentifier
        let task = Task { @MainActor in
            await operation()
        }
        activeOperation = ActiveOperation(
            identifier: identifier,
            task: task
        )
        let value = await task.value
        if activeOperation?.identifier == identifier {
            activeOperation = nil
        }
        try Task.checkCancellation()
        return value
    }
}

@MainActor
final class DockPreviewController {
    private struct CachedThumbnail {
        let image: CGImage
        let windowFrame: CGRect
        let capturedAt: TimeInterval
    }

    private struct ShareableWindowKey: Hashable, Sendable {
        let processIdentifier: pid_t
        let windowID: CGWindowID
    }

    private struct CachedShareableWindowSnapshot {
        let requestIdentifier: UInt64
        let windows: [ShareableWindowKey: SCWindow]
        let capturedAt: TimeInterval
        var unresolvedRequestedKeys: Set<ShareableWindowKey>
    }

    /// `SCWindow` is an immutable ScreenCaptureKit descriptor but the framework
    /// has not annotated it Sendable. Keep that unchecked boundary contained in
    /// the result of our main-actor snapshot task.
    private struct ShareableWindowSnapshot: @unchecked Sendable {
        let windows: [ShareableWindowKey: SCWindow]
    }

    private struct ShareableWindowSnapshotRequest {
        let identifier: UInt64
        let task: Task<ShareableWindowSnapshot, Error>
    }

    private struct ShareableWindowSnapshotFailure {
        let failedAt: TimeInterval
        let error: any Error
    }

    private struct ThumbnailCapture {
        let index: Int
        let key: DockThumbnailCacheKey
        let window: SCWindow
    }

    private struct PreviewLoadState {
        var previews: [DockWindowPreview]
        var captures: [ThumbnailCapture]
    }

    private static let log = Logger(
        subsystem: "com.maclife.mdockpreview",
        category: "dock-preview"
    )
    private static let immediateThumbnailCount = 3
    private static let deferredThumbnailDelay: Duration = .milliseconds(600)
    private static let thumbnailPacing: Duration = .milliseconds(80)
    private static let thumbnailFreshness: TimeInterval = 20
    /// Retain the last good frame as a stale-while-revalidate fallback. The
    /// cache is also capped at 40 downscaled images, so ten minutes remains a
    /// small, bounded footprint while eliminating periodic error-glyph flashes.
    private static let thumbnailRetention: TimeInterval = 10 * 60

    private let settings: AppSettings
    private let panelController = DockPreviewPanelController()
    private let thumbnailCaptureGate = DockSerialAsyncGate<CGImage?>()
    private lazy var pointerMonitor = DockPointerMonitor(
        onMove: { [weak self] event in
            self?.pointerMoved(event)
        }
    )
    private var screenParametersObserver: NSObjectProtocol?
    private var pendingHover: Task<Void, Never>?
    private var pendingHide: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private let axWorker = DockAXWorker()
    private var currentBundleIdentifier: String?
    private var pendingBundleIdentifier: String?
    private var isSuspended = false
    private var isLoadActive = false
    private var hasOutstandingPointerProbe = false
    private var latestPointerRequestID: UInt64 = 0
    private var latestLoadRequestID: UInt64 = 0
    private var cachedDockProcessIdentifier: pid_t?
    private var cachedRunningApplications: [DockRunningApplication] = []
    private var lastApplicationSnapshotTime: TimeInterval = -.infinity
    private var cachedShareableSnapshots: [
        DockShareableWindowSnapshotScope: CachedShareableWindowSnapshot
    ] = [:]
    private var shareableSnapshotRequests: [
        DockShareableWindowSnapshotScope: ShareableWindowSnapshotRequest
    ] = [:]
    private var shareableSnapshotFailures: [
        DockShareableWindowSnapshotScope: ShareableWindowSnapshotFailure
    ] = [:]
    private var latestShareableSnapshotRequestIdentifier: UInt64 = 0
    private var closingWindowRegistry = DockClosingWindowRegistry()
    private var thumbnailCache: [DockThumbnailCacheKey: CachedThumbnail] = [:]
    private var latestPointerEventSequence: UInt64 = 0

    init(settings: AppSettings) {
        self.settings = settings
    }

    func applySettings() {
        if settings.dockPreviewEnabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard screenParametersObserver == nil else { return }
        refreshPointerScreens()
        pointerMonitor.start(
            screens: Self.pointerScreens(),
            primaryDisplayHeight: Self.primaryDisplayHeight()
        )
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPointerScreens()
            }
        }
    }

    func stop() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = nil
        pointerMonitor.stop()
        pendingHover?.cancel()
        pendingHide?.cancel()
        loadTask?.cancel()
        invalidateDiscovery()
        hidePanel()
        currentBundleIdentifier = nil
        pendingBundleIdentifier = nil
    }

    /// Suspend discovery while MDock Preview's status menu is open. AX itself runs
    /// off-main, but skipping obsolete probes avoids needless worker traffic
    /// and stale callbacks while AppKit owns menu tracking.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        pointerMonitor.setSuspended(suspended)
        guard suspended else {
            refreshPointerScreens()
            return
        }

        pendingHover?.cancel()
        pendingHover = nil
        pendingHide?.cancel()
        pendingHide = nil
        invalidateDiscovery()
        hidePanel()
        currentBundleIdentifier = nil
        pendingBundleIdentifier = nil
    }

    /// Only region transitions and a settled Dock position reach the main
    /// actor. Raw mouse movement stays on DockPointerMonitor's private run loop.
    private func pointerMoved(_ event: DockPointerEvent) {
        guard event.sequence > latestPointerEventSequence else { return }
        latestPointerEventSequence = event.sequence
        guard !isSuspended, settings.dockPreviewEnabled else { return }

        switch event.region {
        case .panel:
            pendingHide?.cancel()
            pendingHide = nil
            return

        case .outside:
            invalidatePointerProbe()
            pendingHover?.cancel()
            pendingHover = nil
            // Leaving the Dock area still has to retract a visible panel.
            let panelIsVisible = panelController.frame != nil
            if DockPreviewOutsidePolicy.cancelsLoadImmediately(
                panelIsVisible: panelIsVisible
            ) {
                cancelPendingLoad()
                pendingBundleIdentifier = nil
            } else {
                // There is a short physical gap between the Dock and panel.
                // Keep thumbnail work alive during the hide grace period so
                // crossing that gap cannot strand a visible loading skeleton.
                scheduleHide()
            }
            return

        case .dock:
            break
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard let snapshot = applicationSnapshot(now: now) else { return }
        latestPointerRequestID &+= 1
        let requestID = latestPointerRequestID
        hasOutstandingPointerProbe = true
        axWorker.submitPointerTarget(
            identifier: requestID,
            quartzPoint: event.quartzPoint,
            pointerLocation: event.appKitPoint,
            dockProcessIdentifier: snapshot.dockProcessIdentifier,
            runningApplications: snapshot.runningApplications
        ) { [weak self] identifier, target in
            self?.receivePointerTarget(identifier: identifier, target: target)
        }
    }

    private func receivePointerTarget(
        identifier: UInt64,
        target: DockAppTarget?
    ) {
        guard identifier == latestPointerRequestID else { return }
        hasOutstandingPointerProbe = false
        guard !isSuspended, settings.dockPreviewEnabled else { return }
        guard let target else {
            scheduleHide()
            return
        }
        pendingHide?.cancel()
        pendingHide = nil
        if currentBundleIdentifier == target.bundleIdentifier,
           panelController.frame != nil {
            // A -> B -> A can happen before B's settled hover/window query
            // finishes. Returning without invalidating B lets its stale result
            // replace A's still-correct panel after the pointer is back on A.
            if DockPreviewRetargetPolicy.cancelsPendingTarget(
                pendingBundleIdentifier: pendingBundleIdentifier,
                hoveredBundleIdentifier: target.bundleIdentifier
            ) {
                pendingHover?.cancel()
                pendingHover = nil
                cancelPendingLoad()
                pendingBundleIdentifier = nil
            }
            return
        }
        if pendingBundleIdentifier == target.bundleIdentifier { return }
        pendingHover?.cancel()
        pendingBundleIdentifier = target.bundleIdentifier
        pendingHover = Task { @MainActor [weak self] in
            // The pointer monitor has already waited for an 80 ms bounded
            // sample before this AX result exists. Keep total hover latency
            // near ~200 ms without returning to continuous probing.
            try? await Task.sleep(for: .seconds(0.12))
            guard !Task.isCancelled, let self else { return }
            self.pendingHover = nil
            guard self.pendingBundleIdentifier == target.bundleIdentifier,
                  !self.isSuspended,
                  self.settings.dockPreviewEnabled else { return }
            self.loadAndPresent(target: target)
        }
    }

    private func invalidatePointerProbe() {
        guard hasOutstandingPointerProbe else { return }
        latestPointerRequestID &+= 1
        hasOutstandingPointerProbe = false
        axWorker.cancelPendingPointerTargets()
    }

    private func invalidateDiscovery() {
        latestPointerRequestID &+= 1
        latestLoadRequestID &+= 1
        hasOutstandingPointerProbe = false
        isLoadActive = false
        axWorker.cancelAllPendingDiscovery()
        loadTask?.cancel()
        loadTask = nil
    }

    private func cancelPendingLoad() {
        guard isLoadActive else { return }
        latestLoadRequestID &+= 1
        isLoadActive = false
        axWorker.cancelPendingLoads()
        loadTask?.cancel()
        loadTask = nil
    }

    private func applicationSnapshot(
        now: TimeInterval
    ) -> (
        dockProcessIdentifier: pid_t,
        runningApplications: [DockRunningApplication]
    )? {
        if cachedDockProcessIdentifier == nil
            || now - lastApplicationSnapshotTime >= 1 {
            let applications = NSWorkspace.shared.runningApplications
            cachedDockProcessIdentifier = applications.first {
                $0.bundleIdentifier == "com.apple.dock"
            }?.processIdentifier
            cachedRunningApplications = applications.compactMap { application in
                guard application.activationPolicy == .regular,
                      let identifier = application.bundleIdentifier else { return nil }
                return DockRunningApplication(
                    bundleIdentifier: identifier,
                    processIdentifier: application.processIdentifier,
                    appName: application.localizedName ?? identifier
                )
            }
            lastApplicationSnapshotTime = now
        }
        guard let dockProcessIdentifier = cachedDockProcessIdentifier else {
            return nil
        }
        return (dockProcessIdentifier, cachedRunningApplications)
    }

    private static func pointerScreens() -> [DockPointerScreen] {
        NSScreen.screens.map {
            DockPointerScreen(
                frame: $0.frame,
                visibleFrame: $0.visibleFrame
            )
        }
    }

    private static func primaryDisplayHeight() -> CGFloat {
        NSScreen.screens.first {
            $0.frame.origin == .zero
        }?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    private func refreshPointerScreens() {
        pointerMonitor.updateScreens(
            Self.pointerScreens(),
            primaryDisplayHeight: Self.primaryDisplayHeight()
        )
    }

    private func hidePanel() {
        panelController.hide()
        pointerMonitor.updatePanelFrame(nil)
    }

    private func syncPanelFrame() {
        pointerMonitor.updatePanelFrame(panelController.frame)
    }

    private func prepareForTarget(_ target: DockAppTarget) {
        pendingHide?.cancel()
        pendingHide = nil
        pendingBundleIdentifier = target.bundleIdentifier
    }

    private func scheduleHide() {
        pendingHover?.cancel()
        pendingHover = nil
        guard panelController.frame != nil else {
            cancelPendingLoad()
            pendingBundleIdentifier = nil
            return
        }
        guard pendingHide == nil || pendingHide?.isCancelled == true else { return }
        pendingHide = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.28))
            guard !Task.isCancelled, let self else { return }
            self.cancelPendingLoad()
            self.pendingBundleIdentifier = nil
            self.hidePanel()
            self.currentBundleIdentifier = nil
            self.pendingHide = nil
        }
    }

    private func loadAndPresent(
        target: DockAppTarget,
        minimumWindowCount: Int = 1
    ) {
        prepareForTarget(target)
        latestLoadRequestID &+= 1
        let requestID = latestLoadRequestID
        isLoadActive = true
        loadTask?.cancel()
        loadTask = nil
        axWorker.submitWindows(
            identifier: requestID,
            processIdentifier: target.processIdentifier,
            limit: 10
        ) { [weak self] identifier, windows in
            self?.receiveWindows(
                identifier: identifier,
                target: target,
                minimumWindowCount: minimumWindowCount,
                windows: windows
            )
        }
    }

    private func receiveWindows(
        identifier: UInt64,
        target: DockAppTarget,
        minimumWindowCount: Int,
        windows: [DockAXWindow]
    ) {
        guard identifier == latestLoadRequestID,
              !isSuspended,
              settings.dockPreviewEnabled,
              pendingBundleIdentifier == target.bundleIdentifier else { return }
        let axWindows = closingWindowRegistry.reconciledWindows(
            windows.sorted { $0.windowID < $1.windowID },
            bundleIdentifier: target.bundleIdentifier,
            processIdentifier: target.processIdentifier,
            now: ProcessInfo.processInfo.systemUptime
        )
        guard axWindows.count >= minimumWindowCount else {
            isLoadActive = false
            hidePanel()
            currentBundleIdentifier = nil
            pendingBundleIdentifier = nil
            return
        }
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // AX is the source of truth for WHICH windows exist — it
                // matches the app's own Window menu, so hidden helper windows
                // (Safari prewarm, Electron compositors…) never show up.
                // ScreenCaptureKit is only the thumbnail camera.
                // Creation order (window IDs are monotonically assigned), NOT
                // AX z-order: z-order reshuffles after every selection, which
                // breaks the user's spatial memory of tile positions.
                let onScreenSnapshot: [ShareableWindowKey: SCWindow]
                do {
                    onScreenSnapshot = try await shareableWindowSnapshot(
                        scope: .onScreen
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // AX still gives us a useful, selectable window list. A
                    // transient ScreenCaptureKit failure must not remove the
                    // whole switcher.
                    Self.log.error(
                        "Could not load on-screen Dock thumbnails: \(error.localizedDescription, privacy: .public)"
                    )
                    onScreenSnapshot = [:]
                }
                try Task.checkCancellation()
                guard DockPreviewLoadPolicy.acceptsResult(
                    identifier: identifier,
                    latestIdentifier: self.latestLoadRequestID,
                    isSuspended: self.isSuspended,
                    pendingBundleIdentifier: self.pendingBundleIdentifier,
                    targetBundleIdentifier: target.bundleIdentifier
                ) else {
                    return
                }
                let onScreenByID = shareableWindows(
                    for: target.processIdentifier,
                    in: onScreenSnapshot
                )
                let missingWindowIDs =
                    DockShareableWindowLookupPolicy.missingWindowIDs(
                        axWindows: axWindows,
                        onScreenWindowIDs: Set(onScreenByID.keys)
                    )
                let now = ProcessInfo.processInfo.systemUptime
                pruneThumbnailCache(now: now)
                var loadState = makePreviewLoadState(
                    axWindows: axWindows,
                    shareableByID: onScreenByID,
                    pendingLookupWindowIDs: missingWindowIDs,
                    target: target,
                    now: now
                )
                guard DockPreviewLoadPolicy.acceptsResult(
                    identifier: identifier,
                    latestIdentifier: self.latestLoadRequestID,
                    isSuspended: self.isSuspended,
                    pendingBundleIdentifier: self.pendingBundleIdentifier,
                    targetBundleIdentifier: target.bundleIdentifier
                ) else {
                    return
                }
                currentBundleIdentifier = target.bundleIdentifier
                let runningApplication = NSRunningApplication(
                    processIdentifier: target.processIdentifier
                )
                let appIcon = runningApplication?.icon
                // Put an interactive panel on screen immediately. A retained
                // image remains visible while it is refreshed; a true cold
                // capture uses a neutral static skeleton, never an error glyph.
                present(
                    previews: loadState.previews,
                    target: target,
                    appIcon: appIcon
                )

                if !missingWindowIDs.isEmpty {
                    let requiredKeys = Set(missingWindowIDs.map {
                        ShareableWindowKey(
                            processIdentifier: target.processIdentifier,
                            windowID: $0
                        )
                    })
                    let allSnapshot: [ShareableWindowKey: SCWindow]?
                    do {
                        allSnapshot = try await shareableWindowSnapshot(
                            scope: .all,
                            requiredKeys: requiredKeys
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Keep the fast-path panel alive. Cold windows that the
                        // full query could not resolve become unavailable, while
                        // any retained thumbnails remain visible.
                        Self.log.error(
                            "Could not load minimized Dock thumbnails: \(error.localizedDescription, privacy: .public)"
                        )
                        allSnapshot = nil
                    }
                    try Task.checkCancellation()
                    guard DockPreviewLoadPolicy.acceptsResult(
                        identifier: identifier,
                        latestIdentifier: self.latestLoadRequestID,
                        isSuspended: self.isSuspended,
                        pendingBundleIdentifier: self.pendingBundleIdentifier,
                        targetBundleIdentifier: target.bundleIdentifier
                    ) else {
                        return
                    }

                    var resolvedByID = allSnapshot.map {
                        shareableWindows(
                            for: target.processIdentifier,
                            in: $0
                        )
                    } ?? [:]
                    // The on-screen descriptor has the newest frame and surface
                    // when both scoped snapshots contain the same window.
                    for (windowID, window) in onScreenByID {
                        resolvedByID[windowID] = window
                    }
                    loadState = makePreviewLoadState(
                        axWindows: axWindows,
                        shareableByID: resolvedByID,
                        pendingLookupWindowIDs: [],
                        target: target,
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    present(
                        previews: loadState.previews,
                        target: target,
                        appIcon: appIcon
                    )
                }

                var previews = loadState.previews
                let captures = loadState.captures

                var presentationNeedsUpdate = false
                let firstDeferredCaptureOffset =
                    DockThumbnailCapturePolicy.firstDeferredCaptureOffset(
                        previewIndices: captures.map(\.index),
                        immediatePreviewCount: Self.immediateThumbnailCount
                    )
                for (captureOffset, capture) in captures.enumerated() {
                    try Task.checkCancellation()
                    guard DockPreviewLoadPolicy.acceptsResult(
                        identifier: identifier,
                        latestIdentifier: self.latestLoadRequestID,
                        isSuspended: self.isSuspended,
                        pendingBundleIdentifier: self.pendingBundleIdentifier,
                        targetBundleIdentifier: target.bundleIdentifier
                    ) else {
                        return
                    }
                    // The first three tiles fill the visible viewport. Defer
                    // the off-screen row and pace it so ten Excel windows do
                    // not become ten back-to-back WindowServer requests while
                    // Dock and SwiftUI are animating under the pointer.
                    if captureOffset == firstDeferredCaptureOffset {
                        // Publish the visible batch before deliberately waiting
                        // for off-screen windows. Previously the completed first
                        // three images stayed hidden behind placeholders until
                        // every deferred capture had also finished.
                        if presentationNeedsUpdate {
                            present(
                                previews: previews,
                                target: target,
                                appIcon: appIcon
                            )
                            presentationNeedsUpdate = false
                        }
                        try await Task.sleep(for: Self.deferredThumbnailDelay)
                    } else if captureOffset > 0 {
                        try await Task.sleep(for: Self.thumbnailPacing)
                    }
                    let capturedImage = await captureThumbnail(capture.window)
                    try Task.checkCancellation()
                    guard DockPreviewLoadPolicy.acceptsResult(
                        identifier: identifier,
                        latestIdentifier: self.latestLoadRequestID,
                        isSuspended: self.isSuspended,
                        pendingBundleIdentifier: self.pendingBundleIdentifier,
                        targetBundleIdentifier: target.bundleIdentifier
                    ) else {
                        return
                    }
                    guard let image = capturedImage else {
                        let old = previews[capture.index]
                        if old.thumbnail == nil,
                           old.thumbnailPlaceholder == .loading {
                            previews[capture.index] = DockWindowPreview(
                                id: old.id,
                                title: old.title,
                                thumbnail: nil,
                                thumbnailPlaceholder: .unavailable,
                                aspectRatio: old.aspectRatio
                            )
                            presentationNeedsUpdate = true
                        }
                        continue
                    }
                    thumbnailCache[capture.key] = CachedThumbnail(
                        image: image,
                        windowFrame: capture.window.frame,
                        capturedAt: ProcessInfo.processInfo.systemUptime
                    )
                    pruneThumbnailCache(
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    let old = previews[capture.index]
                    previews[capture.index] = DockWindowPreview(
                        id: old.id,
                        title: old.title,
                        thumbnail: image,
                        thumbnailPlaceholder: .unavailable,
                        aspectRatio: old.aspectRatio
                    )
                    presentationNeedsUpdate = true
                }
                try Task.checkCancellation()
                guard DockPreviewLoadPolicy.acceptsResult(
                    identifier: identifier,
                    latestIdentifier: self.latestLoadRequestID,
                    isSuspended: self.isSuspended,
                    pendingBundleIdentifier: self.pendingBundleIdentifier,
                    targetBundleIdentifier: target.bundleIdentifier
                ) else {
                    return
                }
                // At most one final batch update. Together with the visible
                // batch above this avoids per-tile SwiftUI/WindowServer churn.
                if presentationNeedsUpdate {
                    present(
                        previews: previews,
                        target: target,
                        appIcon: appIcon
                    )
                }
                pendingBundleIdentifier = nil
                isLoadActive = false
                loadTask = nil
            } catch is CancellationError {
                if identifier == self.latestLoadRequestID {
                    self.isLoadActive = false
                    self.loadTask = nil
                }
                return
            } catch {
                // An older ScreenCaptureKit request can finish with a regular
                // error after it has already been cancelled and superseded.
                // Never let that stale task tear down the newer panel/load.
                guard DockPreviewLoadPolicy.acceptsResult(
                    identifier: identifier,
                    latestIdentifier: self.latestLoadRequestID,
                    isSuspended: self.isSuspended,
                    pendingBundleIdentifier: self.pendingBundleIdentifier,
                    targetBundleIdentifier: target.bundleIdentifier
                ) else {
                    return
                }
                Self.log.error("Could not load Dock previews: \(error.localizedDescription, privacy: .public)")
                isLoadActive = false
                loadTask = nil
                hidePanel()
                currentBundleIdentifier = nil
                pendingBundleIdentifier = nil
            }
        }
    }

    private func makePreviewLoadState(
        axWindows: [DockAXWindow],
        shareableByID: [CGWindowID: SCWindow],
        pendingLookupWindowIDs: Set<CGWindowID>,
        target: DockAppTarget,
        now: TimeInterval
    ) -> PreviewLoadState {
        var previews: [DockWindowPreview] = []
        var captures: [ThumbnailCapture] = []
        for window in axWindows {
            let cacheKey = DockThumbnailCacheKey(
                bundleIdentifier: target.bundleIdentifier,
                processIdentifier: target.processIdentifier,
                windowID: window.windowID
            )
            let shareable = shareableByID[window.windowID]
            let frame = shareable?.frame
            let cached = thumbnailCache[cacheKey]
            let cacheDecision = DockThumbnailCachePolicy.decide(
                capturedAt: cached?.capturedAt,
                cachedFrame: cached?.windowFrame,
                currentFrame: frame,
                now: now,
                freshness: Self.thumbnailFreshness,
                retention: Self.thumbnailRetention,
                canCapture: shareable != nil
            )
            let displayImage = cacheDecision.displaysCachedImage
                ? cached?.image
                : nil
            let aspect = frame.map {
                $0.height > 0 ? $0.width / $0.height : 1.6
            } ?? displayImage.map {
                $0.height > 0
                    ? CGFloat($0.width) / CGFloat($0.height)
                    : 1.6
            } ?? 1.6
            let isStillResolving = pendingLookupWindowIDs.contains(
                window.windowID
            )
            previews.append(DockWindowPreview(
                id: window.windowID,
                title: window.title?.isEmpty == false
                    ? window.title!
                    : String(localized: "Untitled Window"),
                thumbnail: displayImage,
                thumbnailPlaceholder: shareable != nil || isStillResolving
                    ? .loading
                    : .unavailable,
                aspectRatio: aspect
            ))
            if cacheDecision.needsRefresh, let shareable {
                captures.append(ThumbnailCapture(
                    index: previews.count - 1,
                    key: cacheKey,
                    window: shareable
                ))
            }
        }
        return PreviewLoadState(previews: previews, captures: captures)
    }

    private func shareableWindows(
        for processIdentifier: pid_t,
        in snapshot: [ShareableWindowKey: SCWindow]
    ) -> [CGWindowID: SCWindow] {
        Dictionary(
            uniqueKeysWithValues: snapshot.compactMap { key, window in
                guard key.processIdentifier == processIdentifier else {
                    return nil
                }
                return (key.windowID, window)
            }
        )
    }

    /// ScreenCaptureKit has no per-application query. Keep a cheap on-screen
    /// snapshot as the common path, then request all windows only when AX says
    /// a real app window is missing (minimized, another Space, Stage Manager).
    /// Requests are single-flight per scope and outlive an individual hover so
    /// rapidly crossing Dock icons cannot create an enumeration storm.
    private func shareableWindowSnapshot(
        scope: DockShareableWindowSnapshotScope,
        requiredKeys: Set<ShareableWindowKey> = []
    ) async throws -> [ShareableWindowKey: SCWindow] {
        let now = ProcessInfo.processInfo.systemUptime
        let cached = cachedShareableSnapshots[scope]
        if let cached,
           now - cached.capturedAt < scope.freshness {
            let newlyUnresolved = DockShareableWindowLookupPolicy
                .newlyUnresolvedWindowIDs(
                    requiredWindowIDs: requiredKeys,
                    availableWindowIDs: Set(cached.windows.keys),
                    previouslyUnresolvedWindowIDs:
                        cached.unresolvedRequestedKeys
                )
            if newlyUnresolved.isEmpty {
                return cached.windows
            }
        }

        // Never infer completion from elapsed time. A slow WindowServer request
        // remains the one shared in-flight request until it actually finishes.
        if let request = shareableSnapshotRequests[scope] {
            return try await awaitShareableWindowSnapshot(
                request,
                scope: scope,
                requiredKeys: requiredKeys
            )
        }

        if let failure = shareableSnapshotFailures[scope],
           now - failure.failedAt < scope.freshness {
            if let cached {
                return cached.windows
            }
            throw failure.error
        }

        latestShareableSnapshotRequestIdentifier &+= 1
        let requestIdentifier = latestShareableSnapshotRequestIdentifier
        let onScreenWindowsOnly = scope.onScreenWindowsOnly
        let task = Task { @MainActor () throws -> ShareableWindowSnapshot in
            let content = try await SCShareableContent
                .excludingDesktopWindows(
                    true,
                    onScreenWindowsOnly: onScreenWindowsOnly
                )
            return ShareableWindowSnapshot(
                windows: Dictionary(
                    content.windows.compactMap { window in
                        guard let application = window.owningApplication else {
                            return nil
                        }
                        return (
                            ShareableWindowKey(
                                processIdentifier: application.processID,
                                windowID: window.windowID
                            ),
                            window
                        )
                    },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        }
        let request = ShareableWindowSnapshotRequest(
            identifier: requestIdentifier,
            task: task
        )
        shareableSnapshotRequests[scope] = request
        return try await awaitShareableWindowSnapshot(
            request,
            scope: scope,
            requiredKeys: requiredKeys
        )
    }

    private func awaitShareableWindowSnapshot(
        _ request: ShareableWindowSnapshotRequest,
        scope: DockShareableWindowSnapshotScope,
        requiredKeys: Set<ShareableWindowKey>
    ) async throws -> [ShareableWindowKey: SCWindow] {
        let snapshot: [ShareableWindowKey: SCWindow]
        do {
            snapshot = try await request.task.value.windows
        } catch {
            if shareableSnapshotRequests[scope]?.identifier
                == request.identifier {
                shareableSnapshotRequests[scope] = nil
                shareableSnapshotFailures[scope] =
                    ShareableWindowSnapshotFailure(
                        failedAt: ProcessInfo.processInfo.systemUptime,
                        error: error
                    )
            }
            try Task.checkCancellation()
            throw error
        }

        let isCurrentRequest = shareableSnapshotRequests[scope]?.identifier
            == request.identifier
        if isCurrentRequest {
            let unresolved = requiredKeys.subtracting(snapshot.keys)
            if var cached = cachedShareableSnapshots[scope],
               cached.requestIdentifier == request.identifier {
                cached.unresolvedRequestedKeys.formUnion(unresolved)
                cachedShareableSnapshots[scope] = cached
            } else {
                let previouslyUnresolved = cachedShareableSnapshots[scope]?
                    .unresolvedRequestedKeys ?? []
                let unresolved = DockShareableWindowLookupPolicy
                    .unresolvedWindowIDs(
                        previouslyUnresolvedWindowIDs: previouslyUnresolved,
                        requiredWindowIDs: requiredKeys,
                        availableWindowIDs: Set(snapshot.keys)
                    )
                cachedShareableSnapshots[scope] =
                    CachedShareableWindowSnapshot(
                        requestIdentifier: request.identifier,
                        windows: snapshot,
                        capturedAt: ProcessInfo.processInfo.systemUptime,
                        unresolvedRequestedKeys: unresolved
                    )
            }
            shareableSnapshotFailures[scope] = nil
            shareableSnapshotRequests[scope] = nil
        } else if var cached = cachedShareableSnapshots[scope],
                  cached.requestIdentifier == request.identifier {
            // A second waiter on the same completed request may carry a
            // different target's negative-miss keys. Merge them without
            // replacing a newer snapshot.
            cached.unresolvedRequestedKeys = DockShareableWindowLookupPolicy
                .unresolvedWindowIDs(
                    previouslyUnresolvedWindowIDs:
                        cached.unresolvedRequestedKeys,
                    requiredWindowIDs: requiredKeys,
                    availableWindowIDs: Set(snapshot.keys)
                )
            cachedShareableSnapshots[scope] = cached
        }
        // The shared ScreenCaptureKit request intentionally completes and warms
        // the cache even if this particular hover has become obsolete.
        try Task.checkCancellation()
        return snapshot
    }

    private func pruneThumbnailCache(now: TimeInterval) {
        thumbnailCache = thumbnailCache.filter {
            now - $0.value.capturedAt < Self.thumbnailRetention
        }
        guard thumbnailCache.count > 40 else { return }
        let newest = thumbnailCache
            .sorted { $0.value.capturedAt > $1.value.capturedAt }
            .prefix(40)
        thumbnailCache = Dictionary(
            uniqueKeysWithValues: newest.map { ($0.key, $0.value) }
        )
    }

    private func present(
        previews: [DockWindowPreview],
        target: DockAppTarget,
        appIcon: NSImage?
    ) {
        panelController.present(
            appName: target.appName,
            appIcon: appIcon,
            windows: previews,
            near: target.pointerLocation
        ) { [weak self] windowID in
            self?.activate(target: target, windowID: windowID)
        } onClose: { [weak self] windowID in
            self?.close(target: target, windowID: windowID)
        }
        syncPanelFrame()
    }

    private func captureThumbnail(_ window: SCWindow) async -> CGImage? {
        do {
            return try await thumbnailCaptureGate.run {
                await Self.performThumbnailCapture(window)
            }
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    private static func performThumbnailCapture(
        _ window: SCWindow
    ) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        // Cap both axes. The old width-only scale produced very tall captures
        // for portrait windows even though the tile is only 140 points high.
        let scale = min(
            1,
            420 / max(window.frame.width, 1),
            280 / max(window.frame.height, 1)
        )
        configuration.width = Int(max(1, window.frame.width * scale))
        configuration.height = Int(max(1, window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
        } catch {
            log.debug(
                "Could not capture Dock window \(window.windowID): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func activate(
        target: DockAppTarget,
        windowID: CGWindowID
    ) {
        hidePanel()
        cancelPendingLoad()
        pendingBundleIdentifier = nil
        currentBundleIdentifier = nil
        // Raise the ONE chosen window off-main, then activate without
        // .activateAllWindows — that flag pulls every window forward and
        // buries the selection under whatever was frontmost before.
        axWorker.submitRaise(
            processIdentifier: target.processIdentifier,
            windowID: windowID
        ) { _ in
            NSRunningApplication(processIdentifier: target.processIdentifier)?
                .activate(options: [])
        }
    }

    private func close(
        target: DockAppTarget,
        windowID: CGWindowID
    ) {
        // Stop a thumbnail result captured before the close click from putting
        // the removed window back into the panel while AX handles the action.
        cancelPendingLoad()
        pendingBundleIdentifier = nil
        closingWindowRegistry.markClosing(
            bundleIdentifier: target.bundleIdentifier,
            processIdentifier: target.processIdentifier,
            windowID: windowID,
            now: ProcessInfo.processInfo.systemUptime,
            gracePeriod: 1.5
        )
        if currentBundleIdentifier == target.bundleIdentifier,
           panelController.removeWindow(windowID: windowID) {
            // This is deliberately optimistic: the real window should leave
            // the preview on the click, not after another process answers AX.
            syncPanelFrame()
        }
        thumbnailCache[DockThumbnailCacheKey(
            bundleIdentifier: target.bundleIdentifier,
            processIdentifier: target.processIdentifier,
            windowID: windowID
        )] = nil
        axWorker.submitClose(
            processIdentifier: target.processIdentifier,
            windowID: windowID
        ) { [weak self] _ in
            guard let self else { return }
            // AX can report a failure even after the target app has acted, so
            // the real window list is the authority. Reconcile once quickly,
            // while the tombstone blocks stale AX data, and once after its
            // expiry so an unsaved-document veto restores the tile.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self,
                      !self.isSuspended,
                      self.settings.dockPreviewEnabled,
                      self.currentBundleIdentifier
                        == target.bundleIdentifier else { return }
                self.loadAndPresent(target: target)
                try? await Task.sleep(for: .milliseconds(1_300))
                guard !Task.isCancelled,
                      !self.isSuspended,
                      self.settings.dockPreviewEnabled,
                      self.currentBundleIdentifier
                        == target.bundleIdentifier else { return }
                self.loadAndPresent(target: target)
            }
        }
    }
}
