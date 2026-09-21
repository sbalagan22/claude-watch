import AppKit
import SwiftUI

/// Menu-bar-only app. `LSUIElement` is true in Info.plist, so there is no Dock
/// icon and no menu bar of its own.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: the Info.plist sets LSUIElement, but a stray
        // activation policy would put an icon in the Dock.
        NSApp.setActivationPolicy(.accessory)
        controller = StatusItemController()
        controller?.start()

        // A menu bar app with no window gives a first-time user nothing to
        // look at, and without hooks it shows nothing at all. So the welcome
        // window appears on first launch, and again any time the hooks are
        // missing — that second case is the one that actually matters.
        if let controller,
           !Preferences.shared.hasSeenOnboarding || !HookInstaller.isInstalled {
            let onboarding = OnboardingWindowController(model: controller.model)
            self.onboarding = onboarding
            onboarding.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

@main
enum ClaudeWatchMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
