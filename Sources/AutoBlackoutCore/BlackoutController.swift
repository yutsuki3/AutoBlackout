import CoreGraphics
import Foundation

/// The state machine that decides whether the built-in display should be ON or OFF.
///
/// Top rule: **never leave the built-in display disabled when there's no usable external display.**
///
/// - State is never read from an in-memory flag; every decision is based on a fresh
///   `DisplaySystem.snapshot()`. (A past accident lost the "we think it's OFF" flag and ID, leaving
///   the app unable to restore anything.)
/// - A disabled built-in display's ID disappears from the online list, so it's tracked separately in
///   `managedDisplay` (the ID this instance disabled) and `store.lastKnownBuiltInID` (a persisted
///   cache).
/// - The API can report success without the change actually applying, so it's re-verified against
///   reality after `verifyDelay`. Retries continue on every `evaluate` call until the restore is
///   confirmed.
/// - `evaluate` is the single correction loop called from the reconfiguration callback, the 1-second
///   poll, and launch.
public final class BlackoutController {
    public enum PanelStatus: Equatable {
        case apiUnavailable
        case notFound
        case on
        case off
        case restoring
    }

    public var isAutoModeEnabled = true

    /// Notifies the UI whenever the state may have changed.
    public var onStateChange: (() -> Void)?

    public private(set) var managedDisplay: CGDirectDisplayID? {
        didSet { store.managedDisplayID = managedDisplay }
    }

    public private(set) var restorePending = false
    public private(set) var isChanging = false
    /// Power-cycling the display exhausted its budget without a restore. The user needs to cycle the lid.
    public private(set) var needsLidCycle = false
    /// A power cycle is in progress to fix up WindowServer's panel connection state after a restore
    /// (`startRepairCycle`). Termination should wait for this to finish.
    public private(set) var isRepairing = false

    /// Failures allowed before the first power cycle (about one attempt per second).
    public static let failuresBeforeFirstPowerCycle = 3
    /// Failures allowed between power cycles. A sleep-to-wake cycle takes a few seconds, so this
    /// spaces them out.
    public static let failuresBetweenPowerCycles = 20
    /// The cap on automatic power cycles per restore attempt, so the screen doesn't keep flickering.
    public static let maxPowerCycles = 2
    /// How long after waking an external display that was connected before sleeping counts as
    /// "resuming" rather than a new connection. USB-C monitors drop out of the online list during a
    /// system sleep/wake and can take a while to come back.
    public static let sleepResumeWindow: TimeInterval = 60
    /// How long after a wake a built-in panel this app never disabled may stay missing from the online
    /// list before it counts as disabled. The panel normally comes back within about a second of a
    /// wake; restoring earlier only power-cycles the displays for nothing.
    public static let wakeSettleWindow: TimeInterval = 8
    /// The longest a sleep notification without a matching wake suppresses that same restore, so a
    /// missed wake notification can't hold it off forever.
    public static let sleepSuppressionLimit: TimeInterval = 300
    /// How long to wait after starting a power cycle before sending the next enable request.
    /// Sending it while displays are asleep blocks for up to 10s waiting on WindowServer to
    /// reconfigure and then fails with 1014, which also delays waking the screens (confirmed on
    /// real hardware).
    public static let powerCycleSettleDelay: TimeInterval = 6

    private let system: DisplaySystem
    private let store: DisplayStateStore
    private let scheduler: Scheduler
    private let logger: EventLogger
    private let verifyDelay: TimeInterval
    /// The grace period between an external display disappearing from the list and restoring the
    /// built-in display. USB-C monitors can briefly disconnect and reconnect on wake (about 0.7s on
    /// real hardware); restoring immediately would cause a flash of the built-in panel turning on
    /// and auto-OFF turning it right back off, repeatedly.
    private let externalLossGrace: TimeInterval
    private let now: () -> Date
    /// When the external display was last seen missing. `nil` while it's visible.
    private var externalLostAt: Date?

