import AutoBlackoutCore
import CoreGraphics
import Foundation

/// Receives display reconfiguration callbacks and forwards them on the main thread. Holds no
/// decision logic of its own (decisions are made by AutoBlackoutCore's `BlackoutController.evaluate`).
final class DisplayMonitor {
    /// Called for both phases of every configuration change. The `willBegin` phase says nothing
    /// about the new layout, so only `didComplete` may be used to evaluate the display state.
    var onEvent: ((DisplayReconfigurationEvent) -> Void)?

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
        guard let userInfo else { return }
        let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let event: DisplayReconfigurationEvent = flags.contains(.beginConfigurationFlag)
            ? .willBegin(displayID: displayID)
            : .didComplete(displayID: displayID, flags: flags)
        DispatchQueue.main.async {
            monitor.onEvent?(event)
        }
    }
}
