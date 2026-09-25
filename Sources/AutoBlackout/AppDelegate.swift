import AppKit
import AutoBlackoutCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = FileEventLogger()
    // Held directly (not just inside `controller`) so the "Verify this Mac" flow can flip
    // `allowsDisableForVerification` on the one `LiveDisplaySystem` the app actually uses, instead of
    // standing up a second display system + controller pair against the same state store.
    private let displaySystem = LiveDisplaySystem()
    private let stateStore = UserDefaultsStateStore()
    private lazy var controller = BlackoutController(
        system: displaySystem,
        store: stateStore,
        scheduler: MainQueueScheduler(),
        logger: logger
    )
    private lazy var hostVerifier = InAppHostVerifier(
        controller: controller,
        system: displaySystem,
        store: stateStore,
        logger: logger
    )
    private let monitor = DisplayMonitor()
    private let restoreOverlay = RestoreOverlayController()
    private var recoveryTimer: Timer?
    private var terminationTimer: Timer?
    /// Set while `hostVerifier` is in its "disabling" or "holding" phase, so `refresh()` can show
    /// progress text instead of the plain panel status. `nil` once it reaches "restoring" — from then
    /// on the normal restoring UI (status text + HUD) already says the same thing.
    private var verifyProgressPhase: InAppHostVerifier.Phase?

    /// How long to wait for the restore before quitting. On the M3, the enable request doesn't
    /// succeed on the first try and, with a power cycle in between, can take 10+ seconds.
    private static let terminationRestoreTimeout: TimeInterval = 60

    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var restoreItem: NSMenuItem!
    private var autoModeItem: NSMenuItem!
    private var loginItemItem: NSMenuItem!
    private var statusLabelItem: NSMenuItem!
    private var verifyItem: NSMenuItem!

    private static let verificationDocsURL = URL(
        string: "https://github.com/yutsuki3/AutoBlackout/blob/main/docs/HOST_VERIFICATION.md#verifying-the-restore-procedure-on-your-mac"
    )!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "laptopcomputer",
            accessibilityDescription: "AutoBlackout"
        )

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        statusLabelItem = NSMenuItem(title: L("Built-in display: ON"), action: nil, keyEquivalent: "")
        statusLabelItem.isEnabled = false
        menu.addItem(statusLabelItem)

        // Shown whenever this Mac model + macOS build isn't verified to restore the display
        // correctly (never verified, or a macOS update invalidated an earlier verification).
        verifyItem = NSMenuItem(
            title: L("Verify this Mac to enable OFF…"),
            action: #selector(verifyThisMac),
            keyEquivalent: ""
        )
        verifyItem.target = self
        verifyItem.isHidden = true
        menu.addItem(verifyItem)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: L("Turn built-in display OFF"),
            action: #selector(toggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Always clickable regardless of the current status: sends an enable request no matter what.
        restoreItem = NSMenuItem(
            title: L("Force-restore built-in display"),
            action: #selector(forceRestore),
            keyEquivalent: ""
        )
        restoreItem.target = self
        menu.addItem(restoreItem)

        autoModeItem = NSMenuItem(
            title: L("Auto-OFF on external monitor connect"),
            action: #selector(toggleAutoMode),
            keyEquivalent: ""
        )
        autoModeItem.target = self
        autoModeItem.state = .on
        menu.addItem(autoModeItem)
        if !controller.isDisableSupported {
            if let notice = HostVerification.reverificationNotice {
                logger.log("re-verification needed: \(notice); use \"Verify this Mac\" in the menu, or "
                    + "run --verify-restore --confirm-reboot-risk")
            }
            controller.isAutoModeEnabled = false
            autoModeItem.state = .off
            autoModeItem.isEnabled = false
        }

        loginItemItem = NSMenuItem(
            title: L("Launch at login"),
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItemItem.target = self
        menu.addItem(loginItemItem)
        updateLoginItemState()

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("About AutoBlackout"), action: #selector(showAbout), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: L("Show Logs"), action: #selector(openLogs), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        controller.onStateChange = { [weak self] in self?.refresh() }
        hostVerifier.onPhaseChange = { [weak self] phase in self?.handleVerifyPhaseChange(phase) }

        monitor.onChange = { [weak self] displayID, flags in
            self?.controller.evaluate(reason: "callback id=\(displayID) flags=0x\(String(flags.rawValue, radix: 16))")
        }
        monitor.start()

        // Right after opening the lid or waking from sleep, the panel has just been re-powered, so
        // evaluate immediately instead of waiting for the next poll. Sleep and wake are also
        // reported to the controller: a system sleep/wake drops the external display out of the
        // online list, and its return must not be mistaken for a new connection (auto-OFF).
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.controller.handlePowerEvent(note.name.rawValue, transition: .sleep)
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.controller.handlePowerEvent(note.name.rawValue, transition: .wake)
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
        alert.messageText = L("Couldn't restore the built-in display, so quitting was cancelled")
        // swiftlint:disable:next line_length
        alert.informativeText = L("Still retrying in the background. Closing the lid and reopening it after a few seconds sometimes brings it back.")
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

    @objc private func verifyThisMac() {
        guard !hostVerifier.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = L("Verify this Mac?")
        // swiftlint:disable:next line_length
        alert.informativeText = L("This disables the built-in display once to test whether it comes back on its own. If it doesn't, a reboot will be required.\n\nBefore continuing: connect an external display, keep the lid open, and stay to watch it.\n\nOn success, this Mac model and macOS build are remembered as verified, and the OFF feature becomes available.")
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Verify Now"))
        alert.addButton(withTitle: L("Learn More…"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            beginVerification()
        case .alertThirdButtonReturn:
            openVerificationDocs()
        default:
            break
        }
    }

    private func beginVerification() {
        switch hostVerifier.start() {
        case .started:
            refresh()
        case .busy:
            showBusyAlert()
        case .blocked(let problems):
            showBlockedAlert(problems)
        }
    }

    private func showBusyAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Can't verify yet")
        // swiftlint:disable:next line_length
        alert.informativeText = L("AutoBlackout is already changing the built-in display's state. Wait a moment and try again.")
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func handleVerifyPhaseChange(_ phase: InAppHostVerifier.Phase) {
        switch phase {
        case .disabling:
            verifyProgressPhase = .disabling
        case .holding:
            verifyProgressPhase = .holding
        case .restoring:
            // The normal restoring status text + HUD (driven by `controller.panelStatus`) already
            // say the same thing from here on.
            verifyProgressPhase = nil
        case .succeeded:
            verifyProgressPhase = nil
            controller.isAutoModeEnabled = true
            autoModeItem.state = .on
        case .failed:
            verifyProgressPhase = nil
        }
        refresh()
        switch phase {
        case .succeeded: showVerifySucceededAlert()
        case .failed(let reason): showVerifyFailedAlert(reason: reason)
        default: break
        }
    }

    private func showBlockedAlert(_ problems: [RestoreVerificationProblem]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Can't verify yet")
        alert.informativeText = problems.map { "• " + $0.localizedDescription }.joined(separator: "\n")
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showVerifySucceededAlert() {
        let alert = NSAlert()
        alert.messageText = L("This Mac is now verified")
        // swiftlint:disable:next line_length
        alert.informativeText = L("The OFF feature is now available, and “Auto-OFF on external monitor connect” has been turned on.")
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showVerifyFailedAlert(reason: InAppHostVerifier.FailureReason) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch reason {
        case .didNotDisable:
            alert.messageText = L("Verification didn't run")
            // swiftlint:disable:next line_length
            alert.informativeText = L("The built-in display didn't turn off, so nothing was changed. Check “Show Logs” for details.")
        case .timedOut:
            alert.messageText = L("Verification didn't finish")
            // swiftlint:disable:next line_length
            alert.informativeText = L("The built-in display hasn't come back yet. AutoBlackout keeps retrying in the background — try closing the lid, waiting a few seconds, then opening it. This Mac stays unverified until the restore succeeds.")
        }
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openVerificationDocs() {
        NSWorkspace.shared.open(Self.verificationDocsURL)
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
                // swiftlint:disable:next line_length
                string: L("A menu bar app that turns off the built-in display when an external display is connected.\nUses a private API, so it can't be distributed through the Mac App Store. MIT License."),
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            ),
        ])
    }

    private func updateLoginItemState() {
        loginItemItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func refresh() {
        let status = controller.panelStatus
        let isVerifying = hostVerifier.isRunning
        if let progress = verifyProgressPhase {
            statusLabelItem.title = verifyStatusText(for: progress)
        } else {
            switch status {
            case .apiUnavailable:
                statusLabelItem.title = L("Private API unavailable on this macOS version")
            case .notFound:
                statusLabelItem.title = L("Built-in display not found")
            case .on:
                statusLabelItem.title = L("Built-in display: ON")
            case .off:
                statusLabelItem.title = L("Built-in display: OFF")
            case .restoring:
                statusLabelItem.title = controller.needsLidCycle
                    ? L("Built-in display: waiting to restore — close the lid, then open it")
                    : L("Built-in display: restoring…")
            }
        }
        let isOff = status == .off || status == .restoring
        toggleItem.title = isOff ? L("Turn built-in display back ON") : L("Turn built-in display OFF")
        toggleItem.isEnabled = !isVerifying && status != .apiUnavailable && status != .notFound
            && !controller.isChanging
            && (isOff || (controller.isDisableSupported && controller.hasUsableExternalDisplay))
        let reverificationNotice = HostVerification.reverificationNotice
        verifyItem.isHidden = controller.isDisableSupported || !HostInfo.isAppleSilicon
        verifyItem.title = reverificationNotice != nil
            ? L("macOS was updated — re-verify to enable OFF…")
            : L("Verify this Mac to enable OFF…")
        verifyItem.isEnabled = !isVerifying
        if !isOff, !controller.isDisableSupported {
            toggleItem.title = !HostInfo.isAppleSilicon
                ? L("OFF is disabled (Intel Macs are not supported)")
                : reverificationNotice != nil
                ? L("OFF is disabled (macOS was updated — restore needs re-verifying)")
                : L("OFF is disabled (restore not verified on this Mac — see “Verify this Mac” in this menu)")
        }
        restoreItem.isEnabled = !isVerifying && status != .apiUnavailable && status != .notFound
        autoModeItem.isEnabled = !isVerifying && controller.isDisableSupported

        restoreOverlay.update(
            isRestoring: status == .restoring,
            needsLidCycle: controller.needsLidCycle,
            builtInDisplayID: controller.builtInPanelID()
        )
    }

    private func verifyStatusText(for phase: InAppHostVerifier.Phase) -> String {
        switch phase {
        case .holding:
            return L("Verifying this Mac: restoring shortly…")
        default:
            return L("Verifying this Mac: turning built-in display off…")
        }
    }
}

private extension NSMenuItem {
    func withTarget(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
