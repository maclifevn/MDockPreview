import AppKit
import SwiftUI

enum SwitcherMetrics {
    static let tileWidth: CGFloat = 200
    static let thumbnailHeight: CGFloat = 118
    static let titleHeight: CGFloat = 18
    static let tileSpacing: CGFloat = 14
    static let padding: CGFloat = 22
    static let headerHeight: CGFloat = 44
    static let maxColumns = 5

    static var rowHeight: CGFloat {
        thumbnailHeight + titleHeight + 8 /* inner */ + 12 /* tile padding */
    }
}

/// A centered, non-activating panel that shows the switcher grid. It never
/// takes key focus — the hotkey monitor drives selection and the target window
/// is only raised on commit.
@MainActor
final class SwitcherPanelController {
    let model = SwitcherModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<SwitcherView>?

    func show(on screen: NSScreen?) {
        let panel = panel ?? makePanel()
        if hosting == nil {
            let view = NSHostingView(rootView: SwitcherView(model: model))
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            hosting = view
        }

        let count = model.windows.count
        let columns = fittingColumns(count: count, screen: screen)
        model.columns = columns
        let size = panelSize(columns: columns, count: count)

        panel.setContentSize(size)
        if let frame = (screen ?? NSScreen.main)?.frame {
            panel.setFrameOrigin(CGPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() { panel?.orderOut(nil) }

    private func fittingColumns(count: Int, screen: NSScreen?) -> Int {
        let maxWidth = ((screen ?? NSScreen.main)?.frame.width ?? 1440) * 0.9
        var columns = max(1, min(SwitcherMetrics.maxColumns, count))
        while columns > 1 {
            let width = CGFloat(columns) * SwitcherMetrics.tileWidth
                + CGFloat(columns - 1) * SwitcherMetrics.tileSpacing
                + SwitcherMetrics.padding * 2
            if width <= maxWidth { break }
            columns -= 1
        }
        return columns
    }

    private func panelSize(columns: Int, count: Int) -> NSSize {
        let rows = max(1, Int(ceil(Double(count) / Double(max(1, columns)))))
        let width = CGFloat(columns) * SwitcherMetrics.tileWidth
            + CGFloat(columns - 1) * SwitcherMetrics.tileSpacing
            + SwitcherMetrics.padding * 2
        let height = SwitcherMetrics.headerHeight
            + CGFloat(rows) * SwitcherMetrics.rowHeight
            + CGFloat(rows - 1) * SwitcherMetrics.tileSpacing
            + SwitcherMetrics.padding * 2
        return NSSize(width: width, height: height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
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
}

// MARK: - SwiftUI

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject private var themeStore = DockPreviewThemeStore.shared

    var body: some View {
        let theme = themeStore.theme
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(model.selectedAppName)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.selectedTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(height: SwitcherMetrics.headerHeight)
            .frame(maxWidth: .infinity)

            LazyVGrid(columns: gridColumns, spacing: SwitcherMetrics.tileSpacing) {
                ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                    SwitcherTile(
                        window: window,
                        selected: index == model.selectedIndex,
                        theme: theme
                    )
                }
            }
        }
        .padding(SwitcherMetrics.padding)
        .background {
            ZStack {
                if let material = theme.material {
                    RoundedRectangle(cornerRadius: theme.cornerRadius).fill(material)
                }
                RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.panelFill)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.panelStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .themedColorScheme(theme.colorScheme)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(SwitcherMetrics.tileWidth), spacing: SwitcherMetrics.tileSpacing),
            count: max(1, model.columns)
        )
    }
}

private struct SwitcherTile: View {
    let window: SwitcherWindow
    let selected: Bool
    let theme: DockPreviewTheme

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                theme.tileFill
                if let thumbnail = window.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if let icon = window.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 46, height: 46)
                }
            }
            .frame(width: SwitcherMetrics.tileWidth - 12, height: SwitcherMetrics.thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? theme.hoverStroke : theme.tileStroke,
                            lineWidth: selected ? 3 : 1)
            }

            HStack(spacing: 5) {
                if let icon = window.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(window.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(height: SwitcherMetrics.titleHeight)
            .frame(maxWidth: SwitcherMetrics.tileWidth - 12)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? theme.hoverStroke.opacity(0.15) : Color.clear)
        }
    }
}
