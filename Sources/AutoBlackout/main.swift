import AppKit
import AutoBlackoutCore

if CommandLine.arguments.contains("--verify-restore") {
    RestoreVerification.run()
}
if CommandLine.arguments.contains("--power-cycle-displays") {
    RestoreVerification.powerCycleOnly()
}

// Emergency recovery mode: `AutoBlackout --restore`
// Restores the built-in display even from SSH or a terminal with a blank screen. Runs the same
// procedure as the app itself (retry the enable request -> power-cycle the displays -> prompt to
// cycle the lid), for up to 5 minutes or until the restore is confirmed.
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
        print("The built-in display still hasn't come back. Close the lid, wait about 5 seconds, "
            + "then open it (leave this command running).")
    }
    controller.requestRestore(trigger: "--restore")

    let deadline = Date().addingTimeInterval(300)
    let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
        if !controller.restorePending, !controller.isRepairing, controller.panelStatus == .on {
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
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
