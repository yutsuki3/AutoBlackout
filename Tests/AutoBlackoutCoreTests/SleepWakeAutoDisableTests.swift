import AutoBlackoutCore
import CoreGraphics
import XCTest

/// A system sleep/wake drops the external display out of the online list and brings it back; that
/// must not be mistaken for a new connection (which would auto-OFF the built-in display).
final class SleepWakeAutoDisableTests: XCTestCase {
    private var system: FakeDisplaySystem!
    private var store: MemoryStore!
    private var scheduler: ManualScheduler!
    private var logger: RecordingLogger!
    private var clock = Date(timeIntervalSince1970: 0)

    override func setUp() {
        system = FakeDisplaySystem()
        store = MemoryStore()
        scheduler = ManualScheduler()
        logger = RecordingLogger()
    }

    private func makeController() -> BlackoutController {
        BlackoutController(
            system: system, store: store, scheduler: scheduler, logger: logger,
            externalLossGrace: 0, now: { [unowned self] in self.clock }
        )
    }

    private func connectExternalAndAutoDisable(_ c: BlackoutController) {
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled)
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)
    }

    /// What a full system sleep/wake looked like on real hardware (USB-C monitor): every real display
    /// drops out of the online list, then the external reappears after the wake notifications.
    private func sleepAndWake(_ c: BlackoutController, externalBackAfter seconds: TimeInterval = 1) {
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        c.handlePowerEvent("NSWorkspaceScreensDidSleepNotification", transition: .sleep)
        system.externals = []
        c.evaluate(reason: "callback")
        c.handlePowerEvent("NSWorkspaceDidWakeNotification", transition: .wake)
        clock = clock.addingTimeInterval(seconds)
        system.externals = [FakeDisplaySystem.external]
        c.handlePowerEvent("NSWorkspaceScreensDidWakeNotification", transition: .wake)
        c.evaluate(reason: "NSWorkspaceScreensDidWakeNotification")
        scheduler.advance()
    }

    func testExternalReappearingAfterSystemSleepDoesNotAutoDisable() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch() // external already there at launch: no auto-OFF, the panel is ON
        XCTAssertTrue(system.panelEnabled)
        let callsBefore = system.calls.count

        sleepAndWake(c)

        XCTAssertTrue(system.panelEnabled, "waking from sleep isn't a new connection")
        XCTAssertEqual(system.calls.count, callsBefore, "no disable request may be sent")
        XCTAssertNil(c.managedDisplay)
    }

    func testExternalReappearingAFewSecondsAfterWakeStillDoesNotAutoDisable() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        sleepAndWake(c, externalBackAfter: BlackoutController.sleepResumeWindow - 1)
        XCTAssertTrue(system.panelEnabled)
    }

    // Reported from real use: the external was unplugged during sleep and the user plugged it back in
    // about 10 seconds after waking. That's a real connection, not the monitor resuming by itself
    // (which real logs show takes about 1 second).
    func testUserReplugTenSecondsAfterWakeIsANewConnection() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        system.externals = [] // unplugged during sleep
        c.evaluate(reason: "callback")
        c.handlePowerEvent("NSWorkspaceDidWakeNotification", transition: .wake)
        c.handlePowerEvent("NSWorkspaceScreensDidWakeNotification", transition: .wake)
        c.evaluate(reason: "NSWorkspaceScreensDidWakeNotification")
        XCTAssertTrue(system.panelEnabled)

        clock = clock.addingTimeInterval(10)
        system.externals = [FakeDisplaySystem.external] // the user plugs the monitor in
        c.evaluate(reason: "callback")
        scheduler.advance()

        XCTAssertFalse(system.panelEnabled, "auto-OFF must fire for a plug-in 10s after waking")
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)
    }

    func testResumeWindowIsShortComparedToAHumanReplug() {
        // Real logs: the monitor is back ~1s after the wake notifications. Keep the allowance well
        // below the time it takes to plug a cable in by hand.
        XCTAssertGreaterThanOrEqual(BlackoutController.sleepResumeWindow, 3)
        XCTAssertLessThanOrEqual(BlackoutController.sleepResumeWindow, 8)
    }

    func testDifferentExternalAfterWakeIsANewConnection() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        system.externals = []
        c.evaluate(reason: "callback")
        c.handlePowerEvent("NSWorkspaceDidWakeNotification", transition: .wake)
        system.externals = [FakeDisplaySystem.external + 1] // a different monitor was plugged in
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled, "a different display is a real new connection")
    }

    func testReplugAfterTheWakeWindowExpiresAutoDisables() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        sleepAndWake(c)
        XCTAssertTrue(system.panelEnabled)

        system.externals = []
        c.evaluate(reason: "callback")
        clock = clock.addingTimeInterval(BlackoutController.sleepResumeWindow + 1)
        c.evaluate(reason: "poll")
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled, "a plug-in long after waking is a new connection")
    }

    func testUnplugAndReplugRightAfterResumeAutoDisables() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        sleepAndWake(c)
        XCTAssertTrue(system.panelEnabled)

        // The resume was consumed, so a real unplug/replug inside the window still counts.
        system.externals = []
        c.evaluate(reason: "callback")
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled)
    }

    func testPlainConnectWithoutAnySleepStillAutoDisables() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)
    }

    func testSleepWithNoExternalDoesNotSuppressAFirstConnection() {
        let c = makeController()
        c.launch()
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        c.handlePowerEvent("NSWorkspaceDidWakeNotification", transition: .wake)
        connectExternalAndAutoDisable(c)
    }

    func testWakeResumeWhileAutoModeIsOffDoesNothing() {
        let c = makeController()
        c.isAutoModeEnabled = false
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        sleepAndWake(c)
        XCTAssertTrue(system.panelEnabled)
    }

    // MARK: - A panel that's missing around sleep/wake, though this app never disabled it

    /// The panel was never disabled by this app (managed == nil) but is missing from the online list,
    /// and the external display has been unplugged: what a real wake after unplugging looked like.
    private func panelMissingWithoutExternal() {
        system.externals = []
        system.panelEnabled = false
    }

    private var restoreRequests: Int { system.calls.filter { $0.enabled }.count }

    func testMissingPanelWhileSleepingIsNotRestored() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)

        panelMissingWithoutExternal()
        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }

        XCTAssertEqual(restoreRequests, 0, "don't send enable requests or power-cycle while going to sleep")
        XCTAssertEqual(system.powerCycleCount, 0)
        XCTAssertFalse(c.restorePending)
    }

    func testPanelReturningOnItsOwnAfterWakeNeverTriggersARestore() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        panelMissingWithoutExternal()
        c.evaluate(reason: "callback")
        c.handlePowerEvent("NSWorkspaceDidWakeNotification", transition: .wake)
        c.evaluate(reason: "callback")
        XCTAssertEqual(restoreRequests, 0)

        clock = clock.addingTimeInterval(1)
        system.panelEnabled = true // the panel came back by itself
        c.evaluate(reason: "poll")
        clock = clock.addingTimeInterval(BlackoutController.wakeSettleWindow + 1)
        c.evaluate(reason: "poll")

        XCTAssertEqual(restoreRequests, 0)
        XCTAssertFalse(c.restorePending)
    }

    func testPanelStillMissingAfterTheWakeSettleWindowIsRestored() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        panelMissingWithoutExternal()
        c.handlePowerEvent("NSWorkspaceDidWakeNotification", transition: .wake)
        c.evaluate(reason: "poll")
        XCTAssertEqual(restoreRequests, 0, "still settling")

        clock = clock.addingTimeInterval(BlackoutController.wakeSettleWindow + 1)
        c.evaluate(reason: "poll")
        scheduler.advance()

        XCTAssertGreaterThan(restoreRequests, 0, "a panel that never comes back is still restored")
        XCTAssertTrue(system.panelEnabled)
    }

    func testAnEndlessSleepDoesNotSuppressTheRestoreForever() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        panelMissingWithoutExternal()
        c.evaluate(reason: "poll")
        XCTAssertEqual(restoreRequests, 0)

        clock = clock.addingTimeInterval(BlackoutController.sleepSuppressionLimit + 1) // no wake ever seen
        c.evaluate(reason: "poll")
        scheduler.advance()

        XCTAssertGreaterThan(restoreRequests, 0)
    }

    func testPanelThisAppDisabledIsStillRestoredImmediatelyWhenTheExternalIsGoneAfterSleep() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c) // managed panel
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)

        system.externals = [] // unplugged while asleep
        c.evaluate(reason: "callback")
        scheduler.advance()

        XCTAssertTrue(system.panelEnabled, "our own disabled panel must not wait for sleep/wake to settle")
        XCTAssertNil(c.managedDisplay)
    }

    func testForceRestoreIsNeverDelayedBySleepWakeSettling() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        c.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        panelMissingWithoutExternal()

        c.requestRestore(trigger: "menu force-restore")
        scheduler.advance()

        XCTAssertGreaterThan(restoreRequests, 0)
        XCTAssertTrue(system.panelEnabled)
    }
}
