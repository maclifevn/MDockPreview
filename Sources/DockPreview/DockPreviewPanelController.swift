import AppKit
import Combine
import SwiftUI

enum DockThumbnailPlaceholder: Equatable {
    /// A capture is in flight. Keep this static so a row of windows does not
    /// create a row of independent spinner/shimmer animations.
    case loading
    /// ScreenCaptureKit cannot currently provide an image for this window.
    case unavailable
}

struct DockWindowPreview: Identifiable {
    let id: CGWindowID
    let title: String
    /// ScreenCaptureKit already returns a CGImage. Keeping it in that form
    /// avoids wrapping it in NSImage only for SwiftUI to synchronously convert
    /// it back to CGImage on every hover-driven body update.
    let thumbnail: CGImage?
    let thumbnailPlaceholder: DockThumbnailPlaceholder
    /// Source window width/height; tiles share one height and take their
    /// width from this, so portrait windows get no gray side bars.
    let aspectRatio: CGFloat

    init(
        id: CGWindowID,
        title: String,
        thumbnail: CGImage?,
        thumbnailPlaceholder: DockThumbnailPlaceholder = .unavailable,
        aspectRatio: CGFloat
    ) {
        self.id = id
        self.title = title
        self.thumbnail = thumbnail
        self.thumbnailPlaceholder = thumbnailPlaceholder
        self.aspectRatio = aspectRatio
    }

    var tileWidth: CGFloat {
        min(max(aspectRatio * DockPreviewMetrics.thumbnailHeight, 90), 260)
    }
}

@MainActor
private final class DockPreviewPanelModel: ObservableObject {
    struct Presentation {
        let appName: String
        let appIcon: NSImage?
        let windows: [DockWindowPreview]
        let onSelect: (CGWindowID) -> Void
        let onClose: (CGWindowID) -> Void

        @MainActor static let empty = Presentation(
            appName: "",
            appIcon: nil,
            windows: [],
            onSelect: { _ in },
            onClose: { _ in }
        )
    }

    @Published var presentation = Presentation.empty
}

@MainActor
final class DockPreviewPanelController {
    private var panel: NSPanel?
    private let model = DockPreviewPanelModel()
    private var hostingView: NSHostingView<DockPreviewPanelView>?
    private var lastPointer: CGPoint?

    var frame: CGRect? {
        guard panel?.isVisible == true else { return nil }
        return panel?.frame
    }

    var hostingViewIdentifierForTesting: ObjectIdentifier? {
        guard let hostingView,
              panel?.contentView === hostingView else { return nil }
        return ObjectIdentifier(hostingView)
    }

    var windowIDsForTesting: [CGWindowID] {
        model.presentation.windows.map(\.id)
    }

    func present(
        appName: String,
        appIcon: NSImage?,
        windows: [DockWindowPreview],
        near pointer: CGPoint,
        onSelect: @escaping (CGWindowID) -> Void,
        onClose: @escaping (CGWindowID) -> Void
    ) {
        guard !windows.isEmpty else {
            hide()
            return
        }
        let size = panelSize(for: windows)
        let panel = panel ?? makePanel()
        if hostingView == nil {
            let hostingView = NSHostingView(
                rootView: DockPreviewPanelView(model: model)
            )
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            self.hostingView = hostingView
        }
        // Update one persistent hosting tree. Replacing NSHostingView here
        // forced SwiftUI, Core Animation, every thumbnail, and the material
        // backdrop to be rebuilt each time the pointer revisited the Dock.
        model.presentation = DockPreviewPanelModel.Presentation(
            appName: appName,
            appIcon: appIcon,
            windows: windows,
            onSelect: onSelect,
            onClose: onClose
        )
        lastPointer = pointer
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: panel.frame.size, pointer: pointer))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Removes a closed window from the live SwiftUI model immediately. AX
    /// discovery still refreshes afterwards, but the user never has to wait
    /// for another process's window list to catch up before the tile vanishes.
    @discardableResult
    func removeWindow(windowID: CGWindowID) -> Bool {
        let presentation = model.presentation
        let remaining = presentation.windows.filter { $0.id != windowID }
        guard remaining.count != presentation.windows.count else { return false }
        model.presentation = DockPreviewPanelModel.Presentation(
            appName: presentation.appName,
            appIcon: presentation.appIcon,
            windows: remaining,
            onSelect: presentation.onSelect,
            onClose: presentation.onClose
        )
        guard !remaining.isEmpty else {
            hide()
            return true
        }
        guard let panel else { return true }
        panel.setContentSize(panelSize(for: remaining))
        if let lastPointer {
            panel.setFrameOrigin(
                origin(for: panel.frame.size, pointer: lastPointer)
            )
        }
        return true
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func panelSize(for windows: [DockWindowPreview]) -> NSSize {
        // The panel hugs its content exactly — any fixed minimum width leaves
        // dead space beside the tiles and the row reads as off-center.
        let contentWidth = windows.reduce(CGFloat(0)) { $0 + $1.tileWidth }
            + CGFloat(max(windows.count - 1, 0))
                * DockPreviewMetrics.tileSpacing
        return NSSize(
            width: min(contentWidth + DockPreviewMetrics.padding * 2, 760),
            height: DockPreviewMetrics.panelHeight
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 210),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        return panel
    }

    private func origin(for size: CGSize, pointer: CGPoint) -> CGPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let screen else { return pointer }
        let frame = screen.frame
        let distances = [
            ("left", abs(pointer.x - frame.minX)),
            ("right", abs(frame.maxX - pointer.x)),
            ("bottom", abs(pointer.y - frame.minY)),
        ]
        let edge = distances.min(by: { $0.1 < $1.1 })?.0 ?? "bottom"
        var point: CGPoint
        switch edge {
        case "left":
            point = CGPoint(x: pointer.x + 46, y: pointer.y - size.height / 2)
        case "right":
            point = CGPoint(x: pointer.x - size.width - 46, y: pointer.y - size.height / 2)
        default:
            point = CGPoint(x: pointer.x - size.width / 2, y: pointer.y + 46)
        }
        point.x = min(max(point.x, frame.minX + 8), frame.maxX - size.width - 8)
        point.y = min(max(point.y, frame.minY + 8), frame.maxY - size.height - 8)
        return point
    }
}

