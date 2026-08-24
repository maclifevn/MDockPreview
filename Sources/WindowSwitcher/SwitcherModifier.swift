import CoreGraphics

/// The holding modifier that arms the ⌥Tab-style switcher. `.command` is
/// intentionally absent: macOS reserves ⌘Tab for its own app switcher and a
/// session event tap cannot take it over (AltTab defaults to ⌥Tab for the same
/// reason).
enum SwitcherModifier: String, CaseIterable, Identifiable, Sendable {
    case option
    case control

    var id: String { rawValue }

    var flag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .control: .maskControl
        }
    }

    var symbol: String {
        switch self {
        case .option: "⌥"
        case .control: "⌃"
        }
    }

    /// e.g. "⌥ Tab" — shown in the shortcut picker.
    var chordLabel: String { "\(symbol) Tab" }
}
