// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
import Testing

@MainActor
private func prepareWorkspaceBarSummonRightLayout(
    on controller: WMController,
    workspaceIds: Set<WorkspaceDescriptor.ID>
) async {
    controller.enableNiriLayout(revealStyle: .auto)
    await waitForLayoutPlanRefreshWork(on: controller)
    controller.syncMonitorsToNiriEngine()

    guard let engine = controller.niriEngine else {
        Issue.record("Expected Niri engine after enabling Niri layout")
        return
    }
    for workspaceId in workspaceIds {
        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        let focusedHandle = controller.workspaceManager.lastFocusedHandle(in: workspaceId)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
            focusedHandle: focusedHandle
        )
        let selection = focusedHandle.flatMap { engine.findNode(for: $0)?.id }
            ?? engine.validateSelection(nil, in: workspaceId)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = selection
        }
    }
}

@MainActor
private func workspaceBarSummonColumnOrder(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> [WindowToken] {
    controller.niriEngine?.columns(in: workspaceId).compactMap { $0.windowNodes.first?.token } ?? []
}

@Suite(.serialized) @MainActor struct WorkspaceBarSummonRightTests {
    @Test func clickedTokenIsSummonedImmediatelyRightOfFocusedAnchor() async throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 921)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let targetWorkspace = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let sourceWorkspace = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        let anchor = addLayoutPlanTestWindow(on: controller, workspaceId: targetWorkspace, windowId: 9210)
        let clicked = addLayoutPlanTestWindow(on: controller, workspaceId: sourceWorkspace, windowId: 9211)
        let anchorHandle = try #require(controller.workspaceManager.handle(for: anchor))
        _ = controller.workspaceManager.setManagedFocus(anchorHandle, in: targetWorkspace, onMonitor: monitor.id)
        await prepareWorkspaceBarSummonRightLayout(
            on: controller,
            workspaceIds: [targetWorkspace, sourceWorkspace]
        )

        #expect(controller.summonWindowRightFromBar(token: clicked, on: monitor.id) == .executed)
        await waitForLayoutPlanRefreshWork(on: controller)

        #expect(controller.workspaceManager.workspace(for: clicked) == targetWorkspace)
        #expect(workspaceBarSummonColumnOrder(on: controller, workspaceId: targetWorkspace) == [anchor, clicked])
    }

    @Test func owningSecondaryBarOverridesPrimaryInteractionMonitor() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        let primaryWindow = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 9220
        )
        let secondaryAnchor = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 9221
        )
        let clicked = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 9222
        )
        let primaryHandle = try #require(controller.workspaceManager.handle(for: primaryWindow))
        let secondaryHandle = try #require(controller.workspaceManager.handle(for: secondaryAnchor))
        _ = controller.workspaceManager.rememberFocus(secondaryHandle, in: fixture.secondaryWorkspaceId)
        _ = controller.workspaceManager.setManagedFocus(
            primaryHandle,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )
        await prepareWorkspaceBarSummonRightLayout(
            on: controller,
            workspaceIds: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId]
        )

        #expect(
            controller.summonWindowRightFromBar(token: clicked, on: fixture.secondaryMonitor.id) == .executed
        )
        await waitForLayoutPlanRefreshWork(on: controller)

        #expect(controller.workspaceManager.workspace(for: clicked) == fixture.secondaryWorkspaceId)
        #expect(
            workspaceBarSummonColumnOrder(on: controller, workspaceId: fixture.secondaryWorkspaceId)
                == [secondaryAnchor, clicked]
        )
    }

    @Test func emptyDestinationUsesWorkspaceOnlyAnchor() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        let clicked = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 9230
        )
        await prepareWorkspaceBarSummonRightLayout(
            on: controller,
            workspaceIds: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId]
        )
        let anchor = controller.summonRightAnchor(on: fixture.secondaryMonitor.id)
        #expect(anchor?.workspaceId == fixture.secondaryWorkspaceId)
        #expect(anchor?.token == nil)

        #expect(
            controller.summonWindowRightFromBar(token: clicked, on: fixture.secondaryMonitor.id) == .executed
        )
        await waitForLayoutPlanRefreshWork(on: controller)

        #expect(workspaceBarSummonColumnOrder(on: controller, workspaceId: fixture.secondaryWorkspaceId) == [clicked])
    }

    @Test func unmanagedFocusUsesRememberedWorkspaceAnchor() async throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 924)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let targetWorkspace = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let sourceWorkspace = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        let anchor = addLayoutPlanTestWindow(on: controller, workspaceId: targetWorkspace, windowId: 9240)
        let clicked = addLayoutPlanTestWindow(on: controller, workspaceId: sourceWorkspace, windowId: 9241)
        let anchorHandle = try #require(controller.workspaceManager.handle(for: anchor))
        _ = controller.workspaceManager.rememberFocus(anchorHandle, in: targetWorkspace)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
        await prepareWorkspaceBarSummonRightLayout(
            on: controller,
            workspaceIds: [targetWorkspace, sourceWorkspace]
        )

        #expect(controller.summonRightAnchor(on: monitor.id)?.token == anchor)
        #expect(controller.summonWindowRightFromBar(token: clicked, on: monitor.id) == .executed)
        await waitForLayoutPlanRefreshWork(on: controller)
        #expect(workspaceBarSummonColumnOrder(on: controller, workspaceId: targetWorkspace) == [anchor, clicked])
    }

    @Test func staleTokenAndUnavailableDestinationLeaveStateUnchanged() async throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 925)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let workspace = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspace, windowId: 9250)
        await prepareWorkspaceBarSummonRightLayout(on: controller, workspaceIds: [workspace])
        let before = workspaceBarSummonColumnOrder(on: controller, workspaceId: workspace)
        let stale = WindowToken(pid: token.pid, windowId: 9259)

        #expect(controller.summonWindowRightFromBar(token: stale, on: monitor.id) == .notFound)
        #expect(workspaceBarSummonColumnOrder(on: controller, workspaceId: workspace) == before)

        controller.workspaceManager.applyMonitorConfigurationChange([])
        _ = controller.workspaceManager.setInteractionMonitor(nil)
        #expect(controller.summonWindowRightFromBar(token: token, on: monitor.id) == .notFound)
        #expect(controller.workspaceManager.workspace(for: token) == workspace)
        #expect(workspaceBarSummonColumnOrder(on: controller, workspaceId: workspace) == before)
    }

    @Test func selectingCurrentAnchorIsSafeNoOp() async throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 926)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let workspace = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let anchor = addLayoutPlanTestWindow(on: controller, workspaceId: workspace, windowId: 9260)
        let anchorHandle = try #require(controller.workspaceManager.handle(for: anchor))
        _ = controller.workspaceManager.setManagedFocus(anchorHandle, in: workspace, onMonitor: monitor.id)
        await prepareWorkspaceBarSummonRightLayout(on: controller, workspaceIds: [workspace])
        let before = workspaceBarSummonColumnOrder(on: controller, workspaceId: workspace)

        #expect(controller.summonWindowRightFromBar(token: anchor, on: monitor.id) == .notFound)
        #expect(controller.workspaceManager.workspace(for: anchor) == workspace)
        #expect(workspaceBarSummonColumnOrder(on: controller, workspaceId: workspace) == before)
    }
}
