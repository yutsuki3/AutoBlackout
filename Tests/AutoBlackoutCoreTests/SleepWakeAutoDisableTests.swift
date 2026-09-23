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

    func testExternalReappearingSlowlyAfterWakeStillDoesNotAutoDisable() {
        let c = makeController()
        system.externals = [FakeDisplaySystem.external]
        c.launch()
        sleepAndWake(c, externalBackAfter: 30)
        XCTAssertTrue(system.panelEnabled)
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
}
