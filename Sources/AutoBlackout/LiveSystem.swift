import AppKit
import AutoBlackoutCore
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import os

/// The real-hardware `DisplaySystem` implementation. This class's `setEnabled` is the only place
/// that ever touches a real display.
final class LiveDisplaySystem: DisplaySystem {
    /// `--verify-restore` only: lets a disable request through even while `isDisableAllowed` is false.
    private let allowsDisableForVerification: Bool

    init(allowsDisableForVerification: Bool = false) {
        self.allowsDisableForVerification = allowsDisableForVerification
    }

    var isToggleAvailable: Bool { PrivateDisplayAPI.isAvailable }
    var isDisableSupported: Bool { PrivateDisplayAPI.isDisableAllowed || allowsDisableForVerification }
    var lastErrorDescription: String? { PrivateDisplayAPI.lastError }

    func snapshot() -> DisplaySnapshot {
        DisplaySnapshot(
            online: Self.onlineDisplayIDs().map(Self.info),
            all: PrivateDisplayAPI.allDisplayIDs()?.map(Self.info)
        )
    }

    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool {
        PrivateDisplayAPI.setEnabled(enabled, for: displayID, overrideDisableBlock: allowsDisableForVerification)
    }

    /// Puts every display to sleep with `pmset displaysleepnow` (no root needed), then declares user
    /// activity a few seconds later to wake them back up. Depending on the screen-lock settings, the
    /// lock screen may appear after waking.
    func powerCycleDisplays() {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        do {
            try pmset.run()
        } catch {
            return
        }
        // Run on a background queue so this still wakes the displays even if the main thread is
        // blocked inside a CG call.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            var assertion: IOPMAssertionID = 0
            let result = IOPMAssertionDeclareUserActivity(
                "AutoBlackout: wake displays to re-power the built-in panel" as CFString,
                kIOPMUserActiveLocal,
                &assertion
            )
            guard result == kIOReturnSuccess else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { IOPMAssertionRelease(assertion) }
        }
    }

    private static func info(_ id: CGDirectDisplayID) -> DisplayInfo {
        DisplayInfo(
            id: id,
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isOnline: CGDisplayIsOnline(id) != 0,
            isActive: CGDisplayIsActive(id) != 0,
            isAsleep: CGDisplayIsAsleep(id) != 0,
            isInMirrorSet: CGDisplayIsInMirrorSet(id) != 0,
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id)
        )
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        let capacity = max(count + 8, 32)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        guard CGGetOnlineDisplayList(capacity, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(min(count, capacity))))
    }
}

/// The main loop used for command-line modes (`--restore` etc.). No UI is shown, but it still runs
/// on `NSApplication` rather than a bare run loop.
///
/// A bare `RunLoop.main.run()` doesn't process WindowServer's screen-change notifications after this
/// process commits its own configuration change (e.g. a disable), so `CGGetOnlineDisplayList` goes
/// stale (an unplugged external display stays in the list). Reproduced and confirmed on 2026-09-23
/// by disabling one virtual display and finding another virtual display invisible afterward.
enum HeadlessMainLoop {
    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
        exit(1)
    }
}

/// The runtime environment, for logging. Whether the display can be restored after being disabled
/// depends on the Mac model (e.g. the MacBook Air M3) and the macOS build.
enum HostInfo {
    static var model: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    /// The macOS build number (e.g. "25G229"), used to key the per-host restore-verification allowlist.
    static var osBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    /// Whether this Mac has an Apple Silicon CPU. The disable feature is only meant for Apple
    /// Silicon: the private API doesn't behave the same way on Intel Macs. Also true when running
    /// under Rosetta, since the hardware is still Apple Silicon.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var summary: String {
        "model=\(model) os=\(ProcessInfo.processInfo.operatingSystemVersionString) build=\(osBuild) "
            + "arch=\(isAppleSilicon ? "arm64" : "x86_64")"
    }

    /// Whether the lid is closed. `nil` if it can't be determined.
    static var isLidClosed: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }
}

/// The app's shared defaults domain. The `.app` bundle's own identifier is that same domain, and
/// Foundation warns when you pass your own bundle ID as a suite name, so use `.standard` there. The
/// bare binary (`--restore` from a terminal, `swift run`) has no bundle ID and needs the named suite
/// to read and write the same domain as the app.
enum AppDefaults {
    static let suiteName = "io.github.yutsuki3.AutoBlackout"

    static var shared: UserDefaults {
        Bundle.main.bundleIdentifier == suiteName ? .standard : (UserDefaults(suiteName: suiteName) ?? .standard)
    }
}

/// Where state is stored across process boundaries, so a separate `--restore` process can read the
/// same values. Uses a fixed suite name for that reason.
final class UserDefaultsStateStore: DisplayStateStore {
    private let defaults: UserDefaults

    /// - Parameter defaults: injectable for tests; production uses the shared suite.
    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
    }

    var lastKnownBuiltInID: CGDirectDisplayID? {
        get { read("lastKnownBuiltInID") }
        set { write(newValue, "lastKnownBuiltInID") }
    }

    var managedDisplayID: CGDirectDisplayID? {
        get { read("managedDisplayID") }
        set { write(newValue, "managedDisplayID") }
    }

    private func read(_ key: String) -> CGDirectDisplayID? {
        (defaults.object(forKey: key) as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    private func write(_ value: CGDirectDisplayID?, _ key: String) {
        if let value { defaults.set(NSNumber(value: value), forKey: key) } else { defaults.removeObject(forKey: key) }
        defaults.synchronize() // so the value survives even if the process is killed right after
    }
}

final class MainQueueScheduler: Scheduler {
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Writes to both os_log and ~/Library/Logs/AutoBlackout/recovery.log. Opens and closes the file
/// for each line, so a log line survives even right before a crash or force-quit. Rotates at 2MB.
final class FileEventLogger: EventLogger {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AutoBlackout", isDirectory: true)

    static let maxLogBytes = 2 * 1024 * 1024

    private let osLog = Logger(subsystem: "io.github.yutsuki3.AutoBlackout", category: "recovery")
    private let url: URL?
    private let formatter = ISO8601DateFormatter()
    /// Also echoes to stdout when true (used by `--restore`).
    private let echo: Bool

    /// - Parameter directory: injectable for tests; production uses `~/Library/Logs/AutoBlackout`.
    init(echo: Bool = false, directory: URL = FileEventLogger.directory) {
        self.echo = echo
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("recovery.log")
        } catch {
            url = nil
        }
    }

    func log(_ message: String) {
        let message = message.replacingOccurrences(of: "\n", with: " ")
        osLog.notice("\(message, privacy: .public)")
        if echo { print(message) }
        guard let url else { return }

        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size >= Self.maxLogBytes {
            let previous = url.appendingPathExtension("previous")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }

        let line = "\(formatter.string(from: Date())) pid=\(getpid()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
