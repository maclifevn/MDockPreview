import AppKit
import SwiftUI

/// Hosts the tabbed Settings window. Everything that used to live in the
/// menu-bar menu — theme, launch at login, permissions — now lives here, plus
/// the option to hide the menu-bar icon and an About/Donate tab.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings
    private let onReopenWelcome: () -> Void

    init(settings: AppSettings, onReopenWelcome: @escaping () -> Void) {
        self.settings = settings
        self.onReopenWelcome = onReopenWelcome
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsView(settings: settings, onReopenWelcome: onReopenWelcome)
        let hosting = NSHostingController(rootView: root)
        // Let the window follow the selected tab's natural height, so each pane
        // fits snugly instead of sharing one tall fixed frame.
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("MDock Preview Settings", comment: "window title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Root

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, permissions, about
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }
}

private struct SettingsView: View {
    let settings: AppSettings
    let onReopenWelcome: () -> Void
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // A toolbar-style segmented switcher instead of TabView's bordered
            // box (whose stray top border showed on either side of the tabs).
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            content
        }
        // Fixed width; height follows the selected tab's content via the hosting
        // controller's preferredContentSize sizing.
        .frame(width: 540)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general: GeneralTab(settings: settings)
        case .appearance: AppearanceTab(settings: settings)
        case .permissions: PermissionsTab(onReopenWelcome: onReopenWelcome)
        case .about: AboutTab()
        }
    }
}

// MARK: - Reusable building blocks

private struct TabContainer<Content: View>: View {
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        // No ScrollView: the content reports its natural height so the window
        // can size to fit each tab exactly.
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            SettingsCard { content }
        }
    }
}

private struct SettingRow<Trailing: View>: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: Trailing

    init(
        icon: String,
        color: Color,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.gradient)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private var rowDivider: some View {
    Divider().padding(.leading, 54)
}

// MARK: - General

private struct GeneralTab: View {
    let settings: AppSettings
    @State private var previewsEnabled: Bool
    @State private var launchAtLogin: Bool
    @State private var showMenuBarIcon: Bool

    init(settings: AppSettings) {
        self.settings = settings
        _previewsEnabled = State(initialValue: settings.dockPreviewEnabled)
        _launchAtLogin = State(initialValue: LaunchAtLoginManager.isEnabled)
        _showMenuBarIcon = State(initialValue: settings.showMenuBarIcon)
    }

    var body: some View {
        TabContainer {
            SettingsSection("Dock previews") {
                SettingRow(
                    icon: "rectangle.stack.fill", color: .blue,
                    title: "Show window previews",
                    subtitle: "Show a preview panel when you hover a Dock icon"
                ) {
                    Toggle("", isOn: $previewsEnabled)
                        .labelsHidden().toggleStyle(.switch)
                        .onChange(of: previewsEnabled) { _, v in settings.dockPreviewEnabled = v }
                }
                rowDivider
                SettingRow(
                    icon: "power", color: .green,
                    title: "Launch at login",
                    subtitle: "Open MDock Preview automatically when you sign in."
                ) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden().toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, v in
                            LaunchAtLoginManager.setEnabled(v)
                            launchAtLogin = LaunchAtLoginManager.isEnabled
                            if v, LaunchAtLoginManager.requiresApproval {
                                LaunchAtLoginManager.openLoginItemsSettings()
                            }
                        }
                }
            }

            SettingsSection("Menu bar") {
                SettingRow(
                    icon: "menubar.rectangle", color: .purple,
                    title: "Show icon in menu bar",
                    subtitle: "If hidden, relaunch the app to reopen Settings"
                ) {
                    Toggle("", isOn: $showMenuBarIcon)
                        .labelsHidden().toggleStyle(.switch)
                        .onChange(of: showMenuBarIcon) { _, v in settings.showMenuBarIcon = v }
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    let settings: AppSettings
    @State private var theme: DockPreviewTheme

    init(settings: AppSettings) {
        self.settings = settings
        _theme = State(initialValue: settings.previewTheme)
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        TabContainer {
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview theme")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                Text("Applies to the window-preview panel. Changes take effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(DockPreviewTheme.allCases) { option in
                    ThemeCard(theme: option, selected: option == theme) {
                        theme = option
                        settings.previewTheme = option
                    }
                }
            }
        }
    }
}

private struct ThemeCard: View {
    let theme: DockPreviewTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ThemeMiniPreview(theme: theme)
                HStack(spacing: 6) {
                    Text(theme.displayName).font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.35))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

/// A miniature of the real preview panel so each theme reads at a glance.
private struct ThemeMiniPreview: View {
    let theme: DockPreviewTheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.tileFill)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.tileStroke, lineWidth: 1))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 68)
        .background {
            ZStack {
                if let material = theme.material {
                    RoundedRectangle(cornerRadius: 11).fill(material)
                }
                RoundedRectangle(cornerRadius: 11).fill(theme.panelFill)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.panelStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .themedColorScheme(theme.colorScheme)
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    let onReopenWelcome: () -> Void

    var body: some View {
        TabContainer {
            VStack(alignment: .leading, spacing: 6) {
                Text("Required permissions")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                Text("MDock Preview needs these to show live window previews. Toggle them in System Settings and the status updates here automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionsView()

            Button { onReopenWelcome() } label: {
                Label("Open Setup Guide", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        TabContainer {
            appOverview
            donateSection
            footer
        }
    }

    private var appOverview: some View {
        SettingsCard {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 66, height: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MDock Preview").font(.title2.weight(.bold))
                    Text(versionText).font(.caption).foregroundStyle(.tertiary)
                    Text("Live window previews from your Dock.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Label("Private", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private var donateSection: some View {
        SettingsSection("Support development ☕") {
            HStack(alignment: .center, spacing: 14) {
                if let qr = Self.donateQRCode {
                    Image(nsImage: qr)
                        .resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                        .accessibilityLabel("Donation QR code")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("If MDock Preview is useful to you, a small coffee helps keep the project maintained and growing. Thank you! 🙏")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Scan with MoMo or a banking app (VietQR · Napas 247)")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack(spacing: 3) {
            Text("Made with ❤️ for").foregroundStyle(.secondary)
            Link(
                "Maclife & Đồng Bọn",
                destination: URL(string: "https://www.facebook.com/groups/maclife.vn")!
            )
        }
        .font(.caption)
        .padding(.leading, 4)
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return String(format: NSLocalizedString("Version %@ (%@)", comment: "about"), short, build)
    }

    private static let donateQRCode: NSImage? = {
        guard let url = Bundle.main.url(forResource: "donate-qr", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
