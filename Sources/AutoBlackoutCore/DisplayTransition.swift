import CoreGraphics
import Foundation

// Pure types and functions for the display-transfer animation. Nothing here touches a window or a
// real display; the AppKit side lives in the executable target behind `TransitionPresenter`.

/// A display reconfiguration notification, split into its two phases. Only `didComplete` describes
/// a settled topology; `willBegin` must never be used to decide anything about the new layout.
public enum DisplayReconfigurationEvent: Equatable {
    case willBegin(displayID: CGDirectDisplayID)
    case didComplete(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags)
}

public enum TransitionCancellationReason: String {
    case externalDisconnected
    case systemSleep
    case manualAction
    case superseded
    case applicationTermination
    case timeout
}

public enum TransitionMotion: Equatable {
    case full
    /// Reduce Motion: no travel and no scaling, only a short fade.
    case reduced
}

/// Which way the surface moves. Only `transferOut` (MacBook -> external) exists today; a
/// `restoreIn` case can be added alongside a presenter implementation for it.
public enum DisplayTransitionDirection: Equatable {
    case transferOut
}

public struct TransitionPlan: Equatable {
    public var direction: DisplayTransitionDirection
    public var builtIn: CGDirectDisplayID
    public var destination: CGDirectDisplayID
    /// Unit vector from the built-in display toward the destination in Core Graphics coordinates
    /// (y grows downward). `.zero` when the two displays share a center (e.g. mirrored).
    public var vector: CGVector
    public var motion: TransitionMotion
    public var duration: TimeInterval

    public init(
        direction: DisplayTransitionDirection = .transferOut,
        builtIn: CGDirectDisplayID,
        destination: CGDirectDisplayID,
        vector: CGVector,
        motion: TransitionMotion,
        duration: TimeInterval
    ) {
        self.direction = direction
        self.builtIn = builtIn
        self.destination = destination
        self.vector = vector
        self.motion = motion
        self.duration = duration
    }
}

public enum TransitionPresentResult: Equatable {
    case started
    /// The destination display isn't visible to AppKit yet (`NSScreen` lags the CG callback).
    case destinationNotReady
    case failed
}

/// Draws the transition. Best-effort: every implementation must be safe to `dismiss` at any time,
/// any number of times.
public protocol TransitionPresenter: AnyObject {
    func present(_ plan: TransitionPlan) -> TransitionPresentResult
    func dismiss()
}

/// Lets something outside the state machine delay the automatic OFF. Consulted only when an auto-OFF
/// is otherwise ready to be issued (real new connection, usable external, panel ON).
public protocol AutoDisableGate: AnyObject {
    /// - Returns: `true` to hold the auto-OFF for now. It is asked again on every later `evaluate`.
    func shouldHoldAutoDisable(panel: CGDirectDisplayID, usable: Set<CGDirectDisplayID>) -> Bool
}

/// The knobs for the look and timing. Phases overlap on purpose; the fractions are of the duration.
public enum TransitionTuning {
    public static let fullDuration: TimeInterval = 0.7
    public static let reducedDuration: TimeInterval = 0.3
    /// Control points of the easing curve (quick start, long soft landing).
    public static let curveX1 = 0.22
    public static let curveY1 = 1.0
    public static let curveX2 = 0.36
    public static let curveY2 = 1.0

    /// The surface shrinks to `minScale` between these fractions of the duration.
    public static let contractStart = 0.14
    public static let contractEnd = 0.64
    public static let minScale = 0.36
    /// The surface slides toward the display edge between these fractions.
    public static let travelStart = 0.43
    public static let travelEnd = 0.86
    /// How far toward the edge the center travels (1 = exactly to the edge).
    public static let travelFraction = 0.85
    /// External side: the surface slides in and grows between these fractions.
    public static let arriveTravelStart = 0.45
    public static let arriveTravelEnd = 0.9
    public static let arriveGrowStart = 0.5
    public static let arriveGrowEnd = 1.0

    public static let startCornerRadius = 14.0
    public static let endCornerRadius = 28.0
    /// Path keyframes sampled across one animation (about 60 per second at the full duration).
    public static let sampleCount = 42
}

/// One frame of the "display surface": the hole through which the real desktop is visible.
public struct SurfaceFrame: Equatable {
    public var rect: CGRect
    public var cornerRadius: CGFloat

    public init(rect: CGRect, cornerRadius: CGFloat) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

public enum TransitionGeometry {
    /// Unit vector from the built-in display's center to the external display's center (Core
    /// Graphics coordinates). `nil` when the centers coincide.
    public static func direction(from builtIn: CGRect, to external: CGRect) -> CGVector? {
        let dx = Double(external.midX - builtIn.midX)
        let dy = Double(external.midY - builtIn.midY)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return nil }
        return CGVector(dx: dx / length, dy: dy / length)
    }

    /// Core Graphics' y axis points down and AppKit/Core Animation's points up.
    public static func appKitVector(fromCG vector: CGVector) -> CGVector {
        CGVector(dx: vector.dx, dy: -vector.dy)
    }

