import AppKit
import SwiftUI

/// Which ink a state draws in, and whether it ships as a template image.
///
/// This split is the reason the app cannot simply put a SwiftUI view in the
/// menu bar and be done: **a SwiftUI view inside an `NSHostingView` does not get
/// macOS's automatic template inversion.** That only applies to `NSImage` with
/// `isTemplate = true`. So the two families need two different rendering paths.
enum IconPalette {
    /// Template states are monochrome and let the system invert them; they must
    /// be drawn in pure black with uniform alpha per shape, never interpolated
    /// across pixels. Non-template states carry colour and bypass that
    /// treatment entirely.
    static func isTemplate(_ state: IconState) -> Bool {
        switch state {
        case .idle, .working:                 true
        case .doneUnseen, .needsYou, .failed: false
        }
    }

    /// The single colour a state draws in.
    ///
    /// `forTemplate` distinguishes the two rendering paths, and getting it
    /// wrong makes the icon invisible on one menu bar appearance:
    ///
    ///   * Rasterising for the status item (`forTemplate: true`), a monochrome
    ///     state must be drawn in pure black, because that is what
    ///     `NSImage.isTemplate` expects — macOS then inverts it to suit the bar.
    ///   * Drawing the same view directly on screen (the settings picker), black
    ///     ink would vanish against a dark window, so it resolves to
    ///     `.primary` and adapts with the appearance instead.
    ///
    /// Colour states are identical on both paths: they bypass template
    /// treatment entirely and come from one accent constant, so the palette
    /// cannot drift.
    static func ink(for state: IconState, forTemplate: Bool) -> Color {
        switch state {
        case .idle, .working:        forTemplate ? .black : .primary
        case .doneUnseen, .needsYou: Palette.accent
        case .failed:                Palette.failure
        }
    }

    /// The same ink as a `CGColor`, for the Core Graphics drawing path.
    ///
    /// The on-screen monochrome case must resolve `labelColor` against the
    /// appearance actually being drawn into: offscreen there may be no current
    /// appearance, and resolving against the wrong one renders the glyph
    /// white-on-white.
    @MainActor
    static func cgInk(for state: IconState,
                      forTemplate: Bool,
                      appearance: NSAppearance? = nil) -> CGColor {
        switch state {
        case .idle, .working:
            if forTemplate { return NSColor.black.cgColor }
            let target = appearance
                ?? NSApp?.effectiveAppearance
                ?? NSAppearance(named: .aqua)!
            return NSColor.labelColor.resolved(for: target).cgColor
        case .doneUnseen, .needsYou: return PaletteNS.accent.cgColor
        case .failed:                return PaletteNS.failure.cgColor
        }
    }
}

/// Rasterises one frame of the glyph to an `NSImage`.
///
/// Drawing goes straight into the image's Core Graphics context via
/// `GlyphDrawing`. An earlier version rendered `StatusIconView` through
/// `ImageRenderer`, which rebuilt the SwiftUI view graph on every one of the
/// twelve frames per second and measured ~10% CPU; drawing the paths directly
/// measures a small fraction of that. The geometry is identical either way —
/// both paths call into `GlyphDrawing`.
@MainActor
enum IconRenderer {
    /// Rendered frames, keyed by everything that affects the drawing.
    ///
    /// A spin loops over the same 96 frames forever, so after one cycle every
    /// frame is a dictionary lookup rather than a rasterisation. This is what
    /// takes the animating cost from ~4% CPU to a fraction of it; the cache is
    /// bounded by the number of distinct frames the design defines, which is
    /// small and fixed.
    private static var cache: [CacheKey: NSImage] = [:]

    private struct CacheKey: Hashable {
        var state: IconState
        /// The integer frame index, not the raw phase: two times inside one
        /// frame must hit the same entry.
        var frame: Int
        var isAnimating: Bool
        var appearance: String
    }

    /// Dropped when the appearance changes, since the monochrome ink resolves
    /// differently on a light and a dark menu bar.
    static func invalidate() { cache.removeAll() }

    /// Renders the given frame. The result is marked as a template for the
    /// monochrome states, so macOS inverts it to suit the menu bar appearance;
    /// colour states are returned untouched.
    static func image(state: IconState,
                      phase: Double,
                      workingCount: Int,
                      isAnimating: Bool) -> NSImage? {
        let period = state.period
        let key = CacheKey(
            state: state,
            frame: Int((phase * Motion.fps * period).rounded()),
            isAnimating: isAnimating,
            appearance: NSApp?.effectiveAppearance.name.rawValue ?? ""
        )
        if let hit = cache[key] { return hit }

        let size = NSSize(width: Metrics.statusIconSize, height: Metrics.statusIconSize)
        let frame = GlyphDrawing.Frame(state: state, phase: phase,
                                       isAnimating: isAnimating)
        let template = IconPalette.isTemplate(state)
        let ink = IconPalette.cgInk(for: state, forTemplate: template)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            GlyphDrawing.draw(frame, in: ctx, rect: rect, ink: ink)
            return true
        }
        image.isTemplate = template
        cache[key] = image
        return image
    }
}
