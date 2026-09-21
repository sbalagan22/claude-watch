import AppKit

/// The completion sound. Half a second, bundled, played through `NSSound` so
/// it follows the system output device and volume.
@MainActor
enum DoneSound {
    private static let sound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "done", withExtension: "wav") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }()

    static func play() {
        guard let sound else { return }
        // Two finishes in quick succession restart the clip rather than
        // overlapping or dropping the second.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
