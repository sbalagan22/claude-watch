import AppKit
import SwiftUI

/// The official logo — the ringed gradient mark from `/design`.
///
/// This is the brand: app icon, onboarding, About, panel header. It is a
/// bitmap on purpose, never the flat glyph, which exists only as the menu bar
/// status indicator under template-image rules. Two sizes ship so the 16pt
/// header mark is downsampled from something close to its size rather than
/// from the 320px master.
struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: Self.image(for: size))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static let small: NSImage = load("AppMarkSmall")
    private static let large: NSImage = load("AppMark")

    private static func image(for size: CGFloat) -> NSImage {
        size <= Metrics.aboutMarkSize ? small : large
    }

    private static func load(_ name: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            // Test hosts have no bundle resources; an empty image keeps layout
            // honest without crashing.
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        return image
    }
}
