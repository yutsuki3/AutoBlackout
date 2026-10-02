import AutoBlackoutCore
import CoreGraphics
import XCTest

// MARK: - Pure geometry / timeline

final class TransitionGeometryTests: XCTestCase {
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testExternalOnTheRightPointsRight() throws {
        let v = try XCTUnwrap(TransitionGeometry.direction(from: builtIn, to: CGRect(x: 1512, y: 0, width: 2560, height: 1440)))
        XCTAssertGreaterThan(v.dx, 0)
    }

    func testExternalOnTheLeftPointsLeft() throws {
        let v = try XCTUnwrap(TransitionGeometry.direction(from: builtIn, to: CGRect(x: -2560, y: 0, width: 2560, height: 1440)))
        XCTAssertLessThan(v.dx, 0)
    }

    func testExternalAboveHasNegativeCGYAndPositiveAppKitY() throws {
        let above = CGRect(x: -400, y: -1440, width: 2560, height: 1440)
        let v = try XCTUnwrap(TransitionGeometry.direction(from: builtIn, to: above))
        XCTAssertLessThan(v.dy, 0, "CG's y axis points down")
        XCTAssertGreaterThan(TransitionGeometry.appKitVector(fromCG: v).dy, 0, "AppKit's y axis points up")
    }

    func testExternalBelowPointsDownInCGAndAppKitFlipsIt() throws {
        let below = CGRect(x: -400, y: 982, width: 2560, height: 1440)
        let v = try XCTUnwrap(TransitionGeometry.direction(from: builtIn, to: below))
        XCTAssertGreaterThan(v.dy, 0)
        XCTAssertLessThan(TransitionGeometry.appKitVector(fromCG: v).dy, 0)
    }

    func testDirectionIsNormalized() throws {
        let external = CGRect(x: 1512, y: 500, width: 2560, height: 1440)
        let v = try XCTUnwrap(TransitionGeometry.direction(from: builtIn, to: external))
        XCTAssertEqual(Double(v.dx * v.dx + v.dy * v.dy), 1, accuracy: 1e-9)
    }

    func testMirroredDisplayHasNoDirection() {
        XCTAssertNil(TransitionGeometry.direction(from: builtIn, to: builtIn))
    }

    func testEdgeDistance() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(TransitionGeometry.edgeDistance(in: size, along: CGVector(dx: 1, dy: 0)), 100, accuracy: 1e-9)
        XCTAssertEqual(TransitionGeometry.edgeDistance(in: size, along: CGVector(dx: 0, dy: -1)), 50, accuracy: 1e-9)
        XCTAssertEqual(TransitionGeometry.edgeDistance(in: size, along: .zero), 0)
    }
}

final class TransitionDestinationTests: XCTestCase {
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let boundsByID: [CGDirectDisplayID: CGRect] = [
        5: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        6: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        7: CGRect(x: 1512, y: 0, width: 1920, height: 1080), // nearer than 5 (smaller, same left edge)
        9: .zero,
    ]

    private func select(_ usable: Set<CGDirectDisplayID>, added: Set<CGDirectDisplayID> = []) -> CGDirectDisplayID? {
        TransitionGeometry.selectDestination(
            usable: usable, recentlyAdded: added, builtInBounds: builtIn, boundsOf: { self.boundsByID[$0] ?? .zero }
        )
    }

    func testSingleExternal() {
        XCTAssertEqual(select([5]), 5)
    }

    func testNewlyAddedDisplayWinsOverNearer() {
        XCTAssertEqual(select([5, 6], added: [6]), 6)
    }

    func testWithoutNewInformationTheNearestWins() {
        XCTAssertEqual(select([5, 7]), 7)
    }

    func testAddedButNotUsableIsIgnored() {
        XCTAssertEqual(select([5], added: [6]), 5)
    }

    func testEqualDistanceFallsBackToLowestID() {
        let twin: [CGDirectDisplayID: CGRect] = [
            12: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            11: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        ]
        let chosen = TransitionGeometry.selectDestination(
            usable: [12, 11], recentlyAdded: [], builtInBounds: builtIn, boundsOf: { twin[$0] ?? .zero }
        )
        XCTAssertEqual(chosen, 11)
    }

    func testDisplaysWithoutGeometryAreNeverChosen() {
        XCTAssertNil(select([9]))
        XCTAssertEqual(select([9, 5]), 5)
    }

    func testIsDeterministic() {
        let results = (0..<20).map { _ in select([5, 6, 7]) }
        XCTAssertEqual(Set(results).count, 1)
    }
}

