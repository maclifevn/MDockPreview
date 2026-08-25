import CoreGraphics

/// The holding modifier that arms the switcher (held + Tab, release to commit).
/// `.command` overrides the system Command-Tab app switcher — the tap consumes
/// the real ⌘Tab keystroke, AltTab-style.
enum SwitcherModifier: String, CaseIterable, Identifiable, Sendable {
    case command
    case option
    case control

    var id: String { rawValue }

    var flag: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .option: .maskAlternate
        case .control: .maskControl
        }
    }

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        }
    }

    /// e.g. "⌘ Tab" — shown in the shortcut picker.
    var chordLabel: String { "\(symbol) Tab" }
}
