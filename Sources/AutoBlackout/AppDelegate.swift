import AppKit
import AutoBlackoutCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = FileEventLogger()
    private lazy var controller = BlackoutController(
        system: LiveDisplaySystem(),
        store: UserDefaultsStateStore(),
        scheduler: MainQueueScheduler(),
        logger: logger
    )
    private let monitor = DisplayMonitor()
    private let restoreOverlay = RestoreOverlayController()
    private var recoveryTimer: Timer?
    private var terminationTimer: Timer?

    /// How long to wait for the restore before quitting. On the M3, the enable request doesn't
    /// succeed on the first try and, with a power cycle in between, can take 10+ seconds.
    private static let terminationRestoreTimeout: TimeInterval = 60

    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var restoreItem: NSMenuItem!
    private var autoModeItem: NSMenuItem!
    private var loginItemItem: NSMenuItem!
    private var statusLabelItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "laptopcomputer",
            accessibilityDescription: "AutoBlackout"
        )

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        statusLabelItem = NSMenuItem(title: "Built-in display: ON", action: nil, keyEquivalent: "")
        statusLabelItem.isEnabled = false
        menu.addItem(statusLabelItem)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Turn built-in display OFF",
            action: #selector(toggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Always clickable regardless of the current status: sends an enable request no matter what.
        restoreItem = NSMenuItem(
            title: "Force-restore built-in display",
            action: #selector(forceRestore),
            keyEquivalent: ""
        )
        restoreItem.target = self
        menu.addItem(restoreItem)

        autoModeItem = NSMenuItem(
            title: "Auto-OFF on external monitor connect",
            action: #selector(toggleAutoMode),
            keyEquivalent: ""
        )
        autoModeItem.target = self
        autoModeItem.state = .on
        menu.addItem(autoModeItem)
        if !controller.isDisableSupported {
            controller.isAutoModeEnabled = false
            autoModeItem.state = .off
            autoModeItem.isEnabled = false
        }

        loginItemItem = NSMenuItem(
            title: "Launch at login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItemItem.target = self
        menu.addItem(loginItemItem)
        updateLoginItemState()

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About AutoBlackout", action: #selector(showAbout), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: "Show Logs", action: #selector(openLogs), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        controller.onStateChange = { [weak self] in self?.refresh() }

        monitor.onChange = { [weak self] displayID, flags in
            self?.controller.evaluate(reason: "callback id=\(displayID) flags=0x\(String(flags.rawValue, radix: 16))")
        }
        monitor.start()

        // Right after opening the lid or waking from sleep, the panel has just been re-powered, so
        // evaluate immediately instead of waiting for the next poll.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.controller.evaluate(reason: note.name.rawValue)
            }
        }

        logger.log("host: " + HostInfo.summary)

        // Self-heal at launch (e.g. a previous process crashed while the display was disabled).
        controller.launch()

        // A safety net for callbacks that never arrive, arrive late, or arrive out of order:
        // re-evaluate and correct every second.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.controller.evaluate(reason: "poll")
        }
        RunLoop.main.add(timer, forMode: .common)
        recoveryTimer = timer

        refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.managedDisplay != nil || controller.restorePending else {
            // Don't rely on `.forAppOnly`'s automatic restore; restore explicitly before quitting.
            controller.prepareForTermination()
            return .terminateNow
        }

        // Quitting while the built-in display is off would leave nothing around to restore it.
        // Run the restore procedure to completion and confirm it worked before quitting; cancel the
        // quit if it doesn't come back.
        logger.log("terminate: restoring panel before quitting")
        controller.isAutoModeEnabled = false
        controller.requestRestore(trigger: "terminate")
        let deadline = Date().addingTimeInterval(Self.terminationRestoreTimeout)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return }
            if !self.controller.restorePending, self.controller.managedDisplay == nil, !self.controller.isRepairing {
                timer.invalidate()
                self.logger.log("terminate: panel restored; quitting")
                NSApp.reply(toApplicationShouldTerminate: true)
            } else if Date() > deadline {
                timer.invalidate()
                self.logger.log("terminate: panel not restored within \(Int(Self.terminationRestoreTimeout))s; quit cancelled")
                self.controller.isAutoModeEnabled = self.autoModeItem.state == .on
                NSApp.reply(toApplicationShouldTerminate: false)
                self.showQuitCancelledAlert()
            }
        }
        // Keep running in the common run loop mode, since terminateLater otherwise only pumps modal
        // panel modes.
        RunLoop.main.add(timer, forMode: .common)
        terminationTimer = timer
        return .terminateLater
    }

    private func showQuitCancelledAlert() {
        let alert = NSAlert()
        alert.messageText = "Couldn't restore the built-in display, so quitting was cancelled"
        alert.informativeText = "Still retrying in the background. Closing the lid and reopening it "
            + "after a few seconds sometimes brings it back."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        recoveryTimer?.invalidate()
        monitor.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        updateLoginItemState()
    }

    @objc private func toggle() {
        controller.toggleManually()
    }

    @objc private func forceRestore() {
        controller.requestRestore(trigger: "menu force-restore")
    }

    @objc private func toggleAutoMode() {
        controller.isAutoModeEnabled.toggle()
        autoModeItem.state = controller.isAutoModeEnabled ? .on : .off
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(FileEventLogger.directory)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logger.log("login item toggle failed: \(error.localizedDescription)")
        }
        updateLoginItemState()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "A menu bar app that turns off the built-in display when an external "
                    + "display is connected.\nUses a private API, so it can't be distributed through the Mac "
                    + "App Store. MIT License.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            ),
        ])
    }

    private func updateLoginItemState() {
        loginItemItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func refresh() {
        let status = controller.panelStatus
        switch status {
        case .apiUnavailable:
            statusLabelItem.title = "Private API unavailable on this macOS version"
        case .notFound:
            statusLabelItem.title = "Built-in display not found"
        case .on:
            statusLabelItem.title = "Built-in display: ON"
        case .off:
            statusLabelItem.title = "Built-in display: OFF"
        case .restoring:
            statusLabelItem.title = controller.needsLidCycle
                ? "Built-in display: waiting to restore — close the lid, then open it"
                : "Built-in display: restoring…"
        }
        let isOff = status == .off || status == .restoring
        toggleItem.title = isOff ? "Turn built-in display back ON" : "Turn built-in display OFF"
        toggleItem.isEnabled = status != .apiUnavailable && status != .notFound
            && !controller.isChanging
            && (isOff || (controller.isDisableSupported && controller.hasUsableExternalDisplay))
        if !isOff, !controller.isDisableSupported {
            toggleItem.title = "OFF is disabled (restore not verified on this Mac — see README)"
        }
        restoreItem.isEnabled = status != .apiUnavailable && status != .notFound

        restoreOverlay.update(
            isRestoring: status == .restoring,
            needsLidCycle: controller.needsLidCycle,
            builtInDisplayID: controller.builtInPanelID()
        )
    }
}

private extension NSMenuItem {
    func withTarget(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
