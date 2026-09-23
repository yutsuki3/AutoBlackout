import AppKit
import AutoBlackoutCore
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import os

/// 本物のディスプレイに対する `DisplaySystem` 実装。実機に作用するのはこのクラスの setEnabled だけ。
final class LiveDisplaySystem: DisplaySystem {
    /// `--verify-restore` 専用: `isDisableAllowed` が false のまま無効化を許可する。
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

    /// `pmset displaysleepnow`（root不要）で全ディスプレイをスリープさせ、数秒後にユーザー操作を宣言して起こす。
    /// 画面ロックの設定によっては、復帰後にロック画面が出る。
    func powerCycleDisplays() {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        do {
            try pmset.run()
        } catch {
            return
        }
        // メインスレッドが CG の呼び出しで塞がっていても起こせるよう、別キューで実行する。
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

/// コマンドとして動くモード（`--restore` 等）のメインループ。UI は出さないが NSApplication で回す。
///
/// 素の `RunLoop.main.run()` だと、自分で構成変更（無効化など）を確定させた後は WindowServer からの
/// 画面変更通知が処理されず、`CGGetOnlineDisplayList` が古いまま残る（外部ディスプレイを抜いても一覧に残る）。
/// 2026-09-23 に、仮想ディスプレイを無効化した後に別の仮想ディスプレイが見えないことで再現・確認した。
enum HeadlessMainLoop {
    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
        exit(1)
    }
}

/// ログに残す実行環境。無効化後に戻せるかは機種（M3 の MacBook Air 等）と macOS のビルドに依存する。
enum HostInfo {
    static var model: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    static var summary: String {
        "model=\(model) os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// 蓋が閉じているか。取得できなければ nil。
    static var isLidClosed: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
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
    /// true なら標準出力にも書く（`--restore` 用）。
    private let echo: Bool

    init(echo: Bool = false) {
        self.echo = echo
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
        if echo { print(message) }
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