final class TransitionTimelineTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let right = CGVector(dx: 1, dy: 0)

    func testEaseEndpointsAndMonotonic() {
        XCTAssertEqual(TransitionTimeline.ease(0), 0, accuracy: 1e-6)
        XCTAssertEqual(TransitionTimeline.ease(1), 1, accuracy: 1e-6)
        let values = stride(from: 0.0, through: 1.0, by: 0.05).map(TransitionTimeline.ease)
        XCTAssertEqual(values, values.sorted())
        XCTAssertGreaterThan(TransitionTimeline.ease(0.2), 0.2, "ease-out front-loads the motion")
    }

    func testBuiltInStartsAsFullScreen() {
        let frame = TransitionTimeline.builtInSurface(at: 0, in: bounds, vector: right)
        XCTAssertEqual(frame.rect.width, 1000, accuracy: 1e-6)
        XCTAssertEqual(frame.rect.midX, 500, accuracy: 1e-6)
    }

    func testBuiltInEndsSmallAndShiftedTowardTheVector() {
        let frame = TransitionTimeline.builtInSurface(at: 1, in: bounds, vector: right)
        XCTAssertEqual(Double(frame.rect.width), 1000 * TransitionTuning.minScale, accuracy: 1e-6)
        XCTAssertGreaterThan(frame.rect.midX, 500)
        XCTAssertEqual(frame.rect.midY, 300, accuracy: 1e-6)
    }

    func testExternalArrivesFromTheOppositeSideAndFillsTheScreen() {
        let start = TransitionTimeline.externalSurface(at: 0, in: bounds, vector: right)
        XCTAssertLessThan(start.rect.midX, 500, "comes in from the edge facing the MacBook")
        XCTAssertEqual(Double(start.rect.width), 1000 * TransitionTuning.minScale, accuracy: 1e-6)
        let end = TransitionTimeline.externalSurface(at: 1, in: bounds, vector: right)
        XCTAssertEqual(end.rect.width, 1000, accuracy: 1e-6)
        XCTAssertEqual(end.rect.midX, 500, accuracy: 1e-6)
    }

    func testCornerRadiusNeverExceedsHalfTheShortSide() {
        for index in 0...20 {
            let frame = TransitionTimeline.builtInSurface(at: Double(index) / 20, in: bounds, vector: right)
            XCTAssertLessThanOrEqual(frame.cornerRadius, min(frame.rect.width, frame.rect.height) / 2)
        }
    }

    func testSamplesIncludeBothEnds() {
        let frames = TransitionTimeline.samples(count: 10) {
            TransitionTimeline.builtInSurface(at: $0, in: bounds, vector: right)
        }
        XCTAssertEqual(frames.count, 11)
        XCTAssertEqual(frames.first, TransitionTimeline.builtInSurface(at: 0, in: bounds, vector: right))
        XCTAssertEqual(frames.last, TransitionTimeline.builtInSurface(at: 1, in: bounds, vector: right))
    }
}

// MARK: - Coordinator + controller

final class FakeTransitionPresenter: TransitionPresenter {
    var results: [TransitionPresentResult] = []
    private(set) var plans: [TransitionPlan] = []
    private(set) var dismissCount = 0
    /// Overlays currently on screen according to the last present/dismiss.
    private(set) var isShowing = false

    func present(_ plan: TransitionPlan) -> TransitionPresentResult {
        plans.append(plan)
        let result = results.isEmpty ? .started : results.removeFirst()
        isShowing = result == .started
        return result
    }

    func dismiss() {
        dismissCount += 1
        isShowing = false
    }
}

final class DisplayTransitionCoordinatorTests: XCTestCase {
    private static let panelBounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let externalBounds = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    private var system: FakeDisplaySystem!
    private var store: MemoryStore!
    private var controllerScheduler: ManualScheduler!
    private var transitionScheduler: ManualScheduler!
    private var logger: RecordingLogger!
    private var presenter: FakeTransitionPresenter!
    private var coordinator: DisplayTransitionCoordinator!
    private var controller: BlackoutController!
    private var clock = Date(timeIntervalSince1970: 1000)
    private var reduceMotion = false

