import AutoBlackoutCore
import CoreGraphics
import XCTest

// MARK: - Fakes

/// Mimics real-hardware behavior: a disabled panel disappears from the online list (the condition
/// that reproduces bug 1).
final class FakeDisplaySystem: DisplaySystem {
    static let panel: CGDirectDisplayID = 1
    static let external: CGDirectDisplayID = 5

    var isToggleAvailable = true
    var isDisableSupported = true
    var lastErrorDescription: String?
    var panelEnabled = true
    /// The built-in panel is display-asleep (still present on the online list).
    var panelAsleep = false
    var externals: Set<CGDirectDisplayID> = []
    /// External displays that are connected but asleep (a subset of `externals`).
    var asleepExternals: Set<CGDirectDisplayID> = []
    /// Whether SLSGetDisplayList is available.
    var allListAvailable = false
    /// While true, enable requests report success but don't actually apply (the condition that
    /// reproduces bug 3).
    var ignoreEnableRequests = false
    /// While true, disable requests report success but don't actually apply.
    var ignoreDisableRequests = false
    /// While true, enable requests are rejected with 1001 (the M3's panel-treated-as-disconnected
    /// state after being disabled). Cleared by `powerCycleDisplays()` or (in tests) by setting this
    /// back to false directly, standing in for a lid cycle.
    var panelUnpowered = false
    /// If false, power-cycling the displays doesn't re-power the panel (the case that needs a lid cycle).
    var powerCycleRepowersPanel = true
    /// If true, external displays stay asleep for a while after a power cycle (waking up later than
    /// the built-in display).
    var powerCycleLeavesExternalsAsleep = false
    /// If true, a power cycle restores the panel through the screen-wake path instead of an enable
    /// request being applied.
    var powerCycleRestoresPanelDirectly = false
    var powerCycleCount = 0
    /// Hook invoked the instant setEnabled is called.
    var onSetEnabled: ((Bool) -> Void)?
    var calls: [(enabled: Bool, id: CGDirectDisplayID)] = []

    func snapshot() -> DisplaySnapshot {
        var online: [DisplayInfo] = []
        if panelEnabled {
            online.append(DisplayInfo(id: Self.panel, isBuiltin: true, isActive: !panelAsleep, isAsleep: panelAsleep))
        }
        online += externals.sorted().map { id in
            let asleep = asleepExternals.contains(id)
            return DisplayInfo(id: id, isBuiltin: false, isActive: !asleep, isAsleep: asleep)
        }
        let all = allListAvailable
            ? [DisplayInfo(id: Self.panel, isBuiltin: true)] + externals.sorted().map { DisplayInfo(id: $0, isBuiltin: false) }
            : nil
        return DisplaySnapshot(online: online, all: all)
    }

    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool {
        onSetEnabled?(enabled)
        calls.append((enabled, displayID))
        guard displayID == Self.panel else { return false }
        if enabled, panelEnabled || panelUnpowered {
            // Matches real hardware: an enable request for an already-ON panel is also rejected
            // with 1001 in the precheck.
            lastErrorDescription = "CGCompleteDisplayConfiguration=1001"
            return false
        }
        if enabled, ignoreEnableRequests { return true }
        if !enabled, ignoreDisableRequests { return true }
        panelEnabled = enabled
        return true
    }

    func powerCycleDisplays() {
        powerCycleCount += 1
        if powerCycleRepowersPanel { panelUnpowered = false }
        if powerCycleLeavesExternalsAsleep { asleepExternals = externals }
        if powerCycleRestoresPanelDirectly { panelEnabled = true }
    }
}

final class MemoryStore: DisplayStateStore {
    var lastKnownBuiltInID: CGDirectDisplayID?
    var managedDisplayID: CGDirectDisplayID?
}

final class ManualScheduler: Scheduler {
    private var pending: [() -> Void] = []
    var pendingCount: Int { pending.count }

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        pending.append(work)
    }

    /// Runs exactly one batch of scheduled work (i.e. advances time by one step).
    func advance() {
        let work = pending
        pending.removeAll()
        work.forEach { $0() }
    }
}

final class RecordingLogger: EventLogger {
    var lines: [String] = []
    func log(_ message: String) { lines.append(message) }
}

// MARK: - Tests

final class BlackoutControllerTests: XCTestCase {
    private var system: FakeDisplaySystem!
    private var store: MemoryStore!
    private var scheduler: ManualScheduler!
    private var logger: RecordingLogger!

