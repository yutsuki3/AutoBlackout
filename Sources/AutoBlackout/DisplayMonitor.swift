import CoreGraphics
import Foundation

/// Receives display reconfiguration callbacks and forwards them on the main thread. Holds no
/// decision logic of its own (decisions are made by AutoBlackoutCore's `BlackoutController.evaluate`).
final class DisplayMonitor {
    /// Called after each (completed) configuration change, with the changed display's ID and flags.
    var onChange: ((_ displayID: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) -> Void)?

    private var registered = false

    func start() {
        guard !registered else { return }
        registered = true
        CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    func stop() {
        guard registered else { return }
        registered = false
        CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    private static let callback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        // Ignore the "begin" notification and only act on the post-change state.
        guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
        let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            monitor.onChange?(displayID, flags)
        }
    }
}