    override func setUp() {
        system = FakeDisplaySystem()
        store = MemoryStore()
        controllerScheduler = ManualScheduler()
        transitionScheduler = ManualScheduler()
        logger = RecordingLogger()
        presenter = FakeTransitionPresenter()
        clock = Date(timeIntervalSince1970: 1000)
        reduceMotion = false

        controller = BlackoutController(
            system: system, store: store, scheduler: controllerScheduler, logger: logger,
            externalLossGrace: 0, now: { [unowned self] in self.clock }
        )
        coordinator = DisplayTransitionCoordinator(
            presenter: presenter,
            scheduler: transitionScheduler,
            logger: logger,
            bounds: { id in
                switch id {
                case FakeDisplaySystem.panel: return Self.panelBounds
                case FakeDisplaySystem.external: return Self.externalBounds
                default: return .zero
                }
            },
            usableExternals: { [unowned self] in DisplayLogic.usableExternals(in: self.system.snapshot()) },
            prefersReducedMotion: { [unowned self] in self.reduceMotion },
            now: { [unowned self] in self.clock }
        )
        controller.launch() // no external yet, so a later connection counts as new
        controller.autoDisableGate = coordinator
        coordinator.onRelease = { [unowned self] in self.controller.evaluate(reason: "transition") }
    }

    private var disableCalls: Int { system.calls.filter { !$0.enabled }.count }

    private func connectExternal() {
        system.externals = [FakeDisplaySystem.external]
        coordinator.handle(.didComplete(displayID: FakeDisplaySystem.external, flags: .addFlag))
        controller.evaluate(reason: "callback")
    }

    func testAutoDisableWaitsForTheAnimationAndThenProceeds() {
        connectExternal()

        XCTAssertEqual(presenter.plans.count, 1)
        XCTAssertEqual(presenter.plans.first?.destination, FakeDisplaySystem.external)
        XCTAssertEqual(presenter.plans.first?.motion, .full)
        XCTAssertGreaterThan(presenter.plans.first?.vector.dx ?? 0, 0)
        XCTAssertTrue(system.panelEnabled, "the panel stays ON while the animation runs")
        XCTAssertEqual(disableCalls, 0)
        XCTAssertTrue(presenter.isShowing)

        transitionScheduler.advance() // the animation ends

        XCTAssertEqual(disableCalls, 1)
        XCTAssertFalse(system.panelEnabled)
        XCTAssertEqual(controller.managedDisplay, FakeDisplaySystem.panel)
        XCTAssertFalse(presenter.isShowing, "overlays are removed once the disable was issued")
    }

    func testRepeatedEvaluatesAndCallbacksDoNotStartASecondTransition() {
        connectExternal()
        coordinator.handle(.didComplete(displayID: FakeDisplaySystem.external, flags: .addFlag))
        controller.evaluate(reason: "callback")
        controller.evaluate(reason: "poll")
        controller.evaluate(reason: "poll")
        XCTAssertEqual(presenter.plans.count, 1)
        XCTAssertEqual(disableCalls, 0)
    }

    func testNoSecondTransitionAfterTheDisableHasBeenIssued() {
        connectExternal()
        transitionScheduler.advance()
        controllerScheduler.advance()
        controller.evaluate(reason: "poll")
        XCTAssertEqual(presenter.plans.count, 1)
        XCTAssertEqual(disableCalls, 1)
    }

    func testExternalUnplugDuringTheAnimationNeverDisablesThePanel() {
        connectExternal()
        system.externals = []
        coordinator.handle(.didComplete(displayID: FakeDisplaySystem.external, flags: .removeFlag))
        controller.evaluate(reason: "callback")

        XCTAssertFalse(presenter.isShowing)
        XCTAssertTrue(logger.lines.contains { $0.contains("cancelled reason=externalDisconnected") })

        transitionScheduler.advance() // the stale completion timer must do nothing
        controller.evaluate(reason: "poll")
        XCTAssertEqual(disableCalls, 0)
        XCTAssertTrue(system.panelEnabled)
    }

    func testExternalUnplugWithoutAnyCallbackIsCaughtWhenTheTimerFires() {
        connectExternal()
        system.externals = []
        transitionScheduler.advance()

        XCTAssertEqual(disableCalls, 0)
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(presenter.isShowing)
    }

    func testOverlayFailureFallsBackToTheImmediateAutoDisable() {
        presenter.results = [.failed]
        connectExternal()
        XCTAssertEqual(disableCalls, 1, "an animation failure must not change the OFF behavior")
        XCTAssertFalse(presenter.isShowing)
    }

    func testWaitsForTheDestinationScreenThenAnimates() {
        presenter.results = [.destinationNotReady, .started]
        connectExternal()
        XCTAssertEqual(disableCalls, 0)
        XCTAssertFalse(presenter.isShowing)

        clock = clock.addingTimeInterval(0.5)
        controller.evaluate(reason: "screen-parameters")
        XCTAssertTrue(presenter.isShowing)
        XCTAssertEqual(disableCalls, 0)
    }

    func testGivesUpWaitingForTheDestinationScreen() {
        presenter.results = [.destinationNotReady, .destinationNotReady]
        connectExternal()
        XCTAssertEqual(disableCalls, 0)

        clock = clock.addingTimeInterval(DisplayTransitionCoordinator.screenWaitLimit + 0.1)
        controller.evaluate(reason: "poll")
        XCTAssertEqual(disableCalls, 1, "falls back to the immediate auto-OFF")
    }

