import AppKit
import CoreGraphics

/// 復帰待ち中に、接続されている画面へスピナー付きのHUDを出す。
///
/// 内蔵パネルは無効化されている間は物理的に何も表示できないため、これは主に
/// 外部ディスプレイが繋がったままのケース（手動での「強制的に復元」など）向け。
/// 外部を全部抜いてから内蔵が実際に点灯するまでの数秒間は、画面自体が1枚も
/// 無い状態になるため、その間は何も表示できない（`NSScreen.screens` が空になり、
/// 何もしないだけで安全に無視される）。
final class RestoreOverlayController {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static let restoringText = "内蔵ディスプレイを起動中…"
    private static let lidCycleText = "内蔵ディスプレイが復帰しません\n蓋を閉じて数秒後に開いてください"

    private var windows: [OverlayWindow] = []
    private var labels: [NSTextField] = []
    private var isVisible = false
    private var showingLidMessage = false

    /// 呼ぶたびに現在の状態に合わせて表示/非表示・文言を更新する。何度呼んでも安全。
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

    /// 復帰待ちの間に画面構成が変わることがある（外部がつながり直す、内蔵が瞬間的に見えるようになる等）。
    /// 出す先の画面が増減していたら作り直す。
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

    /// macOSの音量/明るさHUDに似せた、角丸の半透明パネルを画面中央に出す。
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
