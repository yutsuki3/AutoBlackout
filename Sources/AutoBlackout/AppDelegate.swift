import AppKit
import AutoBlackoutCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = FileEventLogger()
    private lazy var controller = BlackoutController(
        system: LiveDisplaySystem(),
        store: UserDefaultsStateStore(),
        scheduler: MainQueueScheduler(),
        logger: logger
    )
    private let monitor = DisplayMonitor()
    private var recoveryTimer: Timer?

    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var restoreItem: NSMenuItem!
    private var autoModeItem: NSMenuItem!
    private var statusLabelItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "laptopcomputer",
            accessibilityDescription: "AutoBlackout"
        )

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        statusLabelItem = NSMenuItem(title: "内蔵ディスプレイ: ON", action: nil, keyEquivalent: "")
        statusLabelItem.isEnabled = false
        menu.addItem(statusLabelItem)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "内蔵ディスプレイをOFFにする",
            action: #selector(toggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        // 状態表示がどうであれ、常に押せる「有効化要求を送る」ボタン。
        restoreItem = NSMenuItem(
            title: "内蔵ディスプレイを強制的に復元",
            action: #selector(forceRestore),
            keyEquivalent: ""
        )
        restoreItem.target = self
        menu.addItem(restoreItem)

        autoModeItem = NSMenuItem(
            title: "外部モニター接続で自動OFF",
            action: #selector(toggleAutoMode),
            keyEquivalent: ""
        )
        autoModeItem.target = self
        autoModeItem.state = .on
        menu.addItem(autoModeItem)
        if !controller.isDisableSupported {
            controller.isAutoModeEnabled = false
            autoModeItem.state = .off
            autoModeItem.isEnabled = false
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "ログを表示", action: #selector(openLogs), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        controller.onStateChange = { [weak self] in self?.refresh() }

        monitor.onChange = { [weak self] displayID, flags in
            self?.controller.evaluate(reason: "callback id=\(displayID) flags=0x\(String(flags.rawValue, radix: 16))")
        }
        monitor.start()

        // 起動時の自己修復（前回のプロセスが無効化したまま落ちていた場合など）。
        controller.launch()

        // コールバックが来ない・遅れる・順序が前後するケースへの保険として、1秒ごとに実測して是正する。
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.controller.evaluate(reason: "poll")
        }
        RunLoop.main.add(timer, forMode: .common)
        recoveryTimer = timer

        refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // .forAppOnly の自動復元には頼らず、明示的に戻してから終了する。
        controller.prepareForTermination()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        recoveryTimer?.invalidate()
        monitor.stop()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func toggle() {
        controller.toggleManually()
    }

    @objc private func forceRestore() {
        controller.requestRestore(trigger: "menu force-restore")
    }

    @objc private func toggleAutoMode() {
        controller.isAutoModeEnabled.toggle()
        autoModeItem.state = controller.isAutoModeEnabled ? .on : .off
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(FileEventLogger.directory)
    }

    private func refresh() {
        let status = controller.panelStatus
        switch status {
        case .apiUnavailable:
            statusLabelItem.title = "このmacOSでは非公開APIが利用できません"
        case .notFound:
            statusLabelItem.title = "内蔵ディスプレイが見つかりません"
        case .on:
            statusLabelItem.title = "内蔵ディスプレイ: ON"
        case .off:
            statusLabelItem.title = "内蔵ディスプレイ: OFF"
        case .restoring:
            statusLabelItem.title = "内蔵ディスプレイ: 復元中…"
        }
        let isOff = status == .off || status == .restoring
        toggleItem.title = isOff ? "内蔵ディスプレイをONに戻す" : "内蔵ディスプレイをOFFにする"
        toggleItem.isEnabled = status != .apiUnavailable && status != .notFound
            && !controller.isChanging
            && (isOff || (controller.isDisableSupported && controller.hasUsableExternalDisplay))
        if !isOff, !controller.isDisableSupported {
            toggleItem.title = "OFFは使用停止中（このmacOSでは再起動まで戻せないため）"
        }
        restoreItem.isEnabled = status != .apiUnavailable && status != .notFound
    }
}

private extension NSMenuItem {
    func withTarget(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
