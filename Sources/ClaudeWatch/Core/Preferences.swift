import Foundation
import Observation

/// The settings menu, persisted in UserDefaults.
///
/// Deliberately small: animation, status text, completion sound, launch at login. Settings for
/// a menu bar utility should fit one screen with room to spare, so anything
/// that existed because it was easy rather than because someone would change it
/// has been cut.
///
/// Removed on purpose: the spinner style picker (D38 — one spin, no
/// alternates), and the accent and glow toggles. The icon system fixes which
/// states carry colour (only the three asking for attention) and what the done
/// gesture is; making those user-tunable would let a user configure the app
/// into a state the spec calls wrong, and nobody would go looking for either.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let animationEnabled = "animationEnabled"
        static let showStatusText = "showStatusText"
        static let playSoundOnDone = "playSoundOnDone"
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let hasRequestedAccessibility = "hasRequestedAccessibility"
    }

    private let defaults = UserDefaults.standard

    /// Master animation switch, independent of the system Reduce Motion
    /// setting. Off means every state shows its designed static frame.
    var animationEnabled: Bool {
        didSet { defaults.set(animationEnabled, forKey: Key.animationEnabled) }
    }

    /// Show the state as a word beside the glyph — "Working", "Needs you",
    /// "Done", "Failed". Off by default: the glyph is designed to carry the
    /// state on its own, but some people want to read it rather than learn it.
    /// Idle shows no text either way, so a quiet bar stays quiet.
    var showStatusText: Bool {
        didSet { defaults.set(showStatusText, forKey: Key.showStatusText) }
    }

    /// Play a short sound when a session finishes a turn. On by default: the
    /// glyph is peripheral by design, and a finish is the one event people
    /// most often want to hear about while looking at something else.
    var playSoundOnDone: Bool {
        didSet { defaults.set(playSoundOnDone, forKey: Key.playSoundOnDone) }
    }

    /// The welcome window has been dismissed once. It still reappears if the
    /// hooks go missing, because without them the app shows nothing.
    var hasSeenOnboarding: Bool {
        didSet { defaults.set(hasSeenOnboarding, forKey: Key.hasSeenOnboarding) }
    }

    /// The Accessibility permission prompt has been shown once. Focusing an
    /// IDE window by title needs it; without it a click still reaches the
    /// right app.
    var hasRequestedAccessibility: Bool {
        didSet { defaults.set(hasRequestedAccessibility, forKey: Key.hasRequestedAccessibility) }
    }

    private init() {
        defaults.register(defaults: [
            Key.animationEnabled: true,
            Key.showStatusText: false,
            Key.playSoundOnDone: true,
            Key.hasSeenOnboarding: false,
            Key.hasRequestedAccessibility: false,
        ])
        animationEnabled = defaults.bool(forKey: Key.animationEnabled)
        showStatusText = defaults.bool(forKey: Key.showStatusText)
        playSoundOnDone = defaults.bool(forKey: Key.playSoundOnDone)
        hasSeenOnboarding = defaults.bool(forKey: Key.hasSeenOnboarding)
        hasRequestedAccessibility = defaults.bool(forKey: Key.hasRequestedAccessibility)
    }
}
