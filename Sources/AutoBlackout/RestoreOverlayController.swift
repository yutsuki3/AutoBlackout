import AppKit
import CoreGraphics

/// Shows a HUD with a spinner on every connected screen while a restore is in progress.
///
/// The built-in panel itself can't show anything while it's disabled, so this is mainly for the
/// case where an external display stays connected (e.g. a manual "force restore"). For the few
/// seconds between unplugging every external display and the built-in panel actually lighting up,
/// there are zero screens to show anything on anyway (`NSScreen.screens` is empty, so this just does
/// nothing safely).
final class RestoreOverlayController {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static let restoringText = "Restoring the built-in display…"
    private static let lidCycleText = "The built-in display isn't coming back.\nClose the lid, wait a few seconds, then open it."

    private var windows: [OverlayWindow] = []
    private var labels: [NSTextField] = []
    private var isVisible = false
    private var showingLidMessage = false

    /// Updates visibility and text to match the current state on every call. Safe to call repeatedly.
    func update(isRestoring: Bool, needsLidCycle: Bool, builtInDisplayID: CGDirectDisplayID?) {
        guard isRestoring else {
            hide()
            return
        }
        if isVisible {
            refreshScreensIfNeeded(builtInDisplayID: builtInDisplayID)
            setMessage(needsLidCycle: needsLidCycle)
        } else {
            show(needsLidCycle: needsLidCycle, builtInDisplayID: builtInDisplayID)
        }
    }

    private func show(needsLidCycle: Bool, builtInDisplayID: CGDirectDisplayID?) {
        let screens = Self.targetScreens(excluding: builtInDisplayID)
        guard !screens.isEmpty else { return }

        isVisible = true
        showingLidMessage = needsLidCycle
        (windows, labels) = Self.makeOverlays(on: screens, text: text(for: needsLidCycle))
    }

    /// The screen configuration can change while waiting for a restore (an external display
    /// reconnecting, the built-in panel briefly becoming visible, etc.). Rebuild the overlays if the
    /// set of target screens changed.
    private func refreshScreensIfNeeded(builtInDisplayID: CGDirectDisplayID?) {
        let screens = Self.targetScreens(excluding: builtInDisplayID)
        let currentIDs = Set(windows.compactMap(\.screen).map(Self.screenID))
        let targetIDs = Set(screens.map(Self.screenID))
        guard currentIDs != targetIDs else { return }
        windows.forEach { $0.orderOut(nil) }
        guard !screens.isEmpty else {
            windows = []
            labels = []
            return
        }
        (windows, labels) = Self.makeOverlays(on: screens, text: text(for: showingLidMessage))
    }

    private func setMessage(needsLidCycle: Bool) {
        guard needsLidCycle != showingLidMessage else { return }
        showingLidMessage = needsLidCycle
        let message = text(for: needsLidCycle)
        labels.forEach { $0.stringValue = message }
    }

    private func hide() {
        guard isVisible else { return }
        isVisible = false
        windows.forEach { $0.orderOut(nil) }
        windows = []
        labels = []
    }

    private func text(for needsLidCycle: Bool) -> String {
        needsLidCycle ? Self.lidCycleText : Self.restoringText
    }

    private static func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    private static func targetScreens(excluding builtInDisplayID: CGDirectDisplayID?) -> [NSScreen] {
        NSScreen.screens.filter { screen in
            guard let builtInDisplayID else { return true }
            return screenID(screen) != builtInDisplayID
        }
    }

    private static func makeOverlays(on screens: [NSScreen], text: String) -> ([OverlayWindow], [NSTextField]) {
        var windows: [OverlayWindow] = []
        var labels: [NSTextField] = []
        for screen in screens {
            let (window, label) = makeOverlay(on: screen)
            label.stringValue = text
            window.orderFrontRegardless()
            windows.append(window)
            labels.append(label)
        }
        return (windows, labels)
    }

    /// A rounded, translucent panel centered on screen, styled after macOS's volume/brightness HUD.
    private static func makeOverlay(on screen: NSScreen) -> (OverlayWindow, NSTextField) {
        let size = NSSize(width: 220, height: 220)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        let window = OverlayWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 48).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 48).isActive = true
        spinner.startAnimation(nil)

        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: background.widthAnchor, constant: -32),
        ])

        window.contentView = background
        return (window, label)
    }
}
