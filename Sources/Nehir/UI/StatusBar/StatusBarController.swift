import AppKit

@MainActor
final class StatusBarController: NSObject {
    nonisolated static let mainAutosaveName = "NehirMenuBarItem"

    private var statusItem: NSStatusItem?
    private var menuBuilder: StatusBarMenuBuilder?
    private var menu: NSMenu?
    private var isRebuildingOwnedItems = false

    private let settings: SettingsStore
    private let cliManager: AppCLIManager?
    private let statusItemDefaults: UserDefaults
    private weak var controller: WMController?

    init(
        settings: SettingsStore,
        controller: WMController,
        cliManager: AppCLIManager? = nil,
        statusItemDefaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.cliManager = cliManager
        self.statusItemDefaults = statusItemDefaults
        self.controller = controller
        super.init()
    }

    func setup() {
        guard statusItem == nil else { return }
        installOwnedStatusItems()
    }

    static let maxStatusBarAppNameLength = 15

    private func installOwnedStatusItems() {
        guard statusItem == nil, let controller else { return }

        let ownedStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        ownedStatusItem.autosaveName = Self.mainAutosaveName
        statusItem = ownedStatusItem

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "o.circle", accessibilityDescription: "Nehir")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menuBuilder = StatusBarMenuBuilder(settings: settings, controller: controller)
        self.menuBuilder = menuBuilder
        rebuildMenu()

        refreshWorkspaces()
    }

    @objc private func handleClick(_: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            handleRightClick()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        rebuildMenu()
        guard let button = statusItem?.button, let menu else { return }
        // Anchor the menu at the button edge. Offsetting it below the status item
        // makes AppKit think the menu is partially outside the usable menu area on
        // some displays, so it initially draws the menu's scroll affordance until
        // the mouse moves over the menu.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    private func handleRightClick() {
        showMenu()
    }

    func refreshMenu() {
        menuBuilder?.updateToggles()
    }

    func rebuildMenu() {
        menu = menuBuilder?.buildMenu()
    }

    static func truncatedStatusBarAppName(_ appName: String) -> String {
        guard appName.count > maxStatusBarAppNameLength else { return appName }
        return String(appName.prefix(maxStatusBarAppNameLength)) + "\u{2026}"
    }

    static func statusButtonTitle(workspaceLabel: String, focusedAppName: String?) -> String {
        var title = " \(workspaceLabel)"
        if let focusedAppName, !focusedAppName.isEmpty {
            title += " \u{2013} \(truncatedStatusBarAppName(focusedAppName))"
        }
        return title
    }

    func refreshWorkspaces() {
        guard let button = statusItem?.button else { return }

        if button.image == nil {
            button.image = NSImage(systemSymbolName: "o.circle", accessibilityDescription: "Nehir")
            button.image?.isTemplate = true
        }

        guard settings.statusBarShowWorkspaceName,
              let summary = controller?.activeStatusBarWorkspaceSummary()
        else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }

        let workspaceLabel = settings.statusBarUseWorkspaceId ? summary.workspaceRawName : summary.workspaceLabel
        let focusedAppName = settings.statusBarShowAppNames ? summary.focusedAppName : nil
        button.title = Self.statusButtonTitle(workspaceLabel: workspaceLabel, focusedAppName: focusedAppName)
        button.imagePosition = .imageLeft
    }

    func statusButtonTitleForTests() -> String {
        statusItem?.button?.title ?? ""
    }

    func statusButtonImagePositionForTests() -> NSControl.ImagePosition? {
        statusItem?.button?.imagePosition
    }

    func statusItemAutosaveNameForTests() -> String? {
        statusItem?.autosaveName
    }

    func statusItemIsVisibleForTests() -> Bool? {
        statusItem?.isVisible
    }

    func rebuildOwnedStatusItemsAfterUnsafeOrderingForTests() {
        rebuildOwnedStatusItemsAfterUnsafeOrdering()
    }

    func cleanup() {
        cleanupOwnedStatusItems()
    }

    private func cleanupOwnedStatusItems() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        menuBuilder = nil
        menu = nil
    }

    private func rebuildOwnedStatusItemsAfterUnsafeOrdering() {
        guard !isRebuildingOwnedItems else { return }
        isRebuildingOwnedItems = true
        defer { isRebuildingOwnedItems = false }

        cleanupOwnedStatusItems()
        installOwnedStatusItems()
    }
}
