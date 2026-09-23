import CoreGraphics
import Foundation

/// 「内蔵ディスプレイが今OFFかどうか」「自動モードが有効かどうか」を持ち、
/// DisplayMonitor（検知） と PrivateDisplayAPI（実際の切り替え）を仲介する。
///
/// 安全ルール: 外部ディスプレイが1台も無い状態ではOFFにしない・OFFを維持しない。
final class BlackoutController {
    private(set) var isBuiltInDisplayOff = false
    var isAutoModeEnabled = true

    /// 状態が変化するたびにUI側へ通知する。
    var onStateChange: (() -> Void)?

    private let monitor = DisplayMonitor()

    var isAPIAvailable: Bool { PrivateDisplayAPI.isAvailable }

    func start() {
        monitor.onExternalDisplayChange = { [weak self] hasExternal in
            self?.handleExternalDisplayChange(hasExternal: hasExternal)
        }
        monitor.start()
    }

    /// メニューバーからの手動トグル。
    func toggleManually() {
        guard let displayID = monitor.builtInDisplayID() else { return }

        if isBuiltInDisplayOff {
            setBuiltIn(enabled: true, displayID: displayID)
        } else {
            guard monitor.hasUsableExternalDisplay() else { return } // 安全ルール
            setBuiltIn(enabled: false, displayID: displayID)
        }
    }

    private func handleExternalDisplayChange(hasExternal: Bool) {
        guard isAutoModeEnabled, let displayID = monitor.builtInDisplayID() else { return }

        if hasExternal, !isBuiltInDisplayOff {
            setBuiltIn(enabled: false, displayID: displayID)
        } else if !hasExternal, isBuiltInDisplayOff {
            // 外部が全部外れたら無条件で復帰させる（画面ゼロを避ける最優先ルール）。
            setBuiltIn(enabled: true, displayID: displayID)
        }
    }

    private func setBuiltIn(enabled: Bool, displayID: CGDirectDisplayID) {
        guard PrivateDisplayAPI.setEnabled(enabled, for: displayID) else { return }
        isBuiltInDisplayOff = !enabled
        onStateChange?()
    }
}