    /// The external displays that were usable at the moment of disabling. If all of these disappear,
    /// restore even if some other display (e.g. a virtual one) shows up afterward.
    private var externalsAtDisable: Set<CGDirectDisplayID>?
    /// Whether an external display was connected on the previous `evaluate` call (counts as
    /// connected while asleep). Auto-OFF only fires on the "zero -> some" transition; waking from
    /// sleep doesn't count as a new connection.
    private var previousHadExternal: Bool?
    /// The external displays that were connected when the system (or its screens) went to sleep. On
    /// wake, one of these reappearing is the same monitor coming back, not a new connection, even
    /// though it left the online list in between (real hardware: every real display drops out during
    /// a system sleep/wake, leaving only a headless fallback).
    private var externalsBeforeSleep: Set<CGDirectDisplayID>?
    /// Between a sleep notification and the matching wake. The panel and external displays come and
    /// go while the Mac is asleep or has only briefly woken, so a missing panel means nothing then.
    private var isSleeping = false
    private var sleepStartedAt: Date?
    private var lastWakeAt: Date?
    private var loggedPowerSettleWait = false
    /// When the wake-resume allowance ends. `nil` while still asleep (no wake seen yet).
    private var sleepResumeDeadline: Date?
    /// A newly connected external display is waiting for auto-OFF. If it was asleep when it
    /// connected, this waits until it wakes.
    private var autoDisablePending = false
    private var restoreAttempts = 0
    private var powerCycles = 0
    private var failuresSincePowerCycle = 0
    /// Whether WindowServer accepted the most recent enable request.
    private var lastEnableAccepted = false
    /// An enable request was accepted but never applied (WindowServer logs "Failed to plug display 1").
    private var sawUnappliedEnable = false
    private var lastLoggedState: String?
    private var loggedExternalLossWait = false
    private var loggedPanelUnknown = false

    public init(
        system: DisplaySystem,
        store: DisplayStateStore,
        scheduler: Scheduler,
        logger: EventLogger,
        verifyDelay: TimeInterval = 1.0,
        externalLossGrace: TimeInterval = 3.0,
        now: @escaping () -> Date = Date.init
    ) {
        self.system = system
        self.store = store
        self.scheduler = scheduler
        self.logger = logger
        self.verifyDelay = verifyDelay
        self.externalLossGrace = externalLossGrace
        self.now = now
        self.managedDisplay = store.managedDisplayID
    }

    public var isAPIAvailable: Bool { system.isToggleAvailable }
    public var isDisableSupported: Bool { system.isDisableSupported }

    // MARK: - State lookups

    /// The built-in panel's ID. Resolved in this priority order so it's never lost while disabled:
    /// 1. the ID this instance disabled  2. the online list's built-in display  3. the persisted
    /// cache  4. `SLSGetDisplayList`'s built-in display.
    public func builtInPanelID(in snapshot: DisplaySnapshot? = nil) -> CGDirectDisplayID? {
        let snapshot = snapshot ?? system.snapshot()
        if let managedDisplay { return managedDisplay }
        if let online = DisplayLogic.onlineBuiltIn(in: snapshot) {
            if store.lastKnownBuiltInID != online { store.lastKnownBuiltInID = online }
            return online
        }
        return store.lastKnownBuiltInID ?? DisplayLogic.anyBuiltIn(in: snapshot)
    }

    public var panelStatus: PanelStatus {
        guard isAPIAvailable else { return .apiUnavailable }
        let snapshot = system.snapshot()
        guard let panel = builtInPanelID(in: snapshot) else { return .notFound }
        if restorePending { return .restoring }
        return DisplayLogic.isPanelEnabled(panel, in: snapshot) ? .on : .off
    }

    public var isBuiltInDisplayOff: Bool {
        let status = panelStatus
        return status == .off || status == .restoring
    }

    public var hasUsableExternalDisplay: Bool {
        !DisplayLogic.usableExternals(in: system.snapshot()).isEmpty
    }

    // MARK: - Entry points

    /// Self-heals at launch: if a previous process crashed while the built-in display was disabled,
    /// this detects it and restores it.
    public func launch() {
        let snapshot = system.snapshot()
        let panel = builtInPanelID(in: snapshot)
        logger.log("launch: api=\(isAPIAvailable) persistedManaged=\(describe(managedDisplay)) " + describe(snapshot))

        if managedDisplay == nil, let panel,
           !snapshot.online.contains(where: { $0.id == panel }) {
            // Missing from the online list means something disabled it. Adopt it so it's guaranteed
            // to be restored on quit.
            logger.log("launch: panel \(panel) is missing from online list; adopting it as managed")
            managedDisplay = panel
        }
        previousHadExternal = !DisplayLogic.presentExternals(in: snapshot).isEmpty
        // No grace period needed if there's no external display at launch (e.g. a previous process
        // crashed while it was disabled) — restore right away.
        if previousHadExternal == false { externalLostAt = .distantPast }
        evaluate(reason: "launch")
    }

