import AutoBlackoutCore
import Foundation

/// Runs the same restore-verification procedure as
/// `AutoBlackout --verify-restore --confirm-reboot-risk` (see `RestoreVerification`), but in-process
/// from the "Verify this Mac" menu item instead of a separate terminal command.
///
/// Deliberately reuses the app's own `BlackoutController` and its `LiveDisplaySystem`, instead of
/// spinning up a second controller against the same `UserDefaults`-backed state store: only one
/// piece of code should ever be deciding what the built-in display is doing at a time. The app's
/// existing 1-second poll, reconfiguration callback and sleep/wake handling all keep running as
/// usual and do the actual retry/power-cycle work; this class only watches the controller's state
/// and drives the disable -> hold -> restore sequence.
final class InAppHostVerifier {
    enum Phase: Equatable {
        case disabling
        case holding
        case restoring
        case succeeded
        case failed(FailureReason)
    }

    enum FailureReason: Equatable {
        /// The disable request never applied, so nothing was actually tested.
        case didNotDisable
        /// The restore didn't confirm within `giveUpSeconds`. The controller keeps retrying in the
        /// background regardless; this host just isn't marked verified.
        case timedOut
    }

    enum StartResult: Equatable {
        case started
        /// A run is already in progress; the caller should leave it alone.
        case busy
        case blocked([RestoreVerificationProblem])
    }

    private enum InternalPhase {
        case disabling
        case holding
        case restoring
    }

    /// Mirrors `RestoreVerification.holdSeconds`: gives the panel time to become
    /// hardware-disconnected before testing the restore.
    private static let holdSeconds: TimeInterval = 5
    private static let giveUpSeconds: TimeInterval = 600

    private let controller: BlackoutController
    private let system: LiveDisplaySystem
    private let store: DisplayStateStore
    private let logger: EventLogger

    private(set) var isRunning = false
    var onPhaseChange: ((Phase) -> Void)?

    private var timer: Timer?
    private var internalPhase = InternalPhase.disabling
    private var phaseStart = Date()

    init(controller: BlackoutController, system: LiveDisplaySystem, store: DisplayStateStore, logger: EventLogger) {
        self.controller = controller
        self.system = system
        self.store = store
        self.logger = logger
    }

    @discardableResult
    func start() -> StartResult {
        guard !isRunning else { return .busy }
        // Also refuse while the app's controller is mid-operation or already mid-restore: those are
        // real-time states `RestoreVerificationPreflight` (shared with the CLI) can't see, since a
        // freshly-started CLI process never has them.
        guard !controller.isChanging, !controller.restorePending else { return .busy }

        let problems = RestoreVerificationPreflight.problems(
            isAppleSilicon: HostInfo.isAppleSilicon,
            isAPIAvailable: controller.isAPIAvailable,
            snapshot: system.snapshot(),
            isLidClosed: HostInfo.isLidClosed,
            hasUnconfirmedManagedDisplay: store.managedDisplayID != nil
        )
        guard problems.isEmpty else {
            logger.log("in-app verify: preflight failed: " + problems.map(\.logDescription).joined(separator: ", "))
            return .blocked(problems)
        }

        logger.log("in-app verify: starting (" + HostVerification.current.description + ")")
        isRunning = true
        system.allowsDisableForVerification = true
        controller.isAutoModeEnabled = false
        internalPhase = .disabling
        phaseStart = Date()
        onPhaseChange?(.disabling)
        controller.requestDisable(trigger: "in-app-verify")

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return .started
    }

    private func tick() {
        let inPhase = Date().timeIntervalSince(phaseStart)
        switch internalPhase {
        case .disabling:
            guard !controller.isChanging else { return }
            guard controller.managedDisplay != nil else {
                logger.log("in-app verify: RESULT=disable did not apply; panel was never off")
                finish(.failed(.didNotDisable))
                return
            }
            logger.log("in-app verify: panel is off; restoring in \(Int(Self.holdSeconds))s")
            internalPhase = .holding
            phaseStart = Date()
            onPhaseChange?(.holding)

        case .holding:
            guard inPhase >= Self.holdSeconds else { return }
            internalPhase = .restoring
            phaseStart = Date()
            onPhaseChange?(.restoring)
            controller.requestRestore(trigger: "in-app-verify")

        case .restoring:
            if !controller.restorePending, !controller.isRepairing, controller.panelStatus == .on {
                logger.log(String(format: "in-app verify: RESULT=restored %.1fs after the restore started", inPhase))
                HostVerification.markCurrentHostVerified()
                logger.log("in-app verify: this host (\(HostVerification.current)) is now marked as verified")
                finish(.succeeded)
                return
            }
            if inPhase > Self.giveUpSeconds {
                logger.log("in-app verify: RESULT=not restored after \(Int(Self.giveUpSeconds))s; "
                    + "still retrying in the background")
                finish(.failed(.timedOut))
            }
            // No manual `evaluate()` call here: the app's own poll timer and reconfiguration callback
            // are already driving the same controller.
        }
    }

    private func finish(_ phase: Phase) {
        timer?.invalidate()
        timer = nil
        isRunning = false
        system.allowsDisableForVerification = false
        onPhaseChange?(phase)
    }
}

extension RestoreVerificationProblem {
    var localizedDescription: String {
        switch self {
        case .intelNotSupported:
            return L("This Mac has an Intel processor; the OFF feature isn't supported.")
        case .apiUnavailable:
            return L("The private display API isn't available on this macOS version.")
        case .builtInPanelNotOnline:
            return L("The built-in display isn't online right now.")
        case .noUsableExternalDisplay:
            return L("Connect and wake an external display first.")
        case .lidNotOpen:
            return L("Open the lid before verifying.")
        case .unconfirmedPreviousRestore:
            return L("A previous restore hasn't been confirmed yet — try “Force-restore built-in display” first.")
        }
    }
}
