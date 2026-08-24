import SwiftUI

/// Visual themes for the hover preview panel. Each theme only overrides colors,
/// corner radius, an optional blur material, and (when it is inherently dark or
/// light) a forced color scheme so text and placeholders stay legible.
enum DockPreviewTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case graphite
    case frost
    case vibrant

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .graphite: "Graphite"
        case .frost: "Frost"
        case .vibrant: "Vibrant"
        }
    }

    /// Forces the panel's SwiftUI color scheme when the theme is committed to a
    /// look; `nil` follows the system so `.primary`/`.secondary` adapt normally.
    var colorScheme: ColorScheme? {
        switch self {
        case .system, .vibrant: nil
        case .graphite: .dark
        case .frost: .light
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .system, .frost: 14
        case .graphite: 16
        case .vibrant: 18
        }
    }

    /// A blur material drawn behind the fill. Only the opt-in Vibrant theme uses
    /// one — a live material forces WindowServer to re-composite the whole panel
    /// while thumbnails change, which the solid themes deliberately avoid.
    var material: Material? {
        switch self {
        case .vibrant: .ultraThinMaterial
        default: nil
        }
    }

    var panelFill: Color {
        switch self {
        case .system: Color(nsColor: .windowBackgroundColor).opacity(0.97)
        case .graphite: Color(white: 0.16).opacity(0.98)
        case .frost: Color.white.opacity(0.92)
        case .vibrant: Color(nsColor: .windowBackgroundColor).opacity(0.35)
        }
    }

    var panelStroke: Color {
        switch self {
        case .system: .white.opacity(0.15)
        case .graphite: .white.opacity(0.10)
        case .frost: .black.opacity(0.10)
        case .vibrant: .white.opacity(0.25)
        }
    }

    var tileFill: Color {
        switch self {
        case .system: .black.opacity(0.08)
        case .graphite: .black.opacity(0.25)
        case .frost: .black.opacity(0.05)
        case .vibrant: .black.opacity(0.12)
        }
    }

    var tileStroke: Color {
        switch self {
        case .frost: .black.opacity(0.12)
        default: .white.opacity(0.12)
        }
    }

    var hoverStroke: Color {
        .accentColor
    }
}

/// Live, observable source of the current theme. The preview panel's SwiftUI
/// view observes it, so changing the theme restyles a panel that is already on
/// screen without touching the (verbatim) preview controller.
@MainActor
final class DockPreviewThemeStore: ObservableObject {
    static let shared = DockPreviewThemeStore()
    @Published var theme: DockPreviewTheme = .system
    private init() {}
}

extension View {
    /// Applies a forced color scheme only when the theme commits to one.
    @ViewBuilder
    func themedColorScheme(_ scheme: ColorScheme?) -> some View {
        if let scheme {
            environment(\.colorScheme, scheme)
        } else {
            self
        }
    }
}
