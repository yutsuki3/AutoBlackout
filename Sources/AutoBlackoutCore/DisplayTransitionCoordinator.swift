import CoreGraphics
import Foundation

/// Owns the lifecycle of the display-transfer animation and decides when the controller may issue
/// its automatic OFF. It never turns a display off itself: it only holds the controller back while
/// the animation runs, then asks it to re-evaluate (`onRelease`). The controller keeps making every
/// safety decision from a fresh snapshot.
///
/// The animation is purely cosmetic, so every doubt resolves toward "stop animating and let the
/// controller do what it always did": a failed overlay, a timeout, a sleep or a vanished display
/// all end with the hold released or the overlays removed, never with the panel left unrestorable.
public final class DisplayTransitionCoordinator: AutoDisableGate {
    private struct Run {
        let generation: Int
        let destination: CGDirectDisplayID
        let startedAt: Date
        let duration: TimeInterval
    }

    private enum Phase {
        case idle
        /// The destination has no `NSScreen` yet.
        case waitingForScreens(since: Date)
        case running(Run)
        /// The animation finished: the next gate query lets the auto-OFF through exactly once.
        case released(until: Date)
    }

    /// How long to wait for the destination's `NSScreen` before giving up and turning off at once.
    public static let screenWaitLimit: TimeInterval = 2
    /// Slack beyond the animation's duration before a stuck animation is abandoned.
    public static let watchdogMargin: TimeInterval = 1
    /// How long the "go ahead" token stays valid if the controller doesn't consume it.
    public static let releaseWindow: TimeInterval = 5
    /// How long a display counts as newly added after its `addFlag` callback.
    public static let recentAddWindow: TimeInterval = 10

    public var isEnabled = true
    /// Called when the controller should re-evaluate (animation finished or aborted).
    public var onRelease: (() -> Void)?

    private let presenter: TransitionPresenter
    private let scheduler: Scheduler
    private let logger: EventLogger
    private let bounds: (CGDirectDisplayID) -> CGRect
    private let usableExternals: () -> Set<CGDirectDisplayID>
    private let prefersReducedMotion: () -> Bool
    private let now: () -> Date

    private var phase = Phase.idle
    private var generation = 0
    private var isSleeping = false
    private var recentlyAdded: [CGDirectDisplayID: Date] = [:]

    public init(
        presenter: TransitionPresenter,
        scheduler: Scheduler,
        logger: EventLogger,
        bounds: @escaping (CGDirectDisplayID) -> CGRect,
        usableExternals: @escaping () -> Set<CGDirectDisplayID>,
        prefersReducedMotion: @escaping () -> Bool = { false },
        now: @escaping () -> Date = Date.init
    ) {
        self.presenter = presenter
        self.scheduler = scheduler
        self.logger = logger
        self.bounds = bounds
        self.usableExternals = usableExternals
        self.prefersReducedMotion = prefersReducedMotion
        self.now = now
    }

    public var isAnimating: Bool {
        switch phase {
        case .running, .waitingForScreens: return true
        case .idle, .released: return false
        }
    }

    // MARK: - Events

    /// Feeds display reconfiguration notifications. Never decides anything from `willBegin`.
    public func handle(_ event: DisplayReconfigurationEvent) {
        switch event {
        case .willBegin(let displayID):
            if isAnimating { logger.log("transition: reconfiguration began during animation id=\(displayID)") }
        case .didComplete(let displayID, let flags):
            if flags.contains(.addFlag) {
                recentlyAdded[displayID] = now()
                logger.log("transition: display added id=\(displayID)")
            }
            guard case .running(let run) = phase, !usableExternals().contains(run.destination) else { return }
            abort(.externalDisconnected)
            onRelease?()
        }
    }

    public func handlePower(_ transition: BlackoutController.PowerTransition) {
        switch transition {
        case .sleep:
            isSleeping = true
            cancel(.systemSleep)
        case .wake:
            isSleeping = false
        }
    }

    /// Stops any animation and removes its overlays. Never turns a display off, and doesn't ask the
    /// controller to re-evaluate (the 1-second poll covers that).
    public func cancel(_ reason: TransitionCancellationReason) {
        switch phase {
        case .running, .waitingForScreens:
            abort(reason)
        case .released:
            phase = .idle
        case .idle:
            break
        }
    }

