import Foundation

/// Spacing, sizing and timing. Nothing outside this file hardcodes a number
/// that affects layout or motion.
enum Metrics {
    // Panel
    static let panelWidth: CGFloat = 320
    /// The list grows with the number of sessions up to this many rows, then
    /// scrolls. Most people run one to four sessions, so the panel is usually
    /// exactly as tall as its contents.
    static let maxVisibleRows: Int = 8
    static let panelMaxHeight: CGFloat = 480

    // Onboarding window
    static let onboardingWidth: CGFloat = 440
    static let onboardingMarkSize: CGFloat = 72
    /// The official logo beside the panel title and in About.
    static let headerMarkSize: CGFloat = 16
    static let aboutMarkSize: CGFloat = 32
    /// The mock menu bar in onboarding: real bar height, real glyph size.
    static let mockBarHeight: CGFloat = 24
    static let mockBarRadius: CGFloat = 6
    static let mockBarItemWidth: CGFloat = 14
    /// Step indicator segments.
    static let progressSegmentHeight: CGFloat = 3
    static let progressSegmentWidth: CGFloat = 28
    /// How long each state holds in the onboarding demo loop.
    static let demoStateDuration: TimeInterval = 2.4
    /// Time between the first real event landing and onboarding closing, so
    /// the user sees the glyph move before the window goes.
    static let onboardingDismissDelay: TimeInterval = 1.6
    static let configPreviewHeight: CGFloat = 150

    // Spacing scale (4pt base)
    static let spaceXS: CGFloat = 2
    static let spaceS: CGFloat = 4
    static let spaceM: CGFloat = 8
    static let spaceL: CGFloat = 12
    static let spaceXL: CGFloat = 16

    // Rows
    static let rowHeight: CGFloat = 44
    static let rowCorner: CGFloat = 6
    /// The design box the dot geometry is drawn in.
    static let dotCanvas: CGFloat = 8
    /// The size it is shown at. Larger than the spec's 8pt: with several
    /// sessions in the list the dots are what you scan, and at 8pt they were
    /// too small to read the five forms apart at a glance.
    static let dotSize: CGFloat = 14

    // Status item
    static let statusItemWidth: CGFloat = 24
    /// Gap between the glyph and the optional status word.
    static let statusTextSpacing: CGFloat = 4
    /// The glyph's drawn size. The spec's artwork occupies 22pt of optical
    /// width inside a 36pt canvas; at 18pt on screen that lands the mark at the
    /// weight macOS expects beside its own items.
    static let statusIconSize: CGFloat = 18

    // Panel iconography
    /// Row and header action icons.
    static let smallIconSize: CGFloat = 16
    /// Uniform stroke for every small icon.
    static let smallIconStroke: CGFloat = 1.3
    /// The empty state's glyph, the gem at 1.8× the menu bar size.
    static let emptyGlyphSize: CGFloat = 64
    static let emptyGlyphStrokeOpacity: Double = 0.34
    static let emptyGlyphPipOpacity: Double = 0.75
    /// Live spinner previews in the settings picker.
    static let spinnerPreviewSize: CGFloat = 28
    /// Fill behind the selected spinner style.
    static let selectedFill: Double = 0.25
    /// A one-pixel border at any scale.
    static let hairline: CGFloat = 1
    /// A deliberate zero: the panel's top-level sections butt against their
    /// dividers, so the stack has no spacing of its own.
    static let none: CGFloat = 0

    // Panel motion
    //
    // Icon timing lives in `Motion`, which transcribes the design spec's
    // keyframes. Nothing here duplicates those numbers.
    static let rowSpringResponse: Double = 0.34
    static let rowSpringDamping: Double = 0.82
    static let dotCrossfade: TimeInterval = 0.22
    static let highlightSweep: TimeInterval = 0.9

    // Liveness
    /// How often the app reaps sessions whose process is gone.
    static let livenessInterval: TimeInterval = 15
    /// How often the transcripts of working sessions are checked for an
    /// interrupt. A stat per file; the tail is read only when the size grew.
    static let transcriptPollInterval: TimeInterval = 1.0
    static let transcriptTailBytes: Int = 32 * 1024
    /// Backstop for a recycled PID: no event for this long AND no live process.
    static let staleThreshold: TimeInterval = 60 * 60 * 6
    /// Coalescing window for a burst of hook writes.
    static let debounceInterval: TimeInterval = 0.120

    // Energy
    /// Below this battery fraction on battery power, animation suspends.
    static let lowBatteryThreshold: Double = 0.20
}
