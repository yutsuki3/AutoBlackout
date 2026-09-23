import AutoBlackoutCore
import CoreGraphics
import Foundation

/// App version, for `--version` and `--diagnose`. A raw `swift build` binary has no Info.plist, so
/// it reports "dev".
enum AppVersion {
    static var string: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// `AutoBlackout --diagnose`: prints a Markdown report to paste into a bug report. Read-only: never
/// changes any display's state.
enum Diagnostics {
    static func run() -> Never {
        print(report())
        exit(0)
    }

    static func report(logLines: Int = 30) -> String {
        let system = LiveDisplaySystem()
        let store = UserDefaultsStateStore()
        let snapshot = system.snapshot()

        var out: [String] = []
        out.append("### AutoBlackout diagnostics")
        out.append("")
        out.append("- app version: \(AppVersion.string)")
        out.append("- mac model: \(HostInfo.model)")
        out.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString) (build \(HostInfo.osBuild))")
        out.append("- host key: `\(HostVerification.current)`")
        out.append("- restore verification: \(HostVerification.sourceDescription)")
        out.append("- private API available: \(PrivateDisplayAPI.isAvailable)")
        out.append("- lid closed: \(HostInfo.isLidClosed.map(String.init) ?? "unknown")")
        out.append("- lastKnownBuiltInID: \(store.lastKnownBuiltInID.map(String.init) ?? "nil")")
        out.append("- managedDisplayID: \(store.managedDisplayID.map(String.init) ?? "nil")")
        out.append("")
        out.append("Online displays:")
        out.append(contentsOf: rows(snapshot.online))
        out.append("")
        out.append("All displays (SLSGetDisplayList):")
        out.append(contentsOf: snapshot.all.map(rows) ?? ["- unavailable"])
        out.append("")
        out.append("Last \(logLines) lines of recovery.log:")
        out.append("```")
        out.append(contentsOf: tail(logLines))
        out.append("```")
        return out.joined(separator: "\n")
    }

    private static func rows(_ displays: [DisplayInfo]) -> [String] {
        if displays.isEmpty { return ["- none"] }
        return displays.map {
            "- id=\($0.id) builtin=\($0.isBuiltin) online=\($0.isOnline) active=\($0.isActive) "
                + "asleep=\($0.isAsleep) mirror=\($0.isInMirrorSet) "
                + "vendor=0x\(String($0.vendor, radix: 16)) model=0x\(String($0.model, radix: 16))"
        }
    }

    private static func tail(_ count: Int) -> [String] {
        let url = FileEventLogger.directory.appendingPathComponent("recovery.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ["(no log)"] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init))
    }
}
