import AppKit
import Foundation
import IOKit.ps
import Observation

/// Decides whether the menu bar icon is allowed to animate right now.
///
/// Menu bar animation runs constantly and shows up in Activity Monitor's energy
/// column. Users of a free utility notice that and post about it. So animation
/// stops when it cannot be seen or cannot be afforded:
///
///   * the system Reduce Motion setting is on (state changes become static),
///   * the user turned animation off in settings,
///   * the display is asleep or the screen is locked,
///   * the menu bar is hidden (auto-hide, or a full-screen app covering it),
///   * the machine is on battery below a threshold.
@MainActor
@Observable
final class AnimationGate {
    private(set) var isAllowed: Bool = true
    private(set) var reduceMotion: Bool = false

    private var displayAsleep = false
    private var menuBarHidden = false
    private var lowBattery = false
    private var batteryTimer: Timer?
    private var observers: [any NSObjectProtocol] = []

    init() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        observe()
        refreshBattery()
        recompute()
    }

    // No deinit: `batteryTimer` is main-actor isolated and deinit is not, so
    // touching it there is a Swift 6 isolation error. The timer holds only a
    // weak reference to self, so once this object goes away the tick is a
    // no-op; `invalidate()` on teardown is done by `stop()` instead.
    func stop() {
        batteryTimer?.invalidate()
        batteryTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter

        // Reduce Motion can change while the app runs.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.recompute()
            }
        })

        for name in [NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displayAsleep = true
                    self?.recompute()
                }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displayAsleep = false
                    self?.refreshBattery()
                    self?.recompute()
                }
            })
        }

        // Battery state changes rarely; a slow timer is cheaper than an IOKit
        // run-loop source and precise enough for a 20% threshold.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshBattery()
                self?.recompute()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    /// Called by the controller when it notices the menu bar is not visible.
    func setMenuBarHidden(_ hidden: Bool) {
        guard menuBarHidden != hidden else { return }
        menuBarHidden = hidden
        recompute()
    }

    private func refreshBattery() {
        lowBattery = Self.isOnBatteryBelow(Metrics.lowBatteryThreshold)
    }

    private func recompute() {
        let prefs = Preferences.shared
        isAllowed = prefs.animationEnabled
            && !reduceMotion
            && !displayAsleep
            && !menuBarHidden
            && !lowBattery
    }

    /// Re-read settings after the user changes them.
    func settingsChanged() { recompute() }

    /// True when running on battery with charge below `threshold`.
    nonisolated static func isOnBatteryBelow(_ threshold: Double) -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String
            guard state == kIOPSBatteryPowerValue else { continue }
            if let current = desc[kIOPSCurrentCapacityKey] as? Double,
               let max = desc[kIOPSMaxCapacityKey] as? Double, max > 0 {
                return (current / max) < threshold
            }
        }
        return false
    }
}
