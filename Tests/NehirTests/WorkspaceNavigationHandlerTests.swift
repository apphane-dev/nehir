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
    #expect(controller.workspaceManager.rememberedTiledFocusToken(in: workspaceId) == token, sourceLocation: sourceLocation)
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

        let targetFirst = addWorkspaceNavigationTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: 10_101)
        _ = addWorkspaceNavigationTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: 10_102)
        _ = addWorkspaceNavigationTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: 10_103)
        let movedHandle = addWorkspaceNavigationTestWindow(on: controller, workspaceId: sourceWorkspaceId, windowId: 10_104)

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
}