    /// Measures the current state and restores (or auto-disables) as needed. Safe to call any
    /// number of times.
    public func evaluate(reason: String) {
        let snapshot = system.snapshot()
        let panel = builtInPanelID(in: snapshot)
        let usable = DisplayLogic.usableExternals(in: snapshot)
        let present = DisplayLogic.presentExternals(in: snapshot)
        // An external display that's asleep still counts as "connected"; only restore once it
        // disappears from the list entirely. `CGDisplayIsAsleep` is set when the Mac puts the screen
        // to sleep. Restoring on an idle display sleep would wake the screen again via the power
        // cycle on the M3 (and the external's sleep has been observed to appear before the sleep
        // notification itself, on real hardware).
        let hasExternal = externalsAtDisable.map { !present.isDisjoint(with: $0) } ?? !present.isEmpty
        if previousHadExternal == false, !present.isEmpty {
            if resumesAfterSleep(present) {
                logger.log("external display \(sorted(present)) is back after sleep; not a new connection")
            } else {
                autoDisablePending = true
            }
        }
        if present.isEmpty || !isAutoModeEnabled { autoDisablePending = false }
        previousHadExternal = !present.isEmpty
        if hasExternal {
            externalLostAt = nil
        } else if externalLostAt == nil {
            externalLostAt = now()
            // Make sure evaluate runs again once the grace period elapses, even with no callback or
            // poll in between.
            if externalLossGrace > 0 {
                scheduler.schedule(after: externalLossGrace) { [weak self] in
                    self?.evaluate(reason: "external-loss-grace")
                }
            }
        }
        let externalLossConfirmed = externalLostAt.map { now().timeIntervalSince($0) >= externalLossGrace } ?? false

        logStateIfChanged(reason: reason, snapshot: snapshot, panel: panel)

        guard !isChanging else { return }
        guard isAPIAvailable, let panel else {
            if !loggedPanelUnknown {
                // Nothing can be done while the panel can't be found. Still leave a trace in the log.
                logger.log("cannot act (\(reason)): api=\(isAPIAvailable) panel=nil")
                loggedPanelUnknown = true
            }
            onStateChange?()
            return
        }
        loggedPanelUnknown = false

        let enabled = DisplayLogic.isPanelEnabled(panel, in: snapshot)

        if managedDisplay != nil, !hasExternal, !externalLossConfirmed, !restorePending, !loggedExternalLossWait {
            logger.log("external display gone (\(reason)); restoring in \(externalLossGrace)s unless it comes back")
            loggedExternalLossWait = true
        }
        if hasExternal { loggedExternalLossWait = false }

        if managedDisplay != nil, externalLossConfirmed, !restorePending {
            logger.log("recovery required (\(reason)): no external display remains; "
                + "present=\(sorted(present)) atDisable=\(sorted(externalsAtDisable))")
            restorePending = true
        }

        // A panel this app never disabled, missing while the Mac is (re)entering sleep or has just
        // woken (e.g. the external was unplugged during sleep): the displays are still settling and
        // the panel normally reappears by itself. Restoring now only power-cycles the displays, which
        // wakes a Mac that is trying to go back to sleep. Wait; if it's still missing once things
        // settle, the normal restore below takes over.
        if !enabled, managedDisplay == nil, !restorePending, isPowerSettling {
            if !loggedPowerSettleWait {
                logger.log("panel \(panel) missing during sleep/wake but not disabled by this app (\(reason)); "
                    + "waiting for displays to settle")
                loggedPowerSettleWait = true
            }
            onStateChange?()
            return
        }
        loggedPowerSettleWait = false

        if restorePending || (!enabled && externalLossConfirmed) {
            attemptRestore(panel, reason: reason)
            return
        }

        if enabled, managedDisplay != nil {
            // The built-in display was enabled by something else; clear our managed state.
            logger.log("panel \(panel) observed enabled while managed; clearing managed state")
            clearManagedState()
        }

        if isAutoModeEnabled, autoDisablePending, enabled, !usable.isEmpty {
            autoDisablePending = false
            logger.log("auto: external display connected \(sorted(usable))")
            disable(panel, usable: usable, trigger: "auto")
            return
        }

        onStateChange?()
    }

