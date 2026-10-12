import AppKit

/// The modal alerts of the menu bar app. Callers pass already-localized strings, so every `L("…")`
/// key stays a string literal at its call site (which `LocalizationTests` relies on).
enum Alerts {
    /// Shows the alert and returns which button was pressed. With no `buttons`, AppKit supplies its
    /// single default "OK" button. `style` defaults to AppKit's own default, `.warning`.
    @discardableResult
    static func present(
        title: String,
        message: String,
        style: NSAlert.Style = .warning,
        buttons: [String] = []
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
