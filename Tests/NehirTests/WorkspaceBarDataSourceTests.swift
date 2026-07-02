// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation
@testable import Nehir
import Testing

private func makeWorkspaceBarTestMetadata(
    bundleId: String,
    workspaceId: WorkspaceDescriptor.ID,
    mode: TrackedWindowMode = .floating,
    frame: CGRect? = CGRect(x: 100, y: 100, width: 640, height: 480)
) -> ManagedReplacementMetadata {
    ManagedReplacementMetadata(
        bundleId: bundleId,
        workspaceId: workspaceId,
        mode: mode,
        role: kAXWindowRole as String,
        subrole: kAXStandardWindowSubrole as String,
        title: nil,
        windowLevel: 0,
        parentWindowId: nil,
        frame: frame
    )
}

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
            mode: .floating,
            managedReplacementMetadata: makeWorkspaceBarTestMetadata(
                bundleId: "com.example.console",
                workspaceId: workspace2
            )
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: true,
                showFloatingWindows: false,
                showWorkspacesFromOtherDisplays: false
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
            mode: .floating,
            managedReplacementMetadata: makeWorkspaceBarTestMetadata(
                bundleId: "com.example.console",
                workspaceId: workspace2
            )
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: true,
                showFloatingWindows: true,
                showWorkspacesFromOtherDisplays: false
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
                showFloatingWindows: false,
                showWorkspacesFromOtherDisplays: false
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
            mode: .floating,
            managedReplacementMetadata: makeWorkspaceBarTestMetadata(
                bundleId: "com.example.floating",
                workspaceId: workspace1
            )
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
                showFloatingWindows: true,
                showWorkspacesFromOtherDisplays: false
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
            mode: .floating,
            managedReplacementMetadata: makeWorkspaceBarTestMetadata(
                bundleId: "com.example.floating",
                workspaceId: workspace1
            )
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: false,
                showFloatingWindows: true,
                showWorkspacesFromOtherDisplays: false
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
            mode: .floating,
            managedReplacementMetadata: makeWorkspaceBarTestMetadata(
                bundleId: "com.example.terminal",
                workspaceId: workspace1
            )
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: true,
                hideEmptyWorkspaces: false,
                showFloatingWindows: true,
                showWorkspacesFromOtherDisplays: false
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

    @Test @MainActor func foreignWorkspacesAppearOnlyWhenToggleIsEnabled() throws {
        let fixture = makeTwoMonitorLayoutPlanTestController(
            primaryMonitor: makeLayoutPlanPrimaryTestMonitor(name: "Primary"),
            secondaryMonitor: makeLayoutPlanSecondaryTestMonitor(name: "Built-in Retina Display", x: 1920)
        )
        let controller = fixture.controller
        let primaryMonitor = fixture.primaryMonitor
        let secondaryMonitor = fixture.secondaryMonitor
        let secondaryWorkspaceId = fixture.secondaryWorkspaceId

        // Give the secondary display's workspace a tiled window so it is not empty.
        controller.appInfoCache.storeInfoForTests(pid: 7100, name: "Other", bundleId: "com.example.other")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1200),
            pid: 7100,
            windowId: 1200,
            to: secondaryWorkspaceId,
            mode: .tiling
        )

        func projection(showingForeign: Bool) -> WorkspaceBarProjection {
            WorkspaceBarDataSource.workspaceBarProjection(
                for: primaryMonitor,
                options: WorkspaceBarProjectionOptions(
                    deduplicateAppIcons: false,
                    hideEmptyWorkspaces: false,
                    showFloatingWindows: false,
                    showWorkspacesFromOtherDisplays: showingForeign
                ),
                workspaceManager: controller.workspaceManager,
                appInfoCache: controller.appInfoCache,
                niriEngine: nil,
                focusedToken: controller.workspaceManager.confirmedManagedFocusToken,
                settings: controller.settings
            )
        }

        // Toggle off: only this display's workspaces appear; none are foreign.
        let off = projection(showingForeign: false)
        #expect(off.items.contains(where: \.isForeign) == false)
        #expect(off.items.contains(where: { $0.id == secondaryWorkspaceId }) == false)

        // Toggle on: the secondary's active workspace appears as a compact foreign pill.
        let on = projection(showingForeign: true)
        let foreign = try #require(on.items.first(where: { $0.id == secondaryWorkspaceId && $0.isForeign }))
        #expect(foreign.homeMonitorName == secondaryMonitor.name)
        #expect(foreign.homeMonitorLabel == "D2")
        #expect(foreign.isActiveOnHomeDisplay == true)
        #expect(foreign.isFocused == false)
        #expect(foreign.windows.isEmpty)
    }

    @Test @MainActor func foreignEmptyWorkspacesRespectHideEmptyWorkspaces() throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        let primaryMonitor = fixture.primaryMonitor
        let secondaryWorkspaceId = fixture.secondaryWorkspaceId
        // The secondary display's workspace has no windows.

        let projection = WorkspaceBarDataSource.workspaceBarProjection(
            for: primaryMonitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: true,
                showFloatingWindows: false,
                showWorkspacesFromOtherDisplays: true
            ),
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: nil,
            focusedToken: controller.workspaceManager.confirmedManagedFocusToken,
            settings: controller.settings
        )

        // An empty foreign workspace is hidden, consistent with local items.
        #expect(projection.items.contains(where: { $0.id == secondaryWorkspaceId }) == false)
        #expect(projection.items.contains(where: \.isForeign) == false)
    }
}
