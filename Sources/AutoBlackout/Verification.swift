import AutoBlackoutCore
import CoreGraphics
import Foundation

/// `AutoBlackout --verify-restore --confirm-reboot-risk [--after-unplug]`
///
/// 内蔵ディスプレイを1回だけOFFにし、アプリ本体と同じ復帰手順で戻るかを確かめる。
/// `--after-unplug` を付けると、自分からは復帰を要求せず、外部ディスプレイが抜かれて
/// 「使える外部ディスプレイがない」と判定されたときの復帰を確かめる。
/// 戻らなければ再起動が必要になるので、外部ディスプレイと電源をつなぎ、蓋を開けた状態で、人が見ているときにだけ実行する。
///
/// 自動OFFは使わない。再通電で外部ディスプレイがスリープ→復帰したのを「新しく接続された」と判定し、
/// 戻った直後に再びOFFにしてしまうことがあるため。
enum RestoreVerification {
    private enum Phase {
        case disabling
        case holding
        case waitingForUnplug
        case restoring
    }

    /// OFFにしてから復帰を始めるまでの時間。事故のときと同じく、パネルが切断扱い（hot plug 0）になるのを待つ。
    private static let holdSeconds: TimeInterval = 5
    private static let unplugWaitSeconds: TimeInterval = 180
    private static let giveUpSeconds: TimeInterval = 600

    static func run() -> Never {
        let logger = FileEventLogger(echo: true)
        logger.log("verify: " + HostInfo.summary)
        guard CommandLine.arguments.contains("--confirm-reboot-risk") else {
            print("戻らなければ再起動が必要になります。理解した上で --confirm-reboot-risk を付けて実行してください。")
            exit(64)
        }

        let system = LiveDisplaySystem(allowsDisableForVerification: true)
        let store = UserDefaultsStateStore()
        let controller = BlackoutController(
            system: system,
            store: store,
            scheduler: MainQueueScheduler(),
            logger: logger
        )
        controller.isAutoModeEnabled = false

        let snapshot = system.snapshot()
        var problems: [String] = []
        if !controller.isAPIAvailable { problems.append("private API unavailable") }
        if DisplayLogic.onlineBuiltIn(in: snapshot) == nil { problems.append("built-in panel is not online") }
        if DisplayLogic.usableExternals(in: snapshot).isEmpty { problems.append("no usable external display") }
        if HostInfo.isLidClosed != false { problems.append("lid is not open (or unknown)") }
        if store.managedDisplayID != nil { problems.append("a previous restore is unconfirmed (managedDisplayID is set)") }
        guard problems.isEmpty else {
            logger.log("verify: preflight failed: " + problems.joined(separator: ", "))
            exit(2)
        }

        let afterUnplug = CommandLine.arguments.contains("--after-unplug")
        logger.log("verify: mode=\(afterUnplug ? "after-unplug" : "manual-restore")")
        controller.launch()
        var phase = Phase.disabling
        var phaseStart = Date()
        var lidHintShown = false
        controller.requestDisable(trigger: "verify")

        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            let inPhase = Date().timeIntervalSince(phaseStart)
            switch phase {
            case .disabling:
                guard !controller.isChanging else { return }
                guard controller.managedDisplay != nil else {
                    logger.log("verify: RESULT=disable did not apply; panel was never off")
                    exit(3)
                }
                if afterUnplug {
                    logger.log("verify: panel is off; unplug the external display now (waiting up to \(Int(unplugWaitSeconds))s)")
                    phase = .waitingForUnplug
                } else {
                    logger.log("verify: panel is off; restoring in \(Int(holdSeconds))s")
                    phase = .holding
                }
                phaseStart = Date()

            case .waitingForUnplug:
                controller.evaluate(reason: "verify-wait-unplug")
                if controller.restorePending {
                    logger.log("verify: no usable external display; automatic restore started")
                    phase = .restoring
                    phaseStart = Date()
                } else if inPhase >= unplugWaitSeconds {
                    logger.log("verify: RESULT=unplug not detected; restoring without it")
                    controller.requestRestore(trigger: "verify-timeout")
                    phase = .restoring
                    phaseStart = Date()
                }

            case .holding:
                // 外部が外れた等で復帰が必要になれば、ここで既に復帰処理が始まる。
                controller.evaluate(reason: "verify-hold")
                guard inPhase >= holdSeconds else { return }
                phase = .restoring
                phaseStart = Date()
                controller.requestRestore(trigger: "verify")

            case .restoring:
                if !controller.restorePending, !controller.isRepairing, controller.panelStatus == .on {
                    logger.log(String(format: "verify: RESULT=restored %.1fs after the restore started", inPhase))
                    exit(0)
                }
                if controller.needsLidCycle, !lidHintShown {
                    lidHintShown = true
                    logger.log("verify: close the lid, wait about 5s, then open it (keep this process running)")
                }
                if inPhase > giveUpSeconds {
                    logger.log("verify: RESULT=not restored after \(Int(giveUpSeconds))s; a reboot is required")
                    exit(1)
                }
                controller.evaluate(reason: "poll")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        HeadlessMainLoop.run()
    }

    /// `AutoBlackout --power-cycle-displays`: 復帰手順の再通電だけを単独で試す（内蔵はONのまま）。
    static func powerCycleOnly() -> Never {
        let logger = FileEventLogger(echo: true)
        let system = LiveDisplaySystem()
        logger.log("power-cycle test: " + HostInfo.summary)
        system.powerCycleDisplays()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            let rows = system.snapshot().online.map { "\($0.id)[asleep=\($0.isAsleep ? 1 : 0) active=\($0.isActive ? 1 : 0)]" }
            logger.log("power-cycle test: after 8s online=\(rows.joined(separator: " "))")
            exit(0)
        }
        HeadlessMainLoop.run()
    }
}
