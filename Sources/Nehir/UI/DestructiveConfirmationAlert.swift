import AppKit

@MainActor
enum DestructiveConfirmationAlert {
    static func confirmRestart(
        title: String,
        message: String,
        confirmTitle: String
    ) -> (confirmed: Bool, enableTracing: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message

        let traceCheckbox = NSButton(frame: NSRect(x: 0, y: -4, width: 200, height: 18))
        traceCheckbox.setButtonType(.switch)
        traceCheckbox.title = "Enable Tracing"
        alert.accessoryView = traceCheckbox

        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        return (confirmed, traceCheckbox.state == .on)
    }

    static func confirm(
        title: String,
        message: String,
        confirmTitle: String
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
