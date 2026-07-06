// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import ApplicationServices
import Foundation
@testable import Nehir
import Testing

private func makeWindowActionHandlerTestDefaults() -> UserDefaults {
    let suiteName = "dev.guria.nehir.window-action-handler.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeWindowActionHandlerTestWindow(windowId: Int) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private func makeWindowActionHandlerTestFacts() -> WindowRuleFacts {
    WindowRuleFacts(
        appName: "Window Action Handler Test App",
        ax: AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: nil,
            hasCloseButton: true,
            hasFullscreenButton: true,
            fullscreenButtonEnabled: true,
            hasZoomButton: true,
            hasMinimizeButton: true,
            appPolicy: .regular,
            bundleId: "com.example.window-action-handler",
            attributeFetchSucceeded: true
        ),
        sizeConstraints: nil,
        windowServer: nil
    )
}

@MainActor
private func makeWindowActionHandlerTestController() -> WMController {
    resetSharedControllerStateForTests()
    NativeFullscreenPlaceholderManager.materializesWindowsForTests = false
    let settings = SettingsStore(defaults: makeWindowActionHandlerTestDefaults())
    settings.workspaceConfigurations = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .main)
    ]
    let controller = WMController(
        settings: settings,
        windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
    )
    installSynchronousFrameApplySuccessOverride(on: controller)
    controller.workspaceManager.applyMonitorConfigurationChange([makeLayoutPlanTestMonitor()])
    controller.axEventHandler.windowFactsProvider = { _, _ in
        makeWindowActionHandlerTestFacts()
    }
    return controller
}

@MainActor
private func prepareWindowActionHandlerNiriState(
    on controller: WMController,
    assignments: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)],
    focusedWindowId: Int?,
    ensureWorkspaces: Set<WorkspaceDescriptor.ID> = []
) async -> [Int: WindowHandle] {
    controller.enableNiriLayout(revealStyle: .auto)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    var handlesByWindowId: [Int: WindowHandle] = [:]
    var workspaceByWindowId: [Int: WorkspaceDescriptor.ID] = [:]

    for (workspaceId, windowId) in assignments {
        let token = controller.workspaceManager.addWindow(
            makeWindowActionHandlerTestWindow(windowId: windowId),
            pid: getpid(),
            windowId: windowId,
            to: workspaceId
        )
        guard let handle = controller.workspaceManager.handle(for: token) else {
            fatalError("Expected bridge handle for seeded window-action-handler window")
        }
        handlesByWindowId[windowId] = handle
        workspaceByWindowId[windowId] = workspaceId
        _ = controller.workspaceManager.rememberFocus(handle, in: workspaceId)
    }

    if let focusedWindowId,
       let focusedHandle = handlesByWindowId[focusedWindowId],
       let focusedWorkspaceId = workspaceByWindowId[focusedWindowId]
    {
        _ = controller.workspaceManager.setManagedFocus(
            focusedHandle,
            in: focusedWorkspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: focusedWorkspaceId)
        )
    }

    guard let engine = controller.niriEngine else {
        return handlesByWindowId
    }

    let workspaceIds = Set(assignments.map(\.workspaceId)).union(ensureWorkspaces)
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
        }
    }

    return handlesByWindowId
}

@MainActor
private func windowActionHandlerColumnOrder(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> [Int]? {
    controller.niriEngine?.columns(in: workspaceId).compactMap { $0.windowNodes.first?.token.windowId }
}

@Suite(.serialized) @MainActor struct WindowActionHandlerTests {
    @Test func summonWindowRightAppendsToRightmostColumnWhenNoAnchor() async {
        let controller = makeWindowActionHandlerTestController()
        guard let targetWorkspaceId = controller.interactionWorkspace()?.id,
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspaces for no-anchor summon-right test")
            return
        }

        let handles = await prepareWindowActionHandlerNiriState(
            on: controller,
            assignments: [
                (workspaceId: targetWorkspaceId, windowId: 9501),
                (workspaceId: targetWorkspaceId, windowId: 9502),
                (workspaceId: sourceWorkspaceId, windowId: 9503)
            ],
            focusedWindowId: 9501
        )
        guard let summonedHandle = handles[9503] else {
            Issue.record("Missing summoned handle for no-anchor summon-right test")
            return
        }

        #expect(controller.windowActionHandler.summonWindowRight(
            handle: summonedHandle,
            anchorToken: nil,
            anchorWorkspaceId: targetWorkspaceId
        ))
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.workspace(for: summonedHandle.id) == targetWorkspaceId)
        #expect(controller.workspaceManager.rememberedTiledFocusToken(in: targetWorkspaceId) == summonedHandle.id)
        #expect(windowActionHandlerColumnOrder(on: controller, workspaceId: targetWorkspaceId) == [9501, 9502, 9503])
    }

    @Test func summonWindowRightIntoEmptyActiveWorkspaceWithNoAnchor() async {
        let controller = makeWindowActionHandlerTestController()
        guard let targetWorkspaceId = controller.interactionWorkspace()?.id,
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspaces for empty no-anchor summon-right test")
            return
        }

        let handles = await prepareWindowActionHandlerNiriState(
            on: controller,
            assignments: [
                (workspaceId: sourceWorkspaceId, windowId: 9601)
            ],
            focusedWindowId: 9601,
            ensureWorkspaces: [targetWorkspaceId]
        )
        guard let summonedHandle = handles[9601] else {
            Issue.record("Missing summoned handle for empty no-anchor summon-right test")
            return
        }

        #expect(controller.windowActionHandler.summonWindowRight(
            handle: summonedHandle,
            anchorToken: nil,
            anchorWorkspaceId: targetWorkspaceId
        ))
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.workspace(for: summonedHandle.id) == targetWorkspaceId)
        #expect(controller.workspaceManager.rememberedTiledFocusToken(in: targetWorkspaceId) == summonedHandle.id)
        #expect(windowActionHandlerColumnOrder(on: controller, workspaceId: targetWorkspaceId) == [9601])
    }

    @Test func summonWindowRightStillInsertsRightOfAnchorWhenTokenPresent() async {
        let controller = makeWindowActionHandlerTestController()
        guard let targetWorkspaceId = controller.interactionWorkspace()?.id,
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspaces for anchored summon-right test")
            return
        }

        let handles = await prepareWindowActionHandlerNiriState(
            on: controller,
            assignments: [
                (workspaceId: targetWorkspaceId, windowId: 9701),
                (workspaceId: targetWorkspaceId, windowId: 9702),
                (workspaceId: sourceWorkspaceId, windowId: 9703)
            ],
            focusedWindowId: 9701
        )
        guard let anchorHandle = handles[9701],
              let summonedHandle = handles[9703]
        else {
            Issue.record("Missing handles for anchored summon-right test")
            return
        }

        #expect(controller.windowActionHandler.summonWindowRight(
            handle: summonedHandle,
            anchorToken: anchorHandle.id,
            anchorWorkspaceId: targetWorkspaceId
        ))
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.workspace(for: summonedHandle.id) == targetWorkspaceId)
        #expect(controller.workspaceManager.rememberedTiledFocusToken(in: targetWorkspaceId) == summonedHandle.id)
        #expect(windowActionHandlerColumnOrder(on: controller, workspaceId: targetWorkspaceId) == [9701, 9703, 9702])
    }
}
