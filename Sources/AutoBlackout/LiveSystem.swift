import AutoBlackoutCore
import CoreGraphics
import Foundation
import os

/// 本物のディスプレイに対する `DisplaySystem` 実装。実機に作用するのはこのクラスの setEnabled だけ。
final class LiveDisplaySystem: DisplaySystem {
    var isToggleAvailable: Bool { PrivateDisplayAPI.isAvailable }
    var isDisableSupported: Bool { PrivateDisplayAPI.isDisableAllowed }
    var lastErrorDescription: String? { PrivateDisplayAPI.lastError }

    func snapshot() -> DisplaySnapshot {
        DisplaySnapshot(
            online: Self.onlineDisplayIDs().map(Self.info),
            all: PrivateDisplayAPI.allDisplayIDs()?.map(Self.info)
        )
    }

    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool {
        PrivateDisplayAPI.setEnabled(enabled, for: displayID)
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

/// プロセスを跨ぐ状態の保存先。`--restore` で起動した別プロセスからも同じ値を読めるよう固定ドメインを使う。
final class UserDefaultsStateStore: DisplayStateStore {
    private let defaults = UserDefaults(suiteName: "io.github.yutsuki3.AutoBlackout") ?? .standard

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
        defaults.synchronize() // 直後に強制終了されても残るように
    }
}

final class MainQueueScheduler: Scheduler {
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// os_log と ~/Library/Logs/AutoBlackout/recovery.log の両方に書く。
/// 1行ごとに開閉するので、クラッシュや強制終了の直前の記録も残る。2MBでローテート。
final class FileEventLogger: EventLogger {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AutoBlackout", isDirectory: true)

    private let osLog = Logger(subsystem: "io.github.yutsuki3.AutoBlackout", category: "recovery")
    private let url: URL?
    private let formatter = ISO8601DateFormatter()

    init() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            url = Self.directory.appendingPathComponent("recovery.log")
        } catch {
            url = nil
        }
    }

    func log(_ message: String) {
        let message = message.replacingOccurrences(of: "\n", with: " ")
        osLog.notice("\(message, privacy: .public)")
        guard let url else { return }

        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size >= 2 * 1024 * 1024 {
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
