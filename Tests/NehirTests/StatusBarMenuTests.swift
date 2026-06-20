// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation
@testable import Nehir
import Testing

@Suite(.serialized) @MainActor struct StatusBarMenuTests {
    @Test func buildMenuUsesCurrentAppAppearanceForMenuAndViews() throws {
        let originalAppearanceProvider = StatusBarMenuAppearanceProvider.current
        defer { StatusBarMenuAppearanceProvider.current = originalAppearanceProvider }

        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)

        StatusBarMenuAppearanceProvider.current = { NSAppearance(named: .aqua) }
        let lightMenu = builder.buildMenu()

        #expect(lightMenu.appearance?.name == .aqua)
        #expect(try #require(lightMenu.items.first?.view).appearance?.name == .aqua)
        #expect(try #require(lightMenu.items.dropFirst(3).first?.view).appearance?.name == .aqua)

        StatusBarMenuAppearanceProvider.current = { NSAppearance(named: .darkAqua) }
        let darkMenu = builder.buildMenu()

        #expect(darkMenu.appearance?.name == .darkAqua)
        #expect(try #require(darkMenu.items.first?.view).appearance?.name == .darkAqua)
        #expect(try #require(darkMenu.items.dropFirst(3).first?.view).appearance?.name == .darkAqua)
    }

    @Test func resetActionRequiresConfirmation() throws {
        let controller = makeLayoutPlanTestController()
        controller.settings.developerModeEnabled = true
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)
        var confirmationRequested = false
        builder.confirmationAlertPresenter = { _, _, _, _ in
            confirmationRequested = true
            return false
        }

        let menu = builder.buildMenu()
        let labels = menu.items.compactMap(\.view).flatMap(textLabels(in:))
        #expect(labels.contains("Reset Runtime State"))
        #expect(labels.contains("Restart Clearing State"))

        // Declining confirmation should prevent execution
        try actionRow(in: menu, labeled: "Reset Runtime State").performActionForTests()
        #expect(confirmationRequested == true)
    }

    @Test func statusBarTitleUsesInteractionMonitorWorkspaceAndFocusedApp() {
        let primary = makeLayoutPlanTestMonitor(displayId: 100, name: "Primary")
        let secondary = makeLayoutPlanTestMonitor(displayId: 200, name: "Secondary", x: 1920)
        let controller = makeLayoutPlanTestController(
            monitors: [primary, secondary],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", displayName: "Mail", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", displayName: "Code", monitorAssignment: .secondary)
            ]
        )
        controller.settings.statusBarShowWorkspaceName = true
        controller.settings.statusBarShowAppNames = true

        guard let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing secondary workspace for status bar monitor test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 202),
            pid: 202,
            windowId: 202,
            to: secondaryWorkspaceId
        )
        controller.appInfoCache.storeInfoForTests(
            pid: 202,
            name: "Secondary App",
            bundleId: "com.example.secondary"
        )
        _ = controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondary.id)
        _ = controller.workspaceManager.setManagedFocus(token, in: secondaryWorkspaceId, onMonitor: secondary.id)

        let statusBarController = makeStatusBarController(for: controller)
        defer { statusBarController.cleanup() }
        statusBarController.setup()

        #expect(statusBarController.statusButtonTitleForTests() == " Code \u{2013} Secondary App")
        #expect(statusBarController.statusButtonImagePositionForTests() == .imageLeft)
    }

    @Test func statusBarRefreshStaysReadOnlyOnUnassignedThirdMonitor() {
        let primary = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
        let secondary = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
        let third = makeLayoutPlanSecondaryTestMonitor(slot: 2, name: "Third", x: 3840)
        let controller = makeLayoutPlanTestController(
            monitors: [primary, secondary, third],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
            ]
        )
        controller.settings.statusBarShowWorkspaceName = true

        #expect(controller.workspaceManager.setInteractionMonitor(third.id))

        var sessionChangeCount = 0
        let originalOnSessionStateChanged = controller.workspaceManager.onSessionStateChanged
        controller.workspaceManager.onSessionStateChanged = {
            sessionChangeCount += 1
            originalOnSessionStateChanged?()
        }

        let statusBarController = makeStatusBarController(for: controller)
        defer { statusBarController.cleanup() }

        sessionChangeCount = 0
        statusBarController.setup()

        #expect(sessionChangeCount == 0)
        #expect(statusBarController.statusButtonTitleForTests() == "")
        #expect(statusBarController.statusButtonImagePositionForTests() == .imageOnly)
    }

    @Test func statusBarTitleUsesDisplayNameOrRawNameAndTruncatesFocusedApp() {
        let monitor = makeLayoutPlanTestMonitor()
        let controller = makeLayoutPlanTestController(
            monitors: [monitor],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "2", displayName: "Code", monitorAssignment: .main)
            ]
        )
        controller.settings.statusBarShowWorkspaceName = true
        controller.settings.statusBarShowAppNames = true

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false) else {
            Issue.record("Missing workspace for status bar formatting test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 303),
            pid: 303,
            windowId: 303,
            to: workspaceId
        )
        let longAppName = "VeryLongFocusedApplication"
        let expectedTruncated = StatusBarController.truncatedStatusBarAppName(longAppName)
        controller.appInfoCache.storeInfoForTests(
            pid: 303,
            name: longAppName,
            bundleId: "com.example.long"
        )
        _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        let statusBarController = makeStatusBarController(for: controller)
        defer { statusBarController.cleanup() }
        statusBarController.setup()

        #expect(statusBarController.statusButtonTitleForTests() == " Code \u{2013} \(expectedTruncated)")

        controller.settings.statusBarUseWorkspaceId = true
        controller.refreshStatusBar()

        #expect(statusBarController.statusButtonTitleForTests() == " 2 \u{2013} \(expectedTruncated)")
    }

    @Test func statusBarTitleIncludesFocusedFloatingWindowApp() {
        let controller = makeLayoutPlanTestController()
        controller.settings.statusBarShowWorkspaceName = true
        controller.settings.statusBarShowAppNames = true

        guard let monitor = controller.monitorForInteraction(),
              let workspaceId = controller.interactionWorkspace()?.id
        else {
            Issue.record("Missing active workspace for floating status bar test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 404),
            pid: 404,
            windowId: 404,
            to: workspaceId,
            mode: .floating
        )
        controller.appInfoCache.storeInfoForTests(
            pid: 404,
            name: "Floating App",
            bundleId: "com.example.floating"
        )
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        let statusBarController = makeStatusBarController(for: controller)
        defer { statusBarController.cleanup() }
        statusBarController.setup()

        #expect(statusBarController.statusButtonTitleForTests() == " 1 \u{2013} Floating App")
    }

    private func textLabels(in view: NSView) -> [String] {
        let direct = (view as? NSTextField).map(\.stringValue).map { [$0] } ?? []
        return direct + view.subviews.flatMap(textLabels(in:))
    }

    private func actionRow(in menu: NSMenu, labeled label: String) throws -> MenuActionRowView {
        try #require(
            menu.items
                .compactMap(\.view)
                .compactMap { $0 as? MenuActionRowView }
                .first { textLabels(in: $0).contains(label) }
        )
    }

    private func makeStatusBarController(for controller: WMController) -> StatusBarController {
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller
        )
        controller.statusBarController = statusBarController
        return statusBarController
    }
}