enum DockPreviewMetrics {
    /// Reference width for aspect fallbacks.
    static let tileWidth: CGFloat = 210
    static let thumbnailHeight: CGFloat = 125
    static let titleRowHeight: CGFloat = 18
    static let tileSpacing: CGFloat = 10
    static let padding: CGFloat = 14

    static var panelHeight: CGFloat {
        padding * 2 + titleRowHeight + 6 + thumbnailHeight
    }
}

/// Windows-taskbar style: no panel header — each tile carries its own
/// icon + window title above the thumbnail, so the row is symmetric and the
/// identity is per-window, not per-app.
private struct DockPreviewPanelView: View {
    @ObservedObject var model: DockPreviewPanelModel
    @ObservedObject private var themeStore = DockPreviewThemeStore.shared

    var body: some View {
        let presentation = model.presentation
        let theme = themeStore.theme
        ScrollView(.horizontal, showsIndicators: presentation.windows.count > 3) {
            HStack(spacing: DockPreviewMetrics.tileSpacing) {
                ForEach(presentation.windows) { window in
                    DockPreviewTileView(
                        appIcon: presentation.appIcon,
                        window: window,
                        theme: theme,
                        onSelect: presentation.onSelect,
                        onClose: presentation.onClose
                    )
                }
            }
        }
        .padding(DockPreviewMetrics.padding)
        // Solid themes keep a nearly opaque fill so WindowServer does not have
        // to re-composite the whole panel while thumbnails change. Only the
        // opt-in Vibrant theme layers a live blur material behind that fill.
        .background {
            ZStack {
                if let material = theme.material {
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(material)
                }
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .fill(theme.panelFill)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.panelStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .themedColorScheme(theme.colorScheme)
        .accessibilityLabel(presentation.appName)
    }
}

private struct DockPreviewTileView: View {
    let appIcon: NSImage?
    let window: DockWindowPreview
    let theme: DockPreviewTheme
    let onSelect: (CGWindowID) -> Void
    let onClose: (CGWindowID) -> Void

    /// Hover state belongs to one tile. The old parent-level hoveredID made
    /// every border, title, icon, and thumbnail in the row recompute whenever
    /// the pointer crossed a tile boundary.
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onSelect(window.id)
            } label: {
                VStack(spacing: 6) {
                    HStack(spacing: 5) {
                        if let appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                        Text(window.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    // Reserve the close-button column even before hover so a
                    // long title never slides underneath it or jumps sideways.
                    .padding(.trailing, 23)
                    .frame(
                        width: window.tileWidth,
                        height: DockPreviewMetrics.titleRowHeight
                    )
                    Group {
                        if let thumbnail = window.thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .scaledToFit()
                        } else {
                            switch window.thumbnailPlaceholder {
                            case .loading:
                                // A neutral skeleton communicates that content is
                                // pending without briefly showing the capture-error
                                // glyph on every ordinary cold hover.
                                Color.secondary.opacity(0.10)
                            case .unavailable:
                                ZStack {
                                    Color.secondary.opacity(0.10)
                                    Image(systemName: "rectangle.on.rectangle.slash")
                                        .font(.title)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(
                        width: window.tileWidth,
                        height: DockPreviewMetrics.thumbnailHeight
                    )
                    .background(theme.tileFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isHovered
                                    ? theme.hoverStroke
                                    : theme.tileStroke,
                                lineWidth: isHovered ? 2 : 1
                            )
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                onClose(window.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.red, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Close Window"))
            .accessibilityLabel(String(localized: "Close Window"))
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(!isHovered)
        }
        // Spacer and the transparent title-row area do not contribute a
        // default SwiftUI hit region. Without an explicit shape, moving from
        // the thumbnail toward the close button exits hover and hides the
        // button before it can be clicked.
        .contentShape(Rectangle())
        .onHover { inside in
            if isHovered != inside {
                isHovered = inside
            }
        }
    }
}
