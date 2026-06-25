// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import CoreGraphics
import Foundation
@testable import Nehir
import Testing

/// Bar-wiring tests for the right-click action family (plan #18 Phase 3).
///
/// `.contextMenu` closures live inside the SwiftUI view hierarchy and cannot be
/// driven programmatically without simulating a real right-click gesture, so
/// these tests verify the *contract* the closures depend on rather than the
/// gesture itself:
///
/// 1. The bar snapshot exposes the window/scratchpad tokens the closures act on.
/// 2. The controller entry points the closures wrap work end-to-end on those
///    exact tokens (token-target, not focus — the #8/#18 seam).
/// 3. The single-slot disable flag (`scratchpadSlotOccupied`) tracks scratchpad
///    presence so the *Assign to Scratchpad* item disables correctly.
@Suite(.serialized) struct WorkspaceBarRightClickWiringTests {
    @Test @MainActor func snapshotExposesWindowTokensForEachWindowIcon() throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 901)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id else {
            Issue.record("Missing workspace for wiring fixture")
            return
        }

        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9010)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9011)

        let manager = WorkspaceBarManager()
        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRightClickPanelFactory()

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let snapshot = try #require(manager.snapshotForTests(on: monitor.id))
        let windowTokens = snapshot.items.flatMap(\.windows).map(\.id)
        #expect(snapshot.items.contains(where: { $0.windows.contains(where: { $0.id == tokenA }) }))
        #expect(windowTokens.contains(tokenB))
    }

    @Test @MainActor func controllerEntryPointsActOnBarSnapshotTokens() async throws {
        // Integration: the controller methods the closures wrap
        // (toggleWindowFloating / toggleWindowScratchpadAssignment /
        // moveWindowFromBar / closeWindowFromBar) act on the exact tokens the
        // bar snapshot exposes — proving the wiring is token-correct.
        let monitor = makeLayoutPlanTestMonitor(displayId: 902)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspaces for wiring fixture")
            return
        }

        controller.enableNiriLayout()
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: workspace1, windowId: 9020)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: workspace1, windowId: 9021)
        syncNiriWorkspaceStateForRightClickTests(on: controller, workspaceIds: [workspace1, workspace2])

        let manager = WorkspaceBarManager()
        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRightClickPanelFactory()

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let snapshot = try #require(manager.snapshotForTests(on: monitor.id))
        let exposedTokens = Set(snapshot.items.flatMap(\.windows).map(\.id))
        #expect(exposedTokens.contains(tokenA))
        #expect(exposedTokens.contains(tokenB))

        // moveWindowFromBar (window-icon *Move to Workspace ▸*) on tokenB
        // while it is still tiled (the niri engine tracks tiled windows).
        let moveResult = controller.moveWindowFromBar(token: tokenB, toWorkspaceId: workspace2)
        await waitForLayoutPlanRefreshWork(on: controller)
        #expect(moveResult == .executed)
        #expect(controller.workspaceManager.workspace(for: tokenB) == workspace2)

        // toggleWindowFloating (window-icon *Toggle Floating*) on tokenA.
        #expect(controller.toggleWindowFloating(token: tokenA) == .executed)
        #expect(controller.workspaceManager.windowMode(for: tokenA) == .floating)

        // closeWindowFromBar (window-icon *Close*) resolves tokenA's entry.
        #expect(controller.closeWindowFromBar(token: tokenA) == .executed)
    }

    @Test @MainActor func scratchpadPresenceDrivesAssignItemDisabledFlag() throws {
        // The single-slot constraint (#7): the *Assign to Scratchpad* item must
        // disable when the slot is occupied. The view derives
        // `scratchpadSlotOccupied` from `snapshot.scratchpad != nil`; verify the
        // snapshot tracks scratchpad presence.
        let monitor = makeLayoutPlanTestMonitor(displayId: 903)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id else {
            Issue.record("Missing workspace for scratchpad wiring fixture")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9030)
        controller.axManager.applyFramesParallel([(
            token.pid,
            token.windowId,
            CGRect(x: 140, y: 120, width: 760, height: 520)
        )])

        let manager = WorkspaceBarManager()
        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRightClickPanelFactory()

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        // No scratchpad → item enabled (slot free).
        #expect(try #require(manager.snapshotForTests(on: monitor.id)).scratchpad == nil)

        // Assigning makes the scratchpad pill appear → slot occupied → item disabled.
        #expect(controller.assignWindowToScratchpad(token: token) == .executed)
        manager.update()
        let snapshot = try #require(manager.snapshotForTests(on: monitor.id))
        #expect(snapshot.scratchpad?.window.id == token)

        // A second assignment is rejected (the disable flag would have prevented
        // the call in the UI; here we confirm the controller agrees).
        let otherToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9031)
        #expect(controller.assignWindowToScratchpad(token: otherToken) == .notFound)
    }

    @Test @MainActor func moveTargetsExcludeCurrentWorkspace() throws {
        // The *Move to Workspace ▸* submenu must not offer the window's own
        // workspace. Verify the same helper used by the view's scoped actions
        // removes the current workspace while preserving the other workspace.
        let monitor = makeLayoutPlanTestMonitor(displayId: 904)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspaces for move-targets fixture")
            return
        }

        addLayoutPlanTestWindow(on: controller, workspaceId: workspace1, windowId: 9040)
        addLayoutPlanTestWindow(on: controller, workspaceId: workspace2, windowId: 9041)

        let manager = WorkspaceBarManager()
        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRightClickPanelFactory()

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let snapshot = try #require(manager.snapshotForTests(on: monitor.id))
        let moveTargets = snapshot.items.map { item in
            WorkspaceBarWindowMoveTarget(id: item.id, name: item.name)
        }
        let filteredTargets = workspaceBarMoveTargetsExcludingCurrentWorkspace(
            moveTargets,
            currentWorkspaceId: workspace1
        )
        let filteredIds = Set(filteredTargets.map(\.id))

        #expect(!filteredIds.contains(workspace1))
        #expect(filteredIds.contains(workspace2))
    }
}

@MainActor
private func syncNiriWorkspaceStateForRightClickTests(
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
private func makeRightClickPanelFactory() -> @MainActor @Sendable () -> WorkspaceBarPanel {
    {
        let panel = WorkspaceBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        return panel
    }
}
