import AppKit
import AutoBlackoutCore
import CoreGraphics
import QuartzCore

/// Draws the display-transfer animation with plain AppKit windows and Core Animation layers. No
/// screen capture: the real desktop stays visible through a moving "hole" in a dark mask, which
/// reads as the screen shrinking and sliding toward the external display.
///
/// Exists only while a transition runs; `dismiss()` removes every window and layer.
final class TransitionOverlayController: TransitionPresenter {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var windows: [OverlayWindow] = []

    func present(_ plan: TransitionPlan) -> TransitionPresentResult {
        dismiss()
        guard let builtInScreen = Self.screen(for: plan.builtIn) else { return .failed }
        let vector = TransitionGeometry.appKitVector(fromCG: plan.vector)

        switch plan.motion {
        case .reduced:
            windows = [makeFadeWindow(on: builtInScreen, duration: plan.duration)]
        case .full:
            guard let destinationScreen = Self.screen(for: plan.destination) else { return .destinationNotReady }
            windows = [
                makeBuiltInWindow(on: builtInScreen, vector: vector, duration: plan.duration),
                makeExternalWindow(on: destinationScreen, vector: vector, duration: plan.duration),
            ]
        }
        windows.forEach { $0.orderFrontRegardless() }
        return .started
    }

    func dismiss() {
        for window in windows {
            window.orderOut(nil)
            window.contentView?.layer?.sublayers = nil
            window.contentView = nil
        }
        windows = []
    }

    // MARK: - Windows

    /// Reduce Motion: the built-in display just fades to black.
    private func makeFadeWindow(on screen: NSScreen, duration: TimeInterval) -> OverlayWindow {
        let (window, root) = Self.makeWindow(on: screen)
        let veil = Self.makeVeil(bounds: Self.localBounds(of: screen))
        root.addSublayer(veil)
        veil.add(Self.opacityAnimation(values: [0, 1], keyTimes: [0, 1], duration: duration), forKey: "opacity")
        return window
    }

    private func makeBuiltInWindow(on screen: NSScreen, vector: CGVector, duration: TimeInterval) -> OverlayWindow {
        let (window, root) = Self.makeWindow(on: screen)
        let bounds = Self.localBounds(of: screen)
        let frames = TransitionTimeline.samples(count: TransitionTuning.sampleCount) {
            TransitionTimeline.builtInSurface(at: $0, in: bounds, vector: vector)
        }
        let (dim, glow) = Self.makeSurfaceLayers(bounds: bounds, frames: frames, duration: duration)
        let veil = Self.makeVeil(bounds: bounds)
        root.addSublayer(dim)
        root.addSublayer(glow)
        root.addSublayer(veil)

        let contractEnd = TransitionTuning.contractEnd
        glow.add(
            Self.opacityAnimation(values: [1, 1, 0], keyTimes: [0, contractEnd, 0.9], duration: duration),
            forKey: "opacity"
        )
        // The surface is fully gone, and the screen fully black, by the end.
        veil.add(
            Self.opacityAnimation(values: [0, 0, 1], keyTimes: [0, contractEnd, 1], duration: duration),
            forKey: "opacity"
        )
        return window
    }

    private func makeExternalWindow(on screen: NSScreen, vector: CGVector, duration: TimeInterval) -> OverlayWindow {
        let (window, root) = Self.makeWindow(on: screen)
        let bounds = Self.localBounds(of: screen)
        let frames = TransitionTimeline.samples(count: TransitionTuning.sampleCount) {
            TransitionTimeline.externalSurface(at: $0, in: bounds, vector: vector)
        }
        let (dim, glow) = Self.makeSurfaceLayers(bounds: bounds, frames: frames, duration: duration)
        dim.opacity = 0
        glow.opacity = 0
        root.addSublayer(dim)
        root.addSublayer(glow)

        // The dark mask fades in around the incoming surface, then fades out once it fills the screen.
        let keyTimes = [0, 0.25, 0.85, 1.0]
        dim.add(Self.opacityAnimation(values: [0, 1, 1, 0], keyTimes: keyTimes, duration: duration), forKey: "opacity")
        glow.add(Self.opacityAnimation(values: [0, 1, 1, 0], keyTimes: keyTimes, duration: duration), forKey: "opacity")
        return window
    }

    private static func makeWindow(on screen: NSScreen) -> (OverlayWindow, CALayer) {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // `.statusBar` is above the menu bar and the Dock but below screen savers.
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        return (window, view.layer ?? CALayer())
    }

    // MARK: - Layers

    /// A dark mask with a rounded hole (even-odd fill) plus a faint glowing edge around the hole.
    /// Both layers animate along the same sampled path keyframes.
    private static func makeSurfaceLayers(
        bounds: CGRect,
        frames: [SurfaceFrame],
        duration: TimeInterval
    ) -> (dim: CAShapeLayer, glow: CAShapeLayer) {
        let dim = CAShapeLayer()
        dim.frame = bounds
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.cgColor

        let glow = CAShapeLayer()
        glow.frame = bounds
        glow.fillColor = nil
        glow.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        glow.lineWidth = 1.5
        glow.shadowColor = NSColor.white.cgColor
        glow.shadowOpacity = 0.5
        glow.shadowRadius = 10
        glow.shadowOffset = .zero

        let holes = frames.map(holePath)
        let masks = holes.map { hole -> CGPath in
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addPath(hole)
            return path
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.path = masks.first
        glow.path = holes.first
        CATransaction.commit()
        dim.add(pathAnimation(masks, duration: duration), forKey: "path")
        glow.add(pathAnimation(holes, duration: duration), forKey: "path")
        return (dim, glow)
    }

    private static func makeVeil(bounds: CGRect) -> CALayer {
        let veil = CALayer()
        veil.frame = bounds
        veil.backgroundColor = NSColor.black.cgColor
        veil.opacity = 0
        return veil
    }

    private static func holePath(_ frame: SurfaceFrame) -> CGPath {
        CGPath(roundedRect: frame.rect, cornerWidth: frame.cornerRadius, cornerHeight: frame.cornerRadius, transform: nil)
    }

    private static func pathAnimation(_ paths: [CGPath], duration: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = paths
        animation.calculationMode = .linear // the easing is already baked into the samples
        animation.duration = duration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    private static func opacityAnimation(values: [Float], keyTimes: [Double], duration: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values.map { NSNumber(value: $0) }
        animation.keyTimes = keyTimes.map { NSNumber(value: $0) }
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: max(values.count - 1, 1)
        )
        animation.duration = duration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    // MARK: - Screens

    /// The screen in window-local coordinates (origin at its lower-left corner).
    private static func localBounds(of screen: NSScreen) -> CGRect {
        CGRect(origin: .zero, size: screen.frame.size)
    }

    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
    }
}
