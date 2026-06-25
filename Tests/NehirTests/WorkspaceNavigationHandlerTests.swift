// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import ApplicationServices
import CoreGraphics
import Foundation
@testable import Nehir
import Testing

private func makeWorkspaceNavigationTestDefaults() -> UserDefaults {
    let suiteName = "dev.guria.nehir.workspace-navigation.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

@MainActor
private func makeWorkspaceNavigationTestController(
    monitors: [Monitor] = [makeLayoutPlanTestMonitor()],
    workspaceConfigurations: [WorkspaceConfiguration] = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .main)
    ]
) -> WMController {
    resetSharedControllerStateForTests()
    let settings = SettingsStore(defaults: makeWorkspaceNavigationTestDefaults())
    settings.workspaceConfigurations = workspaceConfigurations
    let controller = WMController(
        settings: settings,
        windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
    )
    installSynchronousFrameApplySuccessOverride(on: controller)
    controller.workspaceManager.applyMonitorConfigurationChange(monitors)
    return controller
}

@MainActor
private func addWorkspaceNavigationTestWindow(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID,
    windowId: Int
) -> WindowHandle {
    let token = controller.workspaceManager.addWindow(
        makeLayoutPlanTestWindow(windowId: windowId),
        pid: getpid(),
        windowId: windowId,
        to: workspaceId
    )
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Expected bridge handle for workspace navigation test window")
    }
    return handle
}

@MainActor
private func syncNiriWorkspaceStateForWorkspaceNavigationTests(
    on controller: WMController,
    workspaceIds: Set<WorkspaceDescriptor.ID>
) {
    guard let engine = controller.niriEngine else { return }

    for workspaceId in workspaceIds {
        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        let selectedNodeId = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId
        let focusedHandle = controller.workspaceManager.lastFocusedHandle(in: workspaceId)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: selectedNodeId,
            focusedHandle: focusedHandle
        )

        let resolvedSelection = focusedHandle.flatMap { engine.findNode(for: $0)?.id }
            ?? engine.validateSelection(selectedNodeId, in: workspaceId)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = resolvedSelection
            state.activeColumnIndex = min(state.activeColumnIndex, max(0, engine.columns(in: workspaceId).count - 1))
        }
    }
}

@MainActor
private func assertMovedWindowRevealedInTargetViewport(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID,
    token: WindowToken,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let engine = controller.niriEngine else {
        Issue.record("Missing Niri engine", sourceLocation: sourceLocation)
        return
    }
    guard let movedNode = engine.findNode(for: token),
          let movedColumn = engine.column(of: movedNode),
          let movedColumnIndex = engine.columnIndex(of: movedColumn, in: workspaceId)
    else {
        Issue.record("Moved node was not present in the target workspace", sourceLocation: sourceLocation)
        return
    }

    let targetState = controller.workspaceManager.niriViewportState(for: workspaceId)
    #expect(movedColumnIndex > 0, sourceLocation: sourceLocation)
    #expect(targetState.selectedNodeId == movedNode.id, sourceLocation: sourceLocation)
    #expect(targetState.activeColumnIndex == movedColumnIndex, sourceLocation: sourceLocation)
    #expect(
        controller.workspaceManager.rememberedTiledFocusToken(in: workspaceId) == token,
        sourceLocation: sourceLocation
    )
}

@Suite(.serialized) struct WorkspaceNavigationHandlerTests {
    @Test @MainActor func moveFocusedWindowWithoutFollowRevealsInactiveTargetViewport() async throws {
        let controller = makeWorkspaceNavigationTestController()
        controller.settings.focusFollowsWindowToMonitor = false

        guard let monitor = controller.workspaceManager.monitors.first,
              let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing single-monitor workspace fixture")
            return
        }