    public enum PowerTransition {
        case sleep
        case wake
    }

    /// Handles a sleep/wake notification: logs it with the panel state, and remembers which external
    /// displays were connected going to sleep so that their return on wake isn't mistaken for a new
    /// connection (which would auto-OFF the built-in display after every wake). Sends no request.
    public func handlePowerEvent(_ name: String, transition: PowerTransition) {
        logPowerEvent(name)
        switch transition {
        case .sleep:
            if !isSleeping { sleepStartedAt = now() }
            isSleeping = true
            let present = DisplayLogic.presentExternals(in: system.snapshot())
            // A second sleep notification arrives after the externals are already gone; keep the
            // first record instead of overwriting it with nothing.
            if !present.isEmpty {
                externalsBeforeSleep = present
                sleepResumeDeadline = nil
            }
        case .wake:
            isSleeping = false
            lastWakeAt = now()
            if externalsBeforeSleep != nil { sleepResumeDeadline = now().addingTimeInterval(Self.sleepResumeWindow) }
        }
    }

    private var isPowerSettling: Bool {
        if isSleeping, let started = sleepStartedAt, now().timeIntervalSince(started) < Self.sleepSuppressionLimit {
            return true
        }
        if let wake = lastWakeAt, now().timeIntervalSince(wake) < Self.wakeSettleWindow { return true }
        return false
    }

    /// Whether `present` is the same external display(s) coming back after a sleep. Consumes the
    /// record when it is, so a real unplug/replug right afterwards still counts as a new connection.
    private func resumesAfterSleep(_ present: Set<CGDirectDisplayID>) -> Bool {
        guard let before = externalsBeforeSleep else { return false }
        if let deadline = sleepResumeDeadline, now() >= deadline {
            externalsBeforeSleep = nil
            sleepResumeDeadline = nil
            return false
        }
        guard !present.isDisjoint(with: before) else { return false }
        externalsBeforeSleep = nil
        sleepResumeDeadline = nil
        return true
    }

    /// Records a power event (sleep, wake, screen sleep/wake) together with the panel and display
    /// state at that moment. Log-only: it never changes any state or sends any request. `evaluate`
    /// only logs when the state changed, so without this a sleep/wake that leaves everything as it
    /// was (the common case) would leave no trace at all.
    public func logPowerEvent(_ name: String) {
        let snapshot = system.snapshot()
        logger.log("power: \(name) panel=\(describe(builtInPanelID(in: snapshot))) "
            + "managed=\(describe(managedDisplay)) pending=\(restorePending) " + describe(snapshot))
    }

    public func toggleManually() {
        if isBuiltInDisplayOff {
            requestRestore(trigger: "manual")
        } else {
            requestDisable(trigger: "manual")
        }
    }

    /// The manual "turn OFF" action. Refused if there's no external display.
    public func requestDisable(trigger: String) {
        let snapshot = system.snapshot()
        guard !isChanging, !restorePending, isAPIAvailable, let panel = builtInPanelID(in: snapshot) else {
            logger.log("\(trigger) off refused: changing=\(isChanging) pending=\(restorePending) api=\(isAPIAvailable)")
            return
        }
        guard DisplayLogic.isPanelEnabled(panel, in: snapshot) else { return }
        disable(panel, usable: DisplayLogic.usableExternals(in: snapshot), trigger: trigger)
    }

    /// The manual "turn ON" action. Always sends an enable request, even if the online list already
    /// looks ON.
    public func requestRestore(trigger: String) {
        logger.log("\(trigger) restore requested")
        autoDisablePending = false
        restorePending = true
        evaluate(reason: trigger)
    }

