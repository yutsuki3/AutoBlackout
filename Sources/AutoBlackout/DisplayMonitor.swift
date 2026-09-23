import CoreGraphics
import Foundation

/// ディスプレイ構成変更のコールバックを受け取り、メインスレッドで通知する。
/// 判定ロジックは持たない（判定は AutoBlackoutCore の BlackoutController.evaluate が行う）。
final class DisplayMonitor {
    /// 構成変更（完了側）のたびに呼ばれる。引数は変化したディスプレイIDとフラグ。
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
        // CGDisplayBeginConfigurationFlag は構成変更の「開始」通知なので無視し、完了後の状態だけ見る。
        guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
        let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            monitor.onChange?(displayID, flags)
        }
    }
}
