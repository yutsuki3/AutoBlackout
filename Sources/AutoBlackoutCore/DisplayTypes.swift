import CoreGraphics
import Foundation

/// A single display's state at one point in time. Holds the results of CG's various
/// `CGDisplayIs*` calls as plain values.
public struct DisplayInfo: Equatable {
    public var id: CGDirectDisplayID
    public var isBuiltin: Bool
    public var isOnline: Bool
    public var isActive: Bool
    public var isAsleep: Bool
    public var isInMirrorSet: Bool
    public var vendor: UInt32
    public var model: UInt32

    public init(
        id: CGDirectDisplayID,
        isBuiltin: Bool,
        isOnline: Bool = true,
        isActive: Bool = true,
        isAsleep: Bool = false,
        isInMirrorSet: Bool = false,
        vendor: UInt32 = 0,
        model: UInt32 = 0
    ) {
        self.id = id
        self.isBuiltin = isBuiltin
        self.isOnline = isOnline
        self.isActive = isActive
        self.isAsleep = isAsleep
        self.isInMirrorSet = isInMirrorSet
        self.vendor = vendor
        self.model = model
    }

    /// The virtual display WindowServer creates when every real display disappears (vendor 'unkn' /
    /// model 'virt'). Nothing actually shows on it, so it must never count as a usable external display.
    public var isHeadlessFallback: Bool {
        vendor == 0x756e_6b6e && model == 0x7669_7274
    }
}

/// A display configuration at one point in time.
public struct DisplaySnapshot: Equatable {
    /// The result of `CGGetOnlineDisplayList`. A disabled built-in display can disappear from this.
    public var online: [DisplayInfo]
    /// The result of `SLSGetDisplayList` (private API; includes disabled displays too). `nil` if it
    /// couldn't be resolved. `CGDisplayIs*` can return -1 (truthy) for an ID that isn't in this list,
    /// so treat this as supplementary information only.
    public var all: [DisplayInfo]?

    public init(online: [DisplayInfo], all: [DisplayInfo]? = nil) {
        self.online = online
        self.all = all
    }
}

/// An abstraction over real display operations. Production uses CG + the private API; tests use a mock.
public protocol DisplaySystem: AnyObject {
    /// Whether the private API for toggling enabled state was resolved.
    var isToggleAvailable: Bool { get }
    /// Whether disabling (turning OFF) is allowed. `false` in environments where restoring isn't
    /// guaranteed to work.
    var isDisableSupported: Bool { get }
    /// The most recent `setEnabled` failure detail, for logging.
    var lastErrorDescription: String? { get }
    func snapshot() -> DisplaySnapshot
    /// - Returns: whether the API reported success. **Success being reported doesn't guarantee it
    ///   actually applied.**
    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool
    /// Puts every display to sleep and wakes it back up, re-powering a disabled built-in panel.
    /// Returns without waiting for completion.
    ///
    /// On the MacBook Air M3 and similar models, disabling makes the panel look
    /// hardware-disconnected (IOMFB "hot plug 0"), and WindowServer rejects enable requests with
    /// 1001 until it's re-powered ("hot plug 1").
    func powerCycleDisplays()
}

/// State that needs to survive across processes, so a restore can still happen after the app crashes
/// and restarts.
public protocol DisplayStateStore: AnyObject {
    /// The last built-in display ID confirmed on the online list.
    var lastKnownBuiltInID: CGDirectDisplayID? { get set }
    /// The built-in display ID this app disabled and hasn't yet confirmed restored.
    var managedDisplayID: CGDirectDisplayID? { get set }
}

/// An abstraction over deferred execution. Tests advance time explicitly.
public protocol Scheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void)
}

public protocol EventLogger: AnyObject {
    func log(_ message: String)
}
