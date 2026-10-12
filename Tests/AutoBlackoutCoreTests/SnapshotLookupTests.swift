import AutoBlackoutCore
import XCTest

/// The UI reads the panel status and external-display state from one shared snapshot; those lookups
/// must agree with the ones that take their own snapshot.
final class SnapshotLookupTests: XCTestCase {
    private var system: FakeDisplaySystem!
    private var scheduler: ManualScheduler!
    private var controller: BlackoutController!

    override func setUp() {
        system = FakeDisplaySystem()
        scheduler = ManualScheduler()
        controller = BlackoutController(
            system: system, store: MemoryStore(), scheduler: scheduler, logger: RecordingLogger(),
            externalLossGrace: 0
        )
        controller.launch()
    }

    private func connectExternalAndAutoDisable() {
        system.externals = [FakeDisplaySystem.external]
        controller.evaluate(reason: "callback")
        scheduler.advance()
    }

    func testLookupsMatchTheLiveOnesWhileOn() {
        XCTAssertEqual(controller.panelStatus(in: controller.currentSnapshot()), .on)
        XCTAssertEqual(controller.panelStatus(in: controller.currentSnapshot()), controller.panelStatus)
        XCTAssertFalse(controller.hasUsableExternalDisplay(in: controller.currentSnapshot()))
    }

    func testLookupsMatchTheLiveOnesWhileOff() {
        connectExternalAndAutoDisable()
        let snapshot = controller.currentSnapshot()
        XCTAssertEqual(controller.panelStatus(in: snapshot), .off)
        XCTAssertEqual(controller.panelStatus(in: snapshot), controller.panelStatus)
        XCTAssertTrue(controller.hasUsableExternalDisplay(in: snapshot))
        XCTAssertEqual(controller.hasUsableExternalDisplay(in: snapshot), controller.hasUsableExternalDisplay)
    }

    func testStatusReportsRestoringWhileARestoreIsPending() {
        connectExternalAndAutoDisable()
        system.ignoreEnableRequests = true
        controller.requestRestore(trigger: "manual")
        XCTAssertEqual(controller.panelStatus(in: controller.currentSnapshot()), .restoring)
    }
}
