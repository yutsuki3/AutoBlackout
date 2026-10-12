import AppKit

/// Shows a HUD with the auto-OFF countdown and a "Keep It On" button on every screen, so a user who
/// just plugged in a monitor sees what's about to happen and can stop it without opening the menu.
///
/// The built-in panel is still on during the countdown, so it gets a HUD too.
final class AutoOffCountdownOverlayController {
    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the click even while the HUD isn't key, so a single click is enough.
    private final class FirstClickButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// Called when the user clicks "Keep It On".
    var onCancel: (() -> Void)?

    private var windows: [OverlayPanel] = []
    private var labels: [NSTextField] = []
    private var screenIDs: Set<CGDirectDisplayID> = []

    /// Shows the remaining time while `deadline` is set, hides otherwise. Safe to call repeatedly.
    func update(deadline: Date?) {
        guard let deadline else {
            hide()
            return
        }
        let screens = NSScreen.screens
        let ids = Set(screens.map(Self.screenID))
        if ids != screenIDs {
            hide()
            screenIDs = ids
            (windows, labels) = makeOverlays(on: screens)
        }
        let seconds = max(1, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        let message = String(format: L("The built-in display turns off in %d s"), seconds)
        labels.forEach { $0.stringValue = message }
    }

    private func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        labels = []
        screenIDs = []
    }

    @objc private func cancelClicked() {
        hide()
        onCancel?()
    }

    private static func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    private func makeOverlays(on screens: [NSScreen]) -> ([OverlayPanel], [NSTextField]) {
        var windows: [OverlayPanel] = []
        var labels: [NSTextField] = []
        for screen in screens {
            let (window, label) = makeOverlay(on: screen)
            window.orderFrontRegardless()
            windows.append(window)
            labels.append(label)
        }
        return (windows, labels)
    }

    /// A rounded, translucent panel in the upper middle of the screen, styled like the restore HUD.
    /// Non-activating, so clicking it never pulls focus away from the app the user is working in.
    private func makeOverlay(on screen: NSScreen) -> (OverlayPanel, NSTextField) {
        let size = NSSize(width: 300, height: 150)
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 2 / 3 - size.height / 2)
        let window = OverlayPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "laptopcomputer.slash",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        icon.contentTintColor = .labelColor

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.alignment = .center

        let button = FirstClickButton(title: L("Keep It On"), target: self, action: #selector(cancelClicked))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\u{1b}" // Esc, when the HUD happens to be key

        let stack = NSStackView(views: [icon, label, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
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
