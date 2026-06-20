// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation
@testable import Nehir
import Testing

@Suite struct WorkspaceBarDataSourceTests {
    @Test @MainActor func floatingOnlyWorkspaceIsHiddenWhenFloatingWindowsAreDisabled() throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 6001, name: "Terminal", bundleId: "com.example.terminal")
        controller.appInfoCache.storeInfoForTests(pid: 6002, name: "Console", bundleId: "com.example.console")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 901),
            pid: 6001,
            windowId: 901,
            to: workspace1,
            mode: .tiling
        )
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 902),
            pid: 6002,
            windowId: 902,
            to: workspace2,
            mode: .floating
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: true,
                showFloatingWindows: false
            ),
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: nil,
            focusedToken: controller.workspaceManager.confirmedManagedFocusToken,
            settings: controller.settings
        )

        #expect(items.map(\.id).contains(workspace1))
        #expect(items.map(\.id).contains(workspace2) == false)
    }

    @Test @MainActor func floatingOnlyWorkspaceIsShownWhenFloatingWindowsAreEnabled() throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 6102, name: "Console", bundleId: "com.example.console")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 912),
            pid: 6102,
            windowId: 912,
            to: workspace2,
            mode: .floating
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: true,
                showFloatingWindows: true
            ),
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: nil,
            focusedToken: controller.workspaceManager.confirmedManagedFocusToken,
            settings: controller.settings
        )

        let workspaceItem = try #require(items.first(where: { $0.id == workspace2 }))
        #expect(workspaceItem.tiledWindows.isEmpty)
        #expect(workspaceItem.floatingWindows.map(\.appName) == ["Console"])
        #expect(workspaceItem.windows.map(\.windowId) == [912])
    }

    @Test @MainActor func hiddenScratchpadProjectsAsTopLevelPillWhenFloatingWindowsAreDisabled() throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 6202, name: "Scratch App", bundleId: "com.example.scratch")
        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 922),
            pid: 6202,
            windowId: 922,
            to: workspace2,
            mode: .floating
        )
        _ = controller.workspaceManager.setScratchpadToken(token)
        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )

        let projection = WorkspaceBarDataSource.workspaceBarProjection(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: true,
                showFloatingWindows: false
            ),
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: nil,
            focusedToken: controller.workspaceManager.confirmedManagedFocusToken,
            settings: controller.settings
        )

        #expect(projection.items.map(\.id).contains(workspace2) == false)
        #expect(projection.scratchpad?.window.appName == "Scratch App")
        #expect(projection.scratchpad?.window.windowId == 922)
        #expect(projection.scratchpad?.isVisible == false)
    }

    @Test @MainActor func scratchpadIsSeparatedFromRegularFloatingWindows() throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)
        else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 6301, name: "Floating App", bundleId: "com.example.floating")
        controller.appInfoCache.storeInfoForTests(pid: 6302, name: "Scratch App", bundleId: "com.example.scratch")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 931),
            pid: 6301,
            windowId: 931,
            to: workspace1,
            mode: .floating
        )
        let scratchpadToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 932),
            pid: 6302,
            windowId: 932,
            to: workspace1,
            mode: .floating
        )
        _ = controller.workspaceManager.setScratchpadToken(scratchpadToken)

        let projection = WorkspaceBarDataSource.workspaceBarProjection(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: false,
                showFloatingWindows: true
            ),
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: nil,
            focusedToken: controller.workspaceManager.confirmedManagedFocusToken,
            settings: controller.settings
        )

        let workspaceItem = try #require(projection.items.first(where: { $0.id == workspace1 }))
        #expect(workspaceItem.floatingWindows.map(\.appName) == ["Floating App"])
        #expect(workspaceItem.windows.map(\.windowId) == [931])
        #expect(projection.scratchpad?.window.appName == "Scratch App")
        #expect(projection.scratchpad?.isVisible == true)
    }

    @Test @MainActor func mixedWorkspacePlacesFloatingWindowsInTrailingGroup() throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)
        else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 7001, name: "Tiled App", bundleId: "com.example.tiled")
        controller.appInfoCache.storeInfoForTests(pid: 7002, name: "Floating App", bundleId: "com.example.floating")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1001),
            pid: 7001,
            windowId: 1001,
            to: workspace1,
            mode: .tiling
        )
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1002),
            pid: 7002,
            windowId: 1002,
            to: workspace1,
            mode: .floating
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: false,
                showFloatingWindows: true
            ),
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: nil,
            focusedToken: controller.workspaceManager.confirmedManagedFocusToken,
            settings: controller.settings
        )

        let workspaceItem = try #require(items.first(where: { $0.id == workspace1 }))
        #expect(workspaceItem.tiledWindows.map(\.appName) == ["Tiled App"])
        #expect(workspaceItem.floatingWindows.map(\.appName) == ["Floating App"])
        #expect(workspaceItem.windows.map(\.windowId) == [1001, 1002])
    }

    @Test @MainActor func deduplicatedProjectionKeepsSameAppSeparatedByMode() throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)
        else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 8001, name: "Terminal", bundleId: "com.example.terminal")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1101),
            pid: 8001,
            windowId: 1101,
            to: workspace1,
            mode: .tiling
        )
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1102),
            pid: 8001,
            windowId: 1102,
            to: workspace1,
            mode: .tiling
        )
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1103),
            pid: 8001,
            windowId: 1103,
            to: workspace1,
            mode: .floating
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: true,
                hideEmptyWorkspaces: false,
                showFloatingWindows: true
            ),
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: nil,
            focusedToken: controller.workspaceManager.confirmedManagedFocusToken,
            settings: controller.settings
        )

        let workspaceItem = try #require(items.first(where: { $0.id == workspace1 }))
        #expect(workspaceItem.tiledWindows.count == 1)
        #expect(workspaceItem.tiledWindows.first?.windowCount == 2)
        #expect(workspaceItem.floatingWindows.count == 1)
        #expect(workspaceItem.floatingWindows.first?.windowCount == 1)
        #expect(workspaceItem.windows.map(\.windowCount) == [2, 1])
    }
}
