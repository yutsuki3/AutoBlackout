import AutoBlackoutCore
import CoreGraphics
import XCTest

/// Auto-OFF counts down before turning the built-in display off, so the user can keep it on.
final class AutoDisableCountdownTests: XCTestCase {
    private var system: FakeDisplaySystem!
    private var store: MemoryStore!
    private var scheduler: ManualScheduler!
    private var logger: RecordingLogger!
    private var clock = Date(timeIntervalSince1970: 0)
    private let countdown: TimeInterval = 5

    override func setUp() {
        system = FakeDisplaySystem()
        store = MemoryStore()
        scheduler = ManualScheduler()
        logger = RecordingLogger()
    }

    private func makeController() -> BlackoutController {
        BlackoutController(
            system: system, store: store, scheduler: scheduler, logger: logger,
            externalLossGrace: 0, autoDisableDelay: countdown, now: { [unowned self] in self.clock }
        )
    }

    private func connectExternal(_ c: BlackoutController) {
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
    }

    private func passTime(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    func testConnectStartsCountdownWithoutDisabling() {
        let c = makeController()
        c.launch()
        connectExternal(c)

        XCTAssertTrue(system.calls.isEmpty, "nothing is turned off when the countdown starts")
        XCTAssertEqual(c.autoDisableDeadline, clock.addingTimeInterval(countdown))
        XCTAssertTrue(system.panelEnabled)
    }

    func testPollsDuringCountdownDoNotDisable() {
        let c = makeController()
        c.launch()
        connectExternal(c)

        for _ in 0..<4 {
            passTime(1)
            c.evaluate(reason: "poll")
        }
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertNotNil(c.autoDisableDeadline)
    }

    func testCountdownEndingDisablesPanel() {
        let c = makeController()
        c.launch()
        connectExternal(c)

        passTime(countdown)
        scheduler.advance() // the scheduled end-of-countdown evaluate
        XCTAssertEqual(system.calls.last?.enabled, false)
        scheduler.advance() // verify the disable
        XCTAssertFalse(system.panelEnabled)
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)
        XCTAssertNil(c.autoDisableDeadline)
    }

    func testCancelKeepsPanelOnForThisConnection() {
        let c = makeController()
        c.launch()
        connectExternal(c)

        c.cancelPendingAutoDisable()
        XCTAssertNil(c.autoDisableDeadline)

        passTime(countdown)
        scheduler.advance()
        for _ in 0..<5 {
            passTime(1)
            c.evaluate(reason: "poll")
        }
        XCTAssertTrue(system.calls.isEmpty, "cancelling keeps the panel on while this monitor stays connected")
        XCTAssertTrue(system.panelEnabled)
    }

    func testReconnectAfterCancelCountsDownAgain() {
        let c = makeController()
        c.launch()
        connectExternal(c)
        c.cancelPendingAutoDisable()

        system.externals = []
        c.evaluate(reason: "callback")
        connectExternal(c)
        XCTAssertNotNil(c.autoDisableDeadline, "a new connection gets a new countdown")
    }

    func testUnplugDuringCountdownCancelsIt() {
        let c = makeController()
        c.launch()
        connectExternal(c)

        system.externals = []
        c.evaluate(reason: "callback")
        XCTAssertNil(c.autoDisableDeadline)

        passTime(countdown)
        scheduler.advance()
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testTurningAutoModeOffDuringCountdownCancelsIt() {
        let c = makeController()
        c.launch()
        connectExternal(c)

        c.isAutoModeEnabled = false
        passTime(countdown)
        scheduler.advance()
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertNil(c.autoDisableDeadline)
    }

    func testExternalSleepingDuringCountdownRestartsItWhenItWakes() {
        let c = makeController()
        c.launch()
        connectExternal(c)

        passTime(3)
        system.asleepExternals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        XCTAssertNil(c.autoDisableDeadline, "an asleep monitor can't show anything; don't keep counting")

        passTime(10)
        system.asleepExternals = []
        c.evaluate(reason: "callback")
        XCTAssertEqual(c.autoDisableDeadline, clock.addingTimeInterval(countdown), "the full countdown starts over")
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testManualOffDuringCountdownEndsIt() {
        let c = makeController()
        c.launch()
        connectExternal(c)

        c.toggleManually()
        XCTAssertNil(c.autoDisableDeadline)
        XCTAssertEqual(system.calls.last?.enabled, false)
    }

    func testCancelWithoutCountdownDoesNothing() {
        let c = makeController()
        c.launch()
        c.cancelPendingAutoDisable()
        XCTAssertFalse(logger.lines.contains { $0.contains("cancelled by user") })
    }
}
