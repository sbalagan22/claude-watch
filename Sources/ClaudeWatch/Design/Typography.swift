import AppKit
import SwiftUI

/// The type scale. Nothing outside this file names a font.
///
/// System font stack throughout, which is correct for a native Mac app, and the
/// macOS type scale: 13pt body, not iOS's 17pt.
enum Typography {
    /// 13pt — macOS body. The default for row content.
    static let body = Font.system(size: 13)
    /// 13pt semibold — the primary line of a row (the chat name).
    static let rowTitle = Font.system(size: 13, weight: .semibold)
    /// 11pt — secondary text: project name, environment label.
    static let caption = Font.system(size: 11)
    /// 11pt medium — section headers.
    static let sectionHeader = Font.system(size: 11, weight: .medium)
    /// 11pt monospaced digits — elapsed time. Tabular figures so the row does
    /// not reflow every second as digits change width.
    static let elapsed = Font.system(size: 11, design: .monospaced)
        .monospacedDigit()
    /// The optional status word beside the menu bar glyph. Matches the weight
    /// macOS uses for its own menu bar extras that show text (the clock,
    /// battery percentage).
    static var statusBar: NSFont { NSFont.systemFont(ofSize: 12, weight: .medium) }
    /// Onboarding window.
    static let onboardingTitle = Font.system(size: 22, weight: .semibold)
    static let onboardingBody = Font.system(size: 13)
    /// 12pt — footer controls.
    static let footer = Font.system(size: 12)
    /// 10pt — the trademark disclaimer.
    static let disclaimer = Font.system(size: 10)
}