        controller.enableNiriLayout()
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let targetFirst = addWorkspaceNavigationTestWindow(
            on: controller,
            workspaceId: targetWorkspaceId,
            windowId: 10_101
        )
        _ = addWorkspaceNavigationTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: 10_102)
        _ = addWorkspaceNavigationTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: 10_103)
        let movedHandle = addWorkspaceNavigationTestWindow(
            on: controller,
            workspaceId: sourceWorkspaceId,
            windowId: 10_104
        )

        _ = controller.workspaceManager.rememberFocus(targetFirst, in: targetWorkspaceId)
        _ = controller.workspaceManager.setManagedFocus(movedHandle, in: sourceWorkspaceId, onMonitor: monitor.id)
        syncNiriWorkspaceStateForWorkspaceNavigationTests(
            on: controller,
            workspaceIds: [targetWorkspaceId, sourceWorkspaceId]
        )
        controller.workspaceManager.withNiriViewportState(for: targetWorkspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(0)
        }
        _ = controller.workspaceManager.setActiveWorkspace(sourceWorkspaceId, on: monitor.id)
        _ = controller.workspaceManager.setInteractionMonitor(monitor.id)

        controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 0)
        await waitForLayoutPlanRefreshWork(on: controller)

        assertMovedWindowRevealedInTargetViewport(
            controller: controller,
            workspaceId: targetWorkspaceId,
            token: movedHandle.id
        )
        #expect(controller.interactionWorkspace()?.id == sourceWorkspaceId)
    }

    @Test @MainActor func moveFocusedWindowFromBarMovesFocusedWindowToClickedWorkspace() async throws {
        let controller = makeWorkspaceNavigationTestController()
        controller.settings.focusFollowsWindowToMonitor = false

        guard let monitor = controller.workspaceManager.monitors.first,
              let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing single-monitor workspace fixture")
            return
        }

        controller.enableNiriLayout()
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let targetFirst = addWorkspaceNavigationTestWindow(
            on: controller,
            workspaceId: targetWorkspaceId,
            windowId: 11_101
        )
        _ = addWorkspaceNavigationTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: 11_102)
        _ = addWorkspaceNavigationTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: 11_103)
        let movedHandle = addWorkspaceNavigationTestWindow(
            on: controller,
            workspaceId: sourceWorkspaceId,
            windowId: 11_104
        )

        _ = controller.workspaceManager.rememberFocus(targetFirst, in: targetWorkspaceId)
        _ = controller.workspaceManager.setManagedFocus(movedHandle, in: sourceWorkspaceId, onMonitor: monitor.id)
        syncNiriWorkspaceStateForWorkspaceNavigationTests(
            on: controller,
            workspaceIds: [targetWorkspaceId, sourceWorkspaceId]
        )
        controller.workspaceManager.withNiriViewportState(for: targetWorkspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(0)
        }
        _ = controller.workspaceManager.setActiveWorkspace(sourceWorkspaceId, on: monitor.id)
        _ = controller.workspaceManager.setInteractionMonitor(monitor.id)

        controller.moveFocusedWindowFromBar(toWorkspaceId: targetWorkspaceId)
        await waitForLayoutPlanRefreshWork(on: controller)

        assertMovedWindowRevealedInTargetViewport(
            controller: controller,
            workspaceId: targetWorkspaceId,
            token: movedHandle.id
        )
        #expect(controller.workspaceManager.workspace(for: movedHandle.id) == targetWorkspaceId)
        #expect(controller.interactionWorkspace()?.id == sourceWorkspaceId)
    }

    @Test @MainActor func moveFocusedWindowFromBarNoopsWhenNoManagedFocus() async throws {
        let controller = makeWorkspaceNavigationTestController()

        guard let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)
        else {
            Issue.record("Missing single-monitor workspace fixture")
            return
        }

        // A window exists on the source workspace, but no managed focus is confirmed
        // and the Niri engine is not enabled, so `managedCommandTargetToken()` is nil.
        let unmovedHandle = addWorkspaceNavigationTestWindow(
            on: controller,
            workspaceId: sourceWorkspaceId,
            windowId: 12_101
        )
        #expect(controller.managedCommandTargetToken() == nil)

        controller.moveFocusedWindowFromBar(toWorkspaceId: targetWorkspaceId)
        await waitForLayoutPlanRefreshWork(on: controller)

        #expect(controller.workspaceManager.workspace(for: unmovedHandle.id) == sourceWorkspaceId)
    }

    @Test @MainActor func moveFocusedWindowFromBarResolvesCustomNamedWorkspace() async throws {
        // Nehir workspace names are always numeric; a custom *display* name is separate
        // from the raw numeric `name`. This verifies the bar entry point resolves via
        // `descriptor(for:)?.name` (the raw numeric id) for a non-default-numbered
        // workspace, and that a custom display name does not leak into the resolution.
        let controller = makeWorkspaceNavigationTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "3", displayName: "Development", monitorAssignment: .main)
            ]
        )
        controller.settings.focusFollowsWindowToMonitor = false

        guard let monitor = controller.workspaceManager.monitors.first,
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        else {
            Issue.record("Missing custom-named workspace fixture")
            return
        }
        #expect(controller.workspaceManager.descriptor(for: targetWorkspaceId)?.name == "3")

        controller.enableNiriLayout()
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        _ = addWorkspaceNavigationTestWindow(
            on: controller,
            workspaceId: targetWorkspaceId,
            windowId: 13_101
        )
        _ = addWorkspaceNavigationTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: 13_102)
        let movedHandle = addWorkspaceNavigationTestWindow(
            on: controller,
            workspaceId: sourceWorkspaceId,
            windowId: 13_103
        )

        _ = controller.workspaceManager.setManagedFocus(movedHandle, in: sourceWorkspaceId, onMonitor: monitor.id)
        syncNiriWorkspaceStateForWorkspaceNavigationTests(
            on: controller,
            workspaceIds: [sourceWorkspaceId, targetWorkspaceId]
        )
        controller.workspaceManager.withNiriViewportState(for: targetWorkspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(0)
        }
        _ = controller.workspaceManager.setActiveWorkspace(sourceWorkspaceId, on: monitor.id)
        _ = controller.workspaceManager.setInteractionMonitor(monitor.id)

        controller.moveFocusedWindowFromBar(toWorkspaceId: targetWorkspaceId)
        await waitForLayoutPlanRefreshWork(on: controller)

        assertMovedWindowRevealedInTargetViewport(
            controller: controller,
            workspaceId: targetWorkspaceId,
            token: movedHandle.id
        )
        #expect(controller.workspaceManager.workspace(for: movedHandle.id) == targetWorkspaceId)
    }
}
