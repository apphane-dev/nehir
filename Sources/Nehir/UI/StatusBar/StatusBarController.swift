// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

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
    private static let statusBarIconSize = NSSize(width: 18, height: 18)

    private static func statusBarIcon() -> NSImage {
        let image = NSImage(size: statusBarIconSize, flipped: false) { rect in
            NSColor.black.setStroke()

            let mark = NSBezierPath()
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.lineWidth = 2.4

            mark.move(to: NSPoint(x: rect.minX + 3.3, y: rect.minY + 4.2))
            mark.curve(
                to: NSPoint(x: rect.minX + 6.4, y: rect.maxY - 4.1),
                controlPoint1: NSPoint(x: rect.minX + 3.6, y: rect.minY + 8.4),
                controlPoint2: NSPoint(x: rect.minX + 4.8, y: rect.maxY - 3.6)
            )
            mark.curve(
                to: NSPoint(x: rect.minX + 10.4, y: rect.minY + 5.2),
                controlPoint1: NSPoint(x: rect.minX + 7.9, y: rect.maxY - 4.6),
                controlPoint2: NSPoint(x: rect.minX + 8.5, y: rect.minY + 5.1)
            )
            mark.curve(
                to: NSPoint(x: rect.maxX - 4.0, y: rect.maxY - 4.0),
                controlPoint1: NSPoint(x: rect.minX + 12.2, y: rect.minY + 5.4),
                controlPoint2: NSPoint(x: rect.maxX - 5.4, y: rect.maxY - 4.0)
            )
            mark.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    private func installOwnedStatusItems() {
        guard statusItem == nil, let controller else { return }

        let ownedStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        ownedStatusItem.autosaveName = Self.mainAutosaveName
        statusItem = ownedStatusItem

        guard let button = statusItem?.button else { return }
        button.image = Self.statusBarIcon()
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
            button.image = Self.statusBarIcon()
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
