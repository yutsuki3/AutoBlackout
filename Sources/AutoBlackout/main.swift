import AppKit
import AutoBlackoutCore

if CommandLine.arguments.contains("--verify-restore") {
    RestoreVerification.run()
}
if CommandLine.arguments.contains("--power-cycle-displays") {
    RestoreVerification.powerCycleOnly()
}

// 緊急復旧モード: `AutoBlackout --restore`
// 画面が真っ暗でも SSH やターミナルから復帰させる。アプリ本体と同じ手順（有効化要求の再試行 →
// ディスプレイの再通電 → 蓋の開閉の案内）を、復帰を確認できるまで最大5分続ける。
if CommandLine.arguments.contains("--restore") {
    let logger = FileEventLogger(echo: true)
    logger.log("--restore: " + HostInfo.summary)
    let controller = BlackoutController(
        system: LiveDisplaySystem(),
        store: UserDefaultsStateStore(),
        scheduler: MainQueueScheduler(),
        logger: logger
    )
    controller.isAutoModeEnabled = false
    guard controller.isAPIAvailable, controller.builtInPanelID() != nil else {
        logger.log("--restore: nothing to do (api=\(controller.isAPIAvailable) panel=nil)")
        exit(1)
    }

    var lidHintShown = false
    controller.onStateChange = {
        guard controller.needsLidCycle, !lidHintShown else { return }
        lidHintShown = true
        print("内蔵ディスプレイがまだ戻りません。蓋を閉じて5秒ほど待ってから開いてください（このコマンドは実行したままにしてください）。")
    }
    controller.requestRestore(trigger: "--restore")

    let deadline = Date().addingTimeInterval(300)
    let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
        if !controller.restorePending, controller.panelStatus == .on {
            logger.log("--restore: panel is enabled")
            exit(0)
        }
        if Date() > deadline {
            logger.log("--restore: gave up after 300s")
            exit(1)
        }
        controller.evaluate(reason: "poll")
    }
    RunLoop.main.add(timer, forMode: .common)
    HeadlessMainLoop.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Dockに表示せず、メニューバーのみに常駐する
app.run()