    override func setUp() {
        system = FakeDisplaySystem()
        store = MemoryStore()
        scheduler = ManualScheduler()
        logger = RecordingLogger()
    }

    private var clock = Date(timeIntervalSince1970: 0)

    /// Existing scenarios are checked with no grace period (restore immediately when the external
    /// display disappears). Grace-period tests pass `externalLossGrace` explicitly.
    private func makeController(externalLossGrace: TimeInterval = 0) -> BlackoutController {
        BlackoutController(
            system: system, store: store, scheduler: scheduler, logger: logger,
            externalLossGrace: externalLossGrace, now: { [unowned self] in self.clock }
        )
    }

    private func connectExternalAndAutoDisable(_ c: BlackoutController) {
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled)
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)
    }

    // Bug 1: even after a disable drops the ID from the online list, it can still be restored.
    func testUnplugAfterAutoDisableRestoresPanel() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.externals = []
        c.evaluate(reason: "callback")
        XCTAssertEqual(system.calls.last?.enabled, true)
        XCTAssertEqual(system.calls.last?.id, FakeDisplaySystem.panel)
        scheduler.advance()

        XCTAssertTrue(system.panelEnabled)
        XCTAssertNil(c.managedDisplay)
        XCTAssertNil(store.managedDisplayID)
        XCTAssertFalse(c.restorePending)
    }

    func testPanelIDIsCachedWhileDisabled() {
        let c = makeController()
        c.launch()
        XCTAssertEqual(store.lastKnownBuiltInID, FakeDisplaySystem.panel)
        connectExternalAndAutoDisable(c)
        XCTAssertNil(DisplayLogic.onlineBuiltIn(in: system.snapshot()))
        XCTAssertEqual(c.builtInPanelID(), FakeDisplaySystem.panel)
    }

    // Bug 2: explicitly restores on quit.
    func testTerminationRestoresManagedPanel() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        c.prepareForTermination()
        XCTAssertTrue(system.panelEnabled)
    }

    func testTerminationDoesNothingWhenPanelIsOn() {
        let c = makeController()
        c.launch()
        c.prepareForTermination()
        XCTAssertTrue(system.calls.isEmpty)
    }

    // Bug 3: retries until confirmed if the API reports success without actually applying.
    func testRestoreIsRetriedUntilVerified() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.ignoreEnableRequests = true
        system.externals = []
        c.evaluate(reason: "callback")
        scheduler.advance() // verify -> not applied -> retry
        scheduler.advance()
        let enableCalls = system.calls.filter(\.enabled).count
        XCTAssertGreaterThanOrEqual(enableCalls, 3)
        XCTAssertTrue(c.restorePending)
        XCTAssertEqual(c.panelStatus, .restoring)

        system.ignoreEnableRequests = false
        scheduler.advance() // 3rd failure -> power cycle (enters the settle delay)
        scheduler.advance() // enable request after the settle delay
        scheduler.advance() // verify
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.restorePending)
        XCTAssertNil(c.managedDisplay)
    }

    func testDisableThatDidNotApplyClearsManagedState() {
        system.ignoreDisableRequests = true
        let c = makeController()
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertNil(c.managedDisplay)
        XCTAssertEqual(c.panelStatus, .on)
    }

    // Request 1: a previous process crashed with the panel disabled -> the new process restores it at launch.
    func testLaunchSelfHealsFromPersistedState() {
        system.panelEnabled = false
        store.managedDisplayID = FakeDisplaySystem.panel

        let c = makeController()
        c.launch()
        XCTAssertEqual(system.calls.last?.enabled, true)
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
        XCTAssertNil(store.managedDisplayID)
    }

    func testLaunchSelfHealsUsingOnlyCachedID() {
        system.panelEnabled = false
        store.lastKnownBuiltInID = FakeDisplaySystem.panel

        let c = makeController()
        c.launch()
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testLaunchSelfHealsUsingAllDisplayListWhenNoCache() {
        system.panelEnabled = false
        system.allListAvailable = true

        let c = makeController()
        c.launch()
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testLaunchAdoptsDisabledPanelWhileExternalConnected() {
        system.panelEnabled = false
        system.externals = [FakeDisplaySystem.external]
        store.lastKnownBuiltInID = FakeDisplaySystem.panel

        let c = makeController()
        c.launch()
        XCTAssertFalse(system.panelEnabled, "OK to stay OFF while an external display is present")
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)

        system.externals = []
        c.evaluate(reason: "poll")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    // Request 2: corrected by polling even without a callback.
    func testPollingRestoresWithoutCallback() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.externals = [] // no callback arrives
        c.evaluate(reason: "poll")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testUnplugDuringDisableVerificationRestores() {
        let c = makeController()
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        XCTAssertFalse(system.panelEnabled)

        system.externals = [] // disconnects while verification is pending
        c.evaluate(reason: "callback") // no-op: isChanging is true
        scheduler.advance() // verify -> no external -> restore requested
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testReplacementDisplayDoesNotKeepPanelOff() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.externals = [99] // the original monitor disappeared, a different ID showed up
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    // Safety rule: never disable manually either, with no external display present.
    func testManualDisableRefusedWithoutExternal() {
        let c = makeController()
        c.launch()
        c.toggleManually()
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertTrue(system.panelEnabled)
    }

    func testManualRestoreIsNotUndoneByAutoMode() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        c.toggleManually() // turn back ON
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)

        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertTrue(system.panelEnabled, "a manual restore isn't overridden by auto-OFF even with the external still connected")
    }

    func testAutoModeOffDoesNotDisable() {
        let c = makeController()
        c.isAutoModeEnabled = false
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testLaunchWithExternalDoesNotAutoDisable() {
        system.externals = [FakeDisplaySystem.external]
        let c = makeController()
        c.launch()
        XCTAssertTrue(system.calls.isEmpty)
    }

    // On hosts where OFF is known to strand the panel until reboot, never disable, automatically or manually.
    func testDisableIsNeverCalledWhenUnsupported() {
        system.isDisableSupported = false
        let c = makeController()
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        c.toggleManually()
        scheduler.advance()
        XCTAssertFalse(system.calls.contains { !$0.enabled })
        XCTAssertTrue(system.panelEnabled)
        XCTAssertNil(c.managedDisplay)
    }

    // M3: if enable requests keep getting rejected with 1001, power-cycle the displays and retry.
    func testRejectedRestorePowerCyclesDisplaysThenSucceeds() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.panelUnpowered = true
        c.requestRestore(trigger: "manual")
        for _ in 0..<(BlackoutController.failuresBeforeFirstPowerCycle - 1) { scheduler.advance() }
        XCTAssertEqual(system.powerCycleCount, 0, "doesn't flash the screen right away")
        XCTAssertFalse(system.panelEnabled)

        scheduler.advance() // 3rd failure -> power cycle
        XCTAssertEqual(system.powerCycleCount, 1)
        let callsAtPowerCycle = system.calls.count
        XCTAssertTrue(c.isChanging, "doesn't send enable requests until the power cycle settles")
        scheduler.advance() // enable request after the settle delay
        XCTAssertEqual(system.calls.count, callsAtPowerCycle + 1)
        XCTAssertTrue(system.panelEnabled)
        scheduler.advance() // verify
        XCTAssertFalse(c.restorePending)
        XCTAssertFalse(c.needsLidCycle)
        XCTAssertNil(store.managedDisplayID)
    }

    func testPowerCyclesAreCappedThenLidCycleRestores() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.panelUnpowered = true
        system.powerCycleRepowersPanel = false
        system.externals = []
        c.evaluate(reason: "callback")
        for _ in 0..<200 { scheduler.advance() }
        XCTAssertEqual(system.powerCycleCount, BlackoutController.maxPowerCycles, "flashing is capped")
        XCTAssertTrue(c.needsLidCycle)
        XCTAssertTrue(c.restorePending, "keeps retrying instead of giving up")
        XCTAssertEqual(c.panelStatus, .restoring)

        system.panelUnpowered = false // lid closed and reopened
        scheduler.advance() // the next enable request succeeds
        scheduler.advance() // verify
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.needsLidCycle)
        XCTAssertFalse(c.restorePending)
    }

    func testNoPowerCycleWhenRestoreSucceedsImmediately() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.externals = []
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
        XCTAssertEqual(system.powerCycleCount, 0)
    }

    func testPowerCycleCounterResetsForNextRestore() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)
        system.panelUnpowered = true
        system.powerCycleRepowersPanel = false
        c.requestRestore(trigger: "manual")
        for _ in 0..<200 { scheduler.advance() }
        system.panelUnpowered = false
        scheduler.advance()
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.restorePending)

        // Power cycling is available again on the second OFF -> restore round too.
        system.externals = []
        c.evaluate(reason: "poll")
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled)
        system.panelUnpowered = true
        system.powerCycleRepowersPanel = true
        c.requestRestore(trigger: "manual")
        for _ in 0..<6 { scheduler.advance() }
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.restorePending)
        XCTAssertEqual(system.powerCycleCount, BlackoutController.maxPowerCycles + 1)
    }

    // Power events are logged with the panel/display state, and logging never changes anything.
    func testLogPowerEventRecordsStateAndSendsNoRequests() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)
        let callsBefore = system.calls.count
        let linesBefore = logger.lines.count

        c.logPowerEvent("NSWorkspaceWillSleepNotification")
        system.asleepExternals = [FakeDisplaySystem.external]
        c.logPowerEvent("NSWorkspaceScreensDidSleepNotification")

        let power = Array(logger.lines.dropFirst(linesBefore)).filter { $0.hasPrefix("power: ") }
        XCTAssertEqual(power.count, 2)
        XCTAssertTrue(power[0].contains("NSWorkspaceWillSleepNotification"))
        XCTAssertTrue(power[0].contains("panel=\(FakeDisplaySystem.panel) managed=\(FakeDisplaySystem.panel)"), power[0])
        XCTAssertTrue(power[1].contains("slp=1"), "the external's sleep state is captured: \(power[1])")
        XCTAssertEqual(system.calls.count, callsBefore, "logging must not send any request")
        XCTAssertEqual(system.powerCycleCount, 0)
        XCTAssertFalse(system.panelEnabled)
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)
    }

    // A sleep/wake that leaves everything unchanged still leaves a trace, unlike `evaluate`, which
    // only logs when the state changed.
    func testLogPowerEventLogsEvenWhenNothingChanged() {
        let c = makeController()
        c.launch()
        c.evaluate(reason: "poll")
        let before = logger.lines.count
        c.logPowerEvent("NSWorkspaceDidWakeNotification")
        c.logPowerEvent("NSWorkspaceDidWakeNotification")
        XCTAssertEqual(logger.lines.count, before + 2)
    }

    // Idle display sleep across every screen shouldn't restore the panel, and waking shouldn't re-disable it
    // (since a power cycle would wake the screen).
    func testIdleDisplaySleepKeepsPanelOffWithoutRedisable() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)
        let callsBefore = system.calls.count

        system.asleepExternals = [FakeDisplaySystem.external]
        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertEqual(system.calls.count, callsBefore, "an idle sleep doesn't restore the built-in display")
        XCTAssertEqual(system.powerCycleCount, 0)

        system.asleepExternals = []
        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertEqual(system.calls.count, callsBefore, "waking isn't treated as a new connection, so it doesn't re-disable")
        XCTAssertFalse(system.panelEnabled)
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)
    }

    // An asleep external display still counts as "connected" regardless of sleep notifications; only
    // restore once it disappears from the list.
    func testAsleepExternalKeepsPanelOffUntilRemoved() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.asleepExternals = [FakeDisplaySystem.external]
        for _ in 0..<3 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertFalse(system.panelEnabled)
        XCTAssertFalse(c.restorePending)

        system.externals = []
        system.asleepExternals = []
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    // A built-in display sleep with no external connected shouldn't be mistaken for "it got turned off".
    func testBuiltInIdleSleepWithoutExternalDoesNothing() {
        let c = makeController()
        c.launch()
        system.panelAsleep = true
        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertEqual(system.powerCycleCount, 0)
        XCTAssertEqual(c.panelStatus, .on)
    }

    // An enable request that was accepted but never applied, restored instead via the power-cycle wake
    // path -> power-cycle once more while ON to fix the resulting state.
    func testWakePathRestoreTriggersResyncPowerCycle() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.ignoreEnableRequests = true // accepted but never applied ("Failed to plug display 1")
        system.powerCycleRestoresPanelDirectly = true
        c.requestRestore(trigger: "manual")
        for _ in 0..<BlackoutController.failuresBeforeFirstPowerCycle { scheduler.advance() }
        XCTAssertEqual(system.powerCycleCount, 1)
        XCTAssertTrue(system.panelEnabled, "restored via the wake path")

        scheduler.advance() // the enable request after the settle delay gets 1001 (already ON)
        scheduler.advance() // verify -> confirmed -> repair power cycle
        XCTAssertFalse(c.restorePending)
        XCTAssertTrue(c.isRepairing)
        XCTAssertEqual(system.powerCycleCount, 2)

        scheduler.advance()
        XCTAssertFalse(c.isRepairing)
        XCTAssertEqual(system.powerCycleCount, 2)
        XCTAssertTrue(system.panelEnabled)
    }

    func testNoResyncAfterCleanRestore() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.panelUnpowered = true
        c.requestRestore(trigger: "manual")
        for _ in 0..<10 { scheduler.advance() }
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.isRepairing)
        XCTAssertEqual(system.powerCycleCount, 1)
    }

    // If the power cycle restores the built-in display first and the external wakes late, don't
    // auto-disable immediately after it comes back.
    func testNoAutoDisableWhenExternalWakesAfterPowerCycleRestore() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.panelUnpowered = true
        system.powerCycleLeavesExternalsAsleep = true
        c.requestRestore(trigger: "manual")
        for _ in 0..<BlackoutController.failuresBeforeFirstPowerCycle { scheduler.advance() }
        XCTAssertEqual(system.powerCycleCount, 1)
        scheduler.advance() // enable request after the settle delay
        scheduler.advance() // verify
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.restorePending)

        system.asleepExternals = [] // the external wakes late
        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertTrue(system.panelEnabled, "doesn't auto-disable right after restoring")
        XCTAssertEqual(system.calls.filter { !$0.enabled }.count, 1, "only the original disable")
    }

    func testExternalConnectedWhileAsleepAutoDisablesOnceAwake() {
        let c = makeController()
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        system.asleepExternals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertTrue(system.calls.isEmpty, "doesn't disable while it's asleep")

        system.asleepExternals = []
        c.evaluate(reason: "poll")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled, "runs the connection-triggered auto-OFF once it wakes")
    }

    func testEnablingAutoModeLaterDoesNotActOnEarlierConnection() {
        let c = makeController()
        c.isAutoModeEnabled = false
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")

        c.isAutoModeEnabled = true
        c.evaluate(reason: "poll")
        XCTAssertTrue(system.calls.isEmpty)
    }

    // A brief disconnect/reconnect of the external display on wake shouldn't restore the built-in
    // display (avoids a flash of on-then-immediately-off).
    func testBriefExternalDropDoesNotRestore() {
        let c = makeController(externalLossGrace: 3)
        c.launch()
        connectExternalAndAutoDisable(c)
        let callsBefore = system.calls.count

        system.externals = []
        c.evaluate(reason: "callback")
        clock += 0.7
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        clock += 3
        scheduler.advance() // re-evaluation after the grace period
        for _ in 0..<3 { c.evaluate(reason: "poll"); scheduler.advance() }

        XCTAssertEqual(system.calls.count, callsBefore)
        XCTAssertFalse(system.panelEnabled)
        XCTAssertFalse(c.restorePending)
    }

    func testExternalLossRestoresAfterGrace() {
        let c = makeController(externalLossGrace: 3)
        c.launch()
        connectExternalAndAutoDisable(c)
        let callsBefore = system.calls.count

        system.externals = []
        c.evaluate(reason: "callback")
        clock += 1
        c.evaluate(reason: "poll")
        XCTAssertEqual(system.calls.count, callsBefore, "doesn't restore during the grace period")

        clock += 2.1
        scheduler.advance() // re-evaluation after the grace period -> restore requested
        XCTAssertEqual(system.calls.last?.enabled, true)
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testLaunchWithoutExternalRestoresImmediatelyEvenWithGrace() {
        system.panelEnabled = false
        store.managedDisplayID = FakeDisplaySystem.panel
        let c = makeController(externalLossGrace: 3)
        c.launch()
        XCTAssertEqual(system.calls.last?.enabled, true)
    }

    func testHeadlessFallbackIsNotUsableExternal() {
        let snapshot = DisplaySnapshot(online: [
            DisplayInfo(id: 7, isBuiltin: false, vendor: 0x756e_6b6e, model: 0x7669_7274),
        ])
        XCTAssertTrue(DisplayLogic.usableExternals(in: snapshot).isEmpty)
    }

    func testManagedStateIsPersistedBeforeAPICall() {
        var managedAtCall: CGDirectDisplayID?
        system.onSetEnabled = { [store] enabled in
            if !enabled { managedAtCall = store?.managedDisplayID }
        }
        let c = makeController()
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        XCTAssertEqual(managedAtCall, FakeDisplaySystem.panel)
    }
}
