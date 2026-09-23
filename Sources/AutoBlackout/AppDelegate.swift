import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = BlackoutController()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var autoModeItem: NSMenuItem!
    private var statusLabelItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "laptopcomputer",
            accessibilityDescription: "AutoBlackout"
        )

        let menu = NSMenu()

        statusLabelItem = NSMenuItem(title: "内蔵ディスプレイ: ON", action: nil, keyEquivalent: "")
        statusLabelItem.isEnabled = false
        menu.addItem(statusLabelItem)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "内蔵ディスプレイをOFFにする",
            action: #selector(toggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        autoModeItem = NSMenuItem(
            title: "外部モニター接続で自動OFF",
            action: #selector(toggleAutoMode),
            keyEquivalent: ""
        )
        autoModeItem.target = self
        autoModeItem.state = .on
        menu.addItem(autoModeItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        controller.onStateChange = { [weak self] in self?.refresh() }
        controller.start()
        refresh()
    }

    @objc private func toggle() {
        controller.toggleManually()
    }

    @objc private func toggleAutoMode() {
        controller.isAutoModeEnabled.toggle()
        autoModeItem.state = controller.isAutoModeEnabled ? .on : .off
    }

    private func refresh() {
        guard controller.isAPIAvailable else {
            statusLabelItem.title = "このmacOSでは非公開APIが利用できません"
            toggleItem.isEnabled = false
            return
        }
        statusLabelItem.title = controller.isBuiltInDisplayOff ? "内蔵ディスプレイ: OFF" : "内蔵ディスプレイ: ON"
        toggleItem.title = controller.isBuiltInDisplayOff ? "内蔵ディスプレイをONに戻す" : "内蔵ディスプレイをOFFにする"
    }
}