    /// Called synchronously right before quitting. Restores the panel if this instance disabled it
    /// and it's still off.
    /// Not called on SIGKILL etc. — the next launch's `launch()` and the persisted `managedDisplay`
    /// are the fallback for that.
    public func prepareForTermination() {
        let snapshot = system.snapshot()
        logger.log("terminate: managed=\(describe(managedDisplay)) " + describe(snapshot))
        guard let panel = managedDisplay ?? builtInPanelID(in: snapshot),
              managedDisplay != nil || !DisplayLogic.isPanelEnabled(panel, in: snapshot)
        else { return }
        let ok = system.setEnabled(true, for: panel)
        logger.log("terminate: restore panel=\(panel) apiResult=\(ok)\(errorSuffix(ok))")
        // No time to verify this, so leave `managedDisplay` (persisted) as-is; it clears once the
        // next launch confirms the panel is actually enabled.
    }

    // MARK: - Actually switching

    private func disable(_ panel: CGDirectDisplayID, usable: Set<CGDirectDisplayID>, trigger: String) {
        guard system.isDisableSupported else {
            logger.log("\(trigger) off refused: disabling is not supported (cannot guarantee restore)")
            onStateChange?()
            return
        }
        guard !usable.isEmpty else {
            logger.log("\(trigger) off refused: no usable external display")
            onStateChange?()
            return
        }
        // Persist before making the API call, so a crash right after can still restore on next launch.
        externalsAtDisable = usable
        managedDisplay = panel
        isChanging = true
        let ok = system.setEnabled(false, for: panel)
        logger.log("\(trigger) off: panel=\(panel) apiResult=\(ok)\(errorSuffix(ok)) externals=\(sorted(usable))")
        onStateChange?()

        scheduler.schedule(after: verifyDelay) { [weak self] in
            self?.verifyDisable(panel, trigger: trigger)
        }
    }

    private func verifyDisable(_ panel: CGDirectDisplayID, trigger: String) {
        isChanging = false
        let snapshot = system.snapshot()
        if DisplayLogic.isPanelEnabled(panel, in: snapshot) {
            logger.log("\(trigger) off not applied: panel \(panel) is still enabled")
            clearManagedState()
        } else {
            logger.log("\(trigger) off verified: panel \(panel) is disabled")
        }
        // If the external display was disconnected while verification was in flight, this
        // immediately corrects for it.
        evaluate(reason: "verify-off")
    }

    private func attemptRestore(_ panel: CGDirectDisplayID, reason: String) {
        restorePending = true
        isChanging = true
        restoreAttempts += 1
        let ok = system.setEnabled(true, for: panel)
        lastEnableAccepted = ok
        if restoreAttempts <= 5 || restoreAttempts % 30 == 0 {
            logger.log("restore attempt #\(restoreAttempts) (\(reason)): panel=\(panel) apiResult=\(ok)\(errorSuffix(ok))")
        }
        onStateChange?()

        scheduler.schedule(after: verifyDelay) { [weak self] in
            self?.verifyRestore(panel)
        }
    }

    private func verifyRestore(_ panel: CGDirectDisplayID) {
        isChanging = false
        let snapshot = system.snapshot()
        if DisplayLogic.isPanelEnabled(panel, in: snapshot) {
            logger.log("restore confirmed: panel \(panel) after \(restoreAttempts) attempt(s)")
            let needsRepair = sawUnappliedEnable && !lastEnableAccepted
            clearManagedState()
            if needsRepair { startRepairCycle() }
            onStateChange?()
        } else {
            if lastEnableAccepted { sawUnappliedEnable = true }
            // A reported success doesn't guarantee it applied. Keep retrying until it's confirmed.
            if restoreAttempts <= 5 || restoreAttempts % 30 == 0 {
                logger.log("restore unconfirmed: panel \(panel); retrying")
            }
            if powerCycleIfStillFailing() {
                isChanging = true
                scheduler.schedule(after: Self.powerCycleSettleDelay) { [weak self] in
                    self?.isChanging = false
                    self?.evaluate(reason: "after-power-cycle")
                }
                return
            }
            evaluate(reason: "verify-restore")
        }
    }