    // MARK: - AutoDisableGate

    public func shouldHoldAutoDisable(panel: CGDirectDisplayID, usable: Set<CGDirectDisplayID>) -> Bool {
        if case .released(let until) = phase {
            phase = .idle
            if now() < until {
                logger.log("transition: requesting panel disable")
                return false
            }
        }
        switch phase {
        case .running(let run):
            return continueRun(run, usable: usable)
        case .waitingForScreens(let since):
            return begin(panel: panel, usable: usable, waitingSince: since)
        case .idle, .released:
            return begin(panel: panel, usable: usable, waitingSince: nil)
        }
    }

    // MARK: - Lifecycle

    private func begin(panel: CGDirectDisplayID, usable: Set<CGDirectDisplayID>, waitingSince: Date?) -> Bool {
        pruneRecentlyAdded()
        guard isEnabled, !isSleeping else {
            phase = .idle
            return false
        }
        let builtInBounds = bounds(panel)
        guard !builtInBounds.isEmpty,
              let destination = TransitionGeometry.selectDestination(
                  usable: usable, recentlyAdded: Set(recentlyAdded.keys),
                  builtInBounds: builtInBounds, boundsOf: bounds
              )
        else {
            logger.log("transition: skipped (no destination geometry)")
            phase = .idle
            return false
        }
        let vector = TransitionGeometry.direction(from: builtInBounds, to: bounds(destination)) ?? .zero
        let motion: TransitionMotion = prefersReducedMotion() ? .reduced : .full
        let plan = TransitionPlan(
            builtIn: panel, destination: destination, vector: vector, motion: motion,
            duration: motion == .full ? TransitionTuning.fullDuration : TransitionTuning.reducedDuration
        )
        switch presenter.present(plan) {
        case .started:
            generation += 1
            let current = generation
            phase = .running(Run(generation: current, destination: destination, startedAt: now(), duration: plan.duration))
            recentlyAdded.removeAll()
            logger.log("transition: destination id=\(destination) dx=\(format(vector.dx)) dy=\(format(vector.dy)) "
                + "motion=\(motion == .full ? "full" : "reduced")")
            logger.log("transition: started")
            scheduler.schedule(after: plan.duration) { [weak self] in self?.complete(generation: current) }
            return true
        case .destinationNotReady:
            let since = waitingSince ?? now()
            guard now().timeIntervalSince(since) < Self.screenWaitLimit else {
                logger.log("transition: skipped (destination screen not ready after \(Self.screenWaitLimit)s)")
                phase = .idle
                return false
            }
            if waitingSince == nil { logger.log("transition: waiting for destination screen id=\(destination)") }
            phase = .waitingForScreens(since: since)
            return true
        case .failed:
            logger.log("transition: skipped (overlay creation failed)")
            presenter.dismiss()
            phase = .idle
            return false
        }
    }

    /// A gate query while the animation runs: keep holding unless the destination is gone or the
    /// animation is stuck.
    private func continueRun(_ run: Run, usable: Set<CGDirectDisplayID>) -> Bool {
        guard usable.contains(run.destination) else {
            abort(.externalDisconnected)
            return false
        }
        guard now().timeIntervalSince(run.startedAt) <= run.duration + Self.watchdogMargin else {
            abort(.timeout)
            return false
        }
        return true
    }

    private func complete(generation finished: Int) {
        guard case .running(let run) = phase, run.generation == finished else { return }
        guard usableExternals().contains(run.destination) else {
            abort(.externalDisconnected)
            onRelease?()
            return
        }
        phase = .released(until: now().addingTimeInterval(Self.releaseWindow))
        logger.log("transition: completed")
        // The controller re-checks a fresh snapshot and issues the disable inside this call; only
        // then are the overlays removed, so the built-in display never flashes its desktop first.
        onRelease?()
        presenter.dismiss()
    }

    private func abort(_ reason: TransitionCancellationReason) {
        generation += 1
        phase = .idle
        presenter.dismiss()
        logger.log("transition: cancelled reason=\(reason.rawValue)")
    }

    private func pruneRecentlyAdded() {
        let current = now()
        recentlyAdded = recentlyAdded.filter { current.timeIntervalSince($0.value) < Self.recentAddWindow }
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}