    /// How far a point at the center of `size` travels along `vector` before reaching the edge.
    public static func edgeDistance(in size: CGSize, along vector: CGVector) -> Double {
        let vx = abs(Double(vector.dx))
        let vy = abs(Double(vector.dy))
        guard vx > 1e-6 || vy > 1e-6 else { return 0 }
        let tx = vx > 1e-6 ? Double(size.width) / 2 / vx : Double.greatestFiniteMagnitude
        let ty = vy > 1e-6 ? Double(size.height) / 2 / vy : Double.greatestFiniteMagnitude
        return min(tx, ty)
    }

    /// Picks the display the surface travels to. Deterministic: newly added displays win, then the
    /// nearest to the built-in display, then the lowest ID.
    public static func selectDestination(
        usable: Set<CGDirectDisplayID>,
        recentlyAdded: Set<CGDirectDisplayID>,
        builtInBounds: CGRect,
        boundsOf: (CGDirectDisplayID) -> CGRect
    ) -> CGDirectDisplayID? {
        let added = usable.intersection(recentlyAdded)
        let pool = added.isEmpty ? usable : added
        let candidates = pool
            .map { (id: $0, bounds: boundsOf($0)) }
            .filter { !$0.bounds.isEmpty && !$0.bounds.isNull }
        func distance(_ bounds: CGRect) -> Double {
            let dx = Double(bounds.midX - builtInBounds.midX)
            let dy = Double(bounds.midY - builtInBounds.midY)
            return dx * dx + dy * dy
        }
        return candidates.min { lhs, rhs in
            let (left, right) = (distance(lhs.bounds), distance(rhs.bounds))
            return left != right ? left < right : lhs.id < rhs.id
        }?.id
    }
}

public enum TransitionTimeline {
    /// The easing curve, evaluated from `TransitionTuning`'s control points. 0 -> 0 and 1 -> 1.
    public static func ease(_ input: Double) -> Double {
        let target = min(max(input, 0), 1)
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if bezier(mid, TransitionTuning.curveX1, TransitionTuning.curveX2) < target { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, TransitionTuning.curveY1, TransitionTuning.curveY2)
    }

    /// Maps `time` to 0...1 across `start...end`.
    public static func window(_ time: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return time >= end ? 1 : 0 }
        return min(max((time - start) / (end - start), 0), 1)
    }

    /// The built-in side: the surface contracts, then slides toward `vector` (AppKit coordinates)
    /// and out past the edge.
    public static func builtInSurface(at time: Double, in bounds: CGRect, vector: CGVector) -> SurfaceFrame {
        let contract = ease(window(time, TransitionTuning.contractStart, TransitionTuning.contractEnd))
        let travel = ease(window(time, TransitionTuning.travelStart, TransitionTuning.travelEnd))
        let scale = 1 + (TransitionTuning.minScale - 1) * contract
        let radius = lerp(
            TransitionTuning.startCornerRadius, TransitionTuning.endCornerRadius,
            ease(window(time, 0, TransitionTuning.contractEnd))
        )
        let reach = TransitionGeometry.edgeDistance(in: bounds.size, along: vector) * TransitionTuning.travelFraction
        let center = CGPoint(
            x: Double(bounds.midX) + Double(vector.dx) * reach * travel,
            y: Double(bounds.midY) + Double(vector.dy) * reach * travel
        )
        return surface(center: center, size: bounds.size, scale: scale, radius: radius)
    }

    /// The external side: the surface comes in from the edge facing the built-in display (opposite
    /// of `vector`, AppKit coordinates), slides to the center and grows to fill the display.
    public static func externalSurface(at time: Double, in bounds: CGRect, vector: CGVector) -> SurfaceFrame {
        let travel = ease(window(time, TransitionTuning.arriveTravelStart, TransitionTuning.arriveTravelEnd))
        let grow = ease(window(time, TransitionTuning.arriveGrowStart, TransitionTuning.arriveGrowEnd))
        let scale = lerp(TransitionTuning.minScale, 1, grow)
        let radius = lerp(TransitionTuning.endCornerRadius, TransitionTuning.startCornerRadius, grow)
        let reach = TransitionGeometry.edgeDistance(in: bounds.size, along: vector) * TransitionTuning.travelFraction
        let remaining = 1 - travel
        let center = CGPoint(
            x: Double(bounds.midX) - Double(vector.dx) * reach * remaining,
            y: Double(bounds.midY) - Double(vector.dy) * reach * remaining
        )
        return surface(center: center, size: bounds.size, scale: scale, radius: radius)
    }

    /// `count + 1` evenly spaced frames from time 0 to 1.
    public static func samples(count: Int, _ frame: (Double) -> SurfaceFrame) -> [SurfaceFrame] {
        let steps = max(count, 1)
        return (0...steps).map { frame(Double($0) / Double(steps)) }
    }

    private static func lerp(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from + (to - from) * amount
    }

    private static func surface(center: CGPoint, size: CGSize, scale: Double, radius: Double) -> SurfaceFrame {
        let width = Double(size.width) * scale
        let height = Double(size.height) * scale
        let rect = CGRect(x: Double(center.x) - width / 2, y: Double(center.y) - height / 2, width: width, height: height)
        return SurfaceFrame(rect: rect, cornerRadius: CGFloat(min(radius, min(width, height) / 2)))
    }
}