    /// Power-cycles the displays if enable requests keep getting rejected. Once the cap is reached,
    /// asks the user to cycle the lid instead.
    ///
    /// Observed on a MacBook Air M3 (Mac15,12 / macOS 26.7): right after disabling, IOMFB logs
    /// "Display 1 hot plug 0", and WindowServer rejects enable requests with 1001 in a precheck from
    /// then on. Sending an enable request after the panel is re-powered ("hot plug 1") — via a
    /// display sleep/wake or opening and closing the lid — succeeds (confirmed on real hardware,
    /// 2026-09-23). A power cycle alone isn't enough; the follow-up enable request is what restores it.
    /// - Returns: whether a power cycle was started.
    private func powerCycleIfStillFailing() -> Bool {
        failuresSincePowerCycle += 1
        let threshold = powerCycles == 0 ? Self.failuresBeforeFirstPowerCycle : Self.failuresBetweenPowerCycles
        guard failuresSincePowerCycle >= threshold else { return false }
        failuresSincePowerCycle = 0

        guard powerCycles < Self.maxPowerCycles else {
            if !needsLidCycle {
                needsLidCycle = true
                logger.log("restore still failing after \(powerCycles) display power cycle(s); "
                    + "waiting for the lid to be closed and reopened (retries continue)")
                onStateChange?()
            }
            return false
        }
        powerCycles += 1
        logger.log("restore failing: power-cycling displays #\(powerCycles) to re-power the panel")
        system.powerCycleDisplays()
        return true
    }

    /// Cleans up after an enable request was accepted but never applied ("Failed to plug display 1"),
    /// and the panel came back via a screen-wake path instead.
    ///
    /// That kind of restore leaves WindowServer's panel connection state out of sync: the next
    /// disable only drops it from the configuration without actually powering it off (screen stays
    /// lit). Confirmed on real hardware to happen after opening and closing the lid while the panel
    /// was off (2026-09-23). One more power cycle while ON lets the panel's hotplug "in" event get
    /// processed and reconnects it correctly.
    private func startRepairCycle() {
        logger.log("panel came back without a successful enable; power-cycling once more to re-sync WindowServer")
        isRepairing = true
        isChanging = true
        system.powerCycleDisplays()
        scheduler.schedule(after: Self.powerCycleSettleDelay) { [weak self] in
            guard let self else { return }
            self.isRepairing = false
            self.isChanging = false
            self.logger.log("re-sync power cycle finished")
            self.evaluate(reason: "after-repair")
        }
    }

    private func clearManagedState() {
        managedDisplay = nil
        externalsAtDisable = nil
        restorePending = false
        restoreAttempts = 0
        powerCycles = 0
        failuresSincePowerCycle = 0
        needsLidCycle = false
        lastEnableAccepted = false
        sawUnappliedEnable = false
    }

    // MARK: - Logging

    private func logStateIfChanged(reason: String, snapshot: DisplaySnapshot, panel: CGDirectDisplayID?) {
        let state = "panel=\(describe(panel)) managed=\(describe(managedDisplay)) pending=\(restorePending) "
            + "changing=\(isChanging) auto=\(isAutoModeEnabled) repairing=\(isRepairing) " + describe(snapshot)
        guard state != lastLoggedState else { return }
        lastLoggedState = state
        logger.log("state (\(reason)): " + state)
    }

    private func errorSuffix(_ ok: Bool) -> String {
        ok ? "" : " error=\(system.lastErrorDescription ?? "unknown")"
    }

    private func describe(_ id: CGDirectDisplayID?) -> String {
        id.map { String($0) } ?? "nil"
    }

    private func describe(_ snapshot: DisplaySnapshot) -> String {
        func row(_ d: DisplayInfo) -> String {
            "\(d.id)[b=\(d.isBuiltin ? 1 : 0) on=\(d.isOnline ? 1 : 0) act=\(d.isActive ? 1 : 0) "
                + "slp=\(d.isAsleep ? 1 : 0) mir=\(d.isInMirrorSet ? 1 : 0)"
                + (d.isHeadlessFallback ? " fallback" : "") + "]"
        }
        let all = snapshot.all.map { $0.map(\.id).map(String.init).joined(separator: ",") } ?? "n/a"
        return "online={\(snapshot.online.map(row).joined(separator: " "))} all={\(all)}"
    }

    private func sorted(_ ids: Set<CGDirectDisplayID>?) -> [CGDirectDisplayID] {
        (ids ?? []).sorted()
    }
}
