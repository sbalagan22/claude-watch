import SwiftUI

/// The palette. Nothing outside this file defines a colour.
///
/// Claude orange is the single accent and appears only on the states that earn
/// it: a session needing you, and a session that just finished. Idle is
/// monochrome so the icon is indistinguishable from a system glyph.
enum Palette {
    // Brand
    static let accent     = Color(hex: 0xD9_77_57)   // Claude orange
    static let dark       = Color(hex: 0x14_14_13)
    static let light      = Color(hex: 0xFA_F9_F5)
    static let midGray    = Color(hex: 0xB0_AE_A5)
    static let lightGray  = Color(hex: 0xE8_E6_DC)

    /// Muted red for the failed state. Deliberately desaturated: a failure is
    /// informational, not an alarm, and a vivid red next to the orange accent
    /// reads as a second brand colour.
    static let failure    = Color(hex: 0xC2_56_4A)

    // Semantic. These resolve per appearance via the asset-free dynamic colours below.
    static let primaryText   = Color.primary
    static let secondaryText = Color.secondary
    static let separator     = Color(nsColor: .separatorColor)
    static let panelBackground = Color(nsColor: .windowBackgroundColor)
    static let rowHighlight  = Color(nsColor: .selectedContentBackgroundColor)

    /// State dot colours, by session state.
    ///
    /// Orange marks the two states that are *about the user*: one needing
    /// attention, one just finished. Working is deliberately monochrome — it is
    /// the most common state, and colouring it would make the panel loud and
    /// dilute the accent. Failed is the muted red. Nothing here uses the system
    /// accent colour, which would introduce a third hue the brand does not own.
    static func dot(for state: SessionState) -> Color {
        switch state {
        case .needsYou: return accent
        case .done:     return accent
        case .failed:   return failure
        case .working:  return primaryText
        case .idle:     return midGray
        }
    }

    /// Fill style for the dot. `working` is a hollow ring so it reads as "in
    /// progress" rather than "complete", and so working and idle differ in
    /// shape as well as in weight — legible without relying on colour.
    static func dotIsHollow(_ state: SessionState) -> Bool {
        state == .working
    }
}

/// NSColor equivalents, for the AppKit side (status item drawing).
enum PaletteNS {
    static let accent  = NSColor(srgbRed: 0xD9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
    static let failure = NSColor(srgbRed: 0xC2/255, green: 0x56/255, blue: 0x4A/255, alpha: 1)

    /// The orange states need non-template images, which means light and dark
    /// are handled manually. Template images auto-adapt but cannot carry colour.
    static func accent(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Lift the accent slightly on dark backgrounds so it holds its chroma
        // against the menu bar's translucent dark material.
        return isDark
            ? NSColor(srgbRed: 0xE8/255, green: 0x8B/255, blue: 0x69/255, alpha: 1)
            : accent
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    /// Resolves a dynamic system colour against a specific appearance.
    ///
    /// A dynamic `NSColor` has no single `CGColor`: asking for one resolves it
    /// against whatever appearance happens to be current, which is how a glyph
    /// ends up white-on-white. Drawing offscreen there is often no current
    /// appearance at all, so the target is passed in explicitly.
    @MainActor
    func resolved(for appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance {
            result = self.usingColorSpace(.sRGB) ?? self
        }
        return result
    }
}
