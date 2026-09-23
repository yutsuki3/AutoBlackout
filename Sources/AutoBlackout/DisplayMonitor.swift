import CoreGraphics
import Foundation

/// 内蔵/外部ディスプレイの接続状態を監視し、変化をコールバックで通知する。
/// 非公開APIは一切使わず、公開APIのみで構成 — ここは信頼度の高い層。
final class DisplayMonitor {
    /// 外部ディスプレイの接続状態が変わるたびに呼ばれる。
    var onExternalDisplayChange: ((_ hasExternalDisplay: Bool) -> Void)?

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

    /// 現在オンラインな内蔵ディスプレイのIDを返す。
    func builtInDisplayID() -> CGDirectDisplayID? {
        onlineDisplayIDs().first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 現在使用可能な外部ディスプレイが1台以上あるかどうか。
    func hasUsableExternalDisplay() -> Bool {
        onlineDisplayIDs().contains {
            CGDisplayIsBuiltin($0) == 0
                && CGDisplayIsOnline($0) != 0
                && CGDisplayIsAsleep($0) == 0
        }
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids
    }

    private static let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        // CGDisplayBeginConfigurationFlag は構成変更の「開始」通知なので無視し、完了後の状態だけ見る。
        guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
        let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            monitor.onExternalDisplayChange?(monitor.hasUsableExternalDisplay())
        }
    }
}
