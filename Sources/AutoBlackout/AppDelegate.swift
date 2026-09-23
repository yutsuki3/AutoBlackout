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
    private var terminationTimer: Timer?

    /// 終了前の復帰を待つ上限。M3 では有効化要求が1回では通らず、再通電を挟んで10秒以上かかる。
    private static let terminationRestoreTimeout: TimeInterval = 60

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

        // 画面全体のスリープ中は、スリープした外部ディスプレイを理由に内蔵を戻さない。
        // 蓋を開けた・スリープから復帰した直後はパネルが再通電しているので、ポーリングを待たずに評価する。
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] note in
            self?.controller.displaysAsleep = true
            self?.controller.evaluate(reason: note.name.rawValue)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.controller.displaysAsleep = false
                self?.controller.evaluate(reason: note.name.rawValue)
            }
        }

        logger.log("host: " + HostInfo.summary)

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
        guard controller.managedDisplay != nil || controller.restorePending else {
            // .forAppOnly の自動復元には頼らず、明示的に戻してから終了する。
            controller.prepareForTermination()
            return .terminateNow
        }

        // 内蔵をOFFにしたまま終了すると、戻す要求を送るプロセスがいなくなる（2回目の事故）。
        // 復帰手順を最後まで走らせ、戻ったのを確認してから終了する。戻らなければ終了を取りやめる。
        logger.log("terminate: restoring panel before quitting")
        controller.isAutoModeEnabled = false
        controller.requestRestore(trigger: "terminate")
        let deadline = Date().addingTimeInterval(Self.terminationRestoreTimeout)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return }
            if !self.controller.restorePending, self.controller.managedDisplay == nil {
                timer.invalidate()
                self.logger.log("terminate: panel restored; quitting")
                NSApp.reply(toApplicationShouldTerminate: true)
            } else if Date() > deadline {
                timer.invalidate()
                self.logger.log("terminate: panel not restored within \(Int(Self.terminationRestoreTimeout))s; quit cancelled")
                self.controller.isAutoModeEnabled = self.autoModeItem.state == .on
                NSApp.reply(toApplicationShouldTerminate: false)
                self.showQuitCancelledAlert()
            }
        }
        // terminateLater の間はモーダル用のモードで回るので、common モードに登録する。
        RunLoop.main.add(timer, forMode: .common)
        terminationTimer = timer
        return .terminateLater
    }

    private func showQuitCancelledAlert() {
        let alert = NSAlert()
        alert.messageText = "内蔵ディスプレイを戻せなかったため、終了を中止しました"
        alert.informativeText = "復帰の再試行は続けています。蓋を閉じて数秒後に開くと戻ることがあります。"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
            statusLabelItem.title = controller.needsLidCycle
                ? "内蔵ディスプレイ: 復元待ち — 蓋を閉じて数秒後に開いてください"
                : "内蔵ディスプレイ: 復元中…"
        }
        let isOff = status == .off || status == .restoring
        toggleItem.title = isOff ? "内蔵ディスプレイをONに戻す" : "内蔵ディスプレイをOFFにする"
        toggleItem.isEnabled = status != .apiUnavailable && status != .notFound
            && !controller.isChanging
            && (isOff || (controller.isDisableSupported && controller.hasUsableExternalDisplay))
        if !isOff, !controller.isDisableSupported {
            toggleItem.title = "OFFは使用停止中（ONに戻せることが確認できていないため）"
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
