import ServiceManagement
import SwiftUI

/// Settings: animation, status text, sound, launch at login, reinstall hooks, About.
///
/// Six controls, one screen, no scrolling on a normal display. Everything else
/// the app does is automatic.
struct SettingsPane: View {
    let onReinstallHooks: () -> Void

    @State private var prefs = Preferences.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var hookStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spaceL) {
            group("Menu bar") {
                settingToggle("Animate the icon", $prefs.animationEnabled)
                settingToggle("Show status as text", $prefs.showStatusText)
                settingToggle("Play a sound when a turn finishes", $prefs.playSoundOnDone)
            }

            Divider()

            group("General") {
                settingToggle("Launch at login", $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLogin.set(enabled)
                        // Reflect what actually happened: the request can be
                        // refused, and a toggle that lies is worse than one
                        // that flips back.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }

                HStack(spacing: Metrics.spaceM) {
                    Button {
                        onReinstallHooks()
                        hookStatus = HookInstaller.isInstalled
                            ? "Hooks installed."
                            : "Could not install hooks."
                    } label: {
                        Text("Reinstall hooks").font(Typography.body)
                    }
                    if let hookStatus {
                        Text(hookStatus)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
            }

            Divider()

            group("About") {
                HStack(spacing: Metrics.spaceL) {
                    BrandMark(size: Metrics.aboutMarkSize)
                    VStack(alignment: .leading, spacing: Metrics.spaceXS) {
                        Text("Claude Watch \(appVersion)")
                            .font(Typography.body)
                        // Required disclaimer, in the preferences footer and About.
                        Text("Not affiliated with Anthropic.")
                            .font(Typography.disclaimer)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
            }
        }
        .padding(Metrics.spaceL)
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(Typography.body)
    }

    /// A settings row: label on the left, control hard against the right edge,
    /// so every control lines up in one column rather than tracking its label.
    private func settingToggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title)
                .font(Typography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View)
        -> some View {
        VStack(alignment: .leading, spacing: Metrics.spaceM) {
            Text(title)
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.secondaryText)
            content()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

/// Launch at login via `SMAppService`. No helper bundle, no login item plist.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration can fail for an unsigned or quarantined build. The
            // caller re-reads `isEnabled`, so the toggle reflects reality.
        }
    }
}