    func testStuckAnimationIsAbandonedByTheWatchdog() {
        connectExternal()
        clock = clock.addingTimeInterval(TransitionTuning.fullDuration + DisplayTransitionCoordinator.watchdogMargin + 0.1)
        controller.evaluate(reason: "poll") // the completion timer never fired
        XCTAssertEqual(disableCalls, 1)
        XCTAssertFalse(presenter.isShowing)
    }

    func testSleepDuringTheAnimationCancelsItAndDoesNotRestartIt() {
        connectExternal()
        coordinator.handlePower(.sleep)
        XCTAssertFalse(presenter.isShowing)
        XCTAssertTrue(logger.lines.contains { $0.contains("cancelled reason=systemSleep") })

        controller.evaluate(reason: "poll")
        XCTAssertEqual(presenter.plans.count, 1, "no new animation while the Mac is asleep")
    }

    func testManualCancelRemovesTheOverlaysWithoutDisabling() {
        connectExternal()
        controller.isAutoModeEnabled = false
        coordinator.cancel(.manualAction)
        controller.evaluate(reason: "poll")
        XCTAssertFalse(presenter.isShowing)
        XCTAssertEqual(disableCalls, 0)
    }

    func testTerminationCancelRemovesTheOverlays() {
        connectExternal()
        coordinator.cancel(.applicationTermination)
        XCTAssertFalse(presenter.isShowing)
        XCTAssertFalse(coordinator.isAnimating)
    }

    func testReduceMotionUsesTheShortFadePlan() {
        reduceMotion = true
        connectExternal()
        XCTAssertEqual(presenter.plans.first?.motion, .reduced)
        XCTAssertEqual(presenter.plans.first?.duration, TransitionTuning.reducedDuration)
    }

    func testDisabledCoordinatorBehavesLikeBefore() {
        coordinator.isEnabled = false
        connectExternal()
        XCTAssertEqual(presenter.plans.count, 0)
        XCTAssertEqual(disableCalls, 1)
    }

    func testUnsupportedDisableNeverAnimates() {
        system.isDisableSupported = false
        connectExternal()
        XCTAssertEqual(presenter.plans.count, 0)
    }

    func testExternalAlreadyConnectedAtLaunchDoesNotAnimate() {
        system.externals = [FakeDisplaySystem.external]
        controller.launch()
        controller.evaluate(reason: "poll")
        XCTAssertEqual(presenter.plans.count, 0)
        XCTAssertTrue(system.panelEnabled)
    }

    func testReconnectingAfterSystemSleepDoesNotAnimate() {
        system.externals = [FakeDisplaySystem.external]
        controller.launch()

        controller.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        coordinator.handlePower(.sleep)
        system.externals = []
        controller.evaluate(reason: "callback")
        controller.handlePowerEvent("NSWorkspaceDidWakeNotification", transition: .wake)
        coordinator.handlePower(.wake)
        clock = clock.addingTimeInterval(1)
        system.externals = [FakeDisplaySystem.external]
        coordinator.handle(.didComplete(displayID: FakeDisplaySystem.external, flags: .addFlag))
        controller.evaluate(reason: "callback")

        XCTAssertEqual(presenter.plans.count, 0)
        XCTAssertEqual(disableCalls, 0)
        XCTAssertTrue(system.panelEnabled)
    }

    func testRealReplugLongAfterWakeAnimates() {
        system.externals = [FakeDisplaySystem.external]
        controller.launch()
        controller.handlePowerEvent("NSWorkspaceWillSleepNotification", transition: .sleep)
        coordinator.handlePower(.sleep)
        system.externals = []
        controller.evaluate(reason: "callback")
        controller.handlePowerEvent("NSWorkspaceDidWakeNotification", transition: .wake)
        coordinator.handlePower(.wake)
        clock = clock.addingTimeInterval(BlackoutController.sleepResumeWindow + 5)
        system.externals = [FakeDisplaySystem.external]
        coordinator.handle(.didComplete(displayID: FakeDisplaySystem.external, flags: .addFlag))
        controller.evaluate(reason: "callback")

        XCTAssertEqual(presenter.plans.count, 1)
        XCTAssertEqual(disableCalls, 0)
    }

    func testBeginPhaseAloneDoesNothing() {
        coordinator.handle(.willBegin(displayID: FakeDisplaySystem.external))
        XCTAssertEqual(presenter.plans.count, 0)
        XCTAssertFalse(coordinator.isAnimating)
    }
}
