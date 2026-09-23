import AutoBlackoutCore
import CoreGraphics
import Foundation

/// `AutoBlackout --verify-restore --confirm-reboot-risk [--after-unplug]`
///
/// Disables the built-in display once and checks whether the app's own restore procedure brings it
/// back. With `--after-unplug`, it doesn't request the restore itself; instead it checks the restore
/// that happens once the external display is unplugged and "no usable external display" is
/// detected. If it doesn't come back, a reboot is needed, so only run this with an external display
/// and power connected, the lid open, and someone watching.
///
/// On success, this host (this exact Mac model + macOS build) is remembered as verified, which is
/// what lets `AutoBlackout` use the disable feature going forward — see
/// `PrivateDisplayAPI.isDisableAllowed`.
///
/// Auto-disable is not used here: it could mistake the external display waking from sleep during
/// the power cycle for a fresh connection and immediately disable the panel again right after it
/// comes back.
enum RestoreVerification {
    private enum Phase {
        case disabling
        case holding
        case waitingForUnplug
        case restoring
    }

    /// How long to wait after disabling before starting the restore. Mirrors the real accidents:
    /// gives the panel time to become hardware-disconnected (hot plug 0).
    private static let holdSeconds: TimeInterval = 5
    private static let unplugWaitSeconds: TimeInterval = 180
    private static let giveUpSeconds: TimeInterval = 600

    static func run() -> Never {
        let logger = FileEventLogger(echo: true)
        logger.log("verify: " + HostInfo.summary)
        guard CommandLine.arguments.contains("--confirm-reboot-risk") else {
            print("If the display doesn't come back, a reboot will be required. "
                + "Pass --confirm-reboot-risk once you understand that and want to proceed.")
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
        if !HostInfo.isAppleSilicon { problems.append("Intel Macs are not supported") }
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
                // If a restore becomes necessary for another reason (e.g. the external display
                // dropped), it will already have started by the time we get here.
                controller.evaluate(reason: "verify-hold")
                guard inPhase >= holdSeconds else { return }
                phase = .restoring
                phaseStart = Date()
                controller.requestRestore(trigger: "verify")

            case .restoring:
                if !controller.restorePending, !controller.isRepairing, controller.panelStatus == .on {
                    logger.log(String(format: "verify: RESULT=restored %.1fs after the restore started", inPhase))
                    HostVerification.markCurrentHostVerified()
                    logger.log("verify: this host (\(HostVerification.current)) is now marked as verified; "
                        + "the disable feature is available")
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

    /// `AutoBlackout --power-cycle-displays`: tries just the restore procedure's power-cycle step on
    /// its own, without touching the built-in panel's enabled state.
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
