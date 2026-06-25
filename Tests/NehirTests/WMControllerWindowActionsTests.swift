// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir
import Testing

/// Mirrors the file-private niri sync helper in WorkspaceNavigationHandlerTests:
/// inserts each workspace's windows into the engine and reconciles selection.
@MainActor
private func syncNiriWorkspaceState(
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

/// Token-target semantics for the workspace-bar right-click action family
/// (plan #18 Phase 1). These exercise the load-bearing refactor: the
/// per-window actions must act on the *passed* token, not the focused window
/// (the #8 defect). Mirrors the assertion style of `WMControllerScratchpadTests`.
@Suite(.serialized) struct WMControllerWindowActionsTests {
    // MARK: - Toggle Floating

    @Test @MainActor func toggleWindowFloatingActsOnExplicitTokenNotFocus() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for toggle-floating test")
            return
        }

        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 801)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 802)

        // Focus window A; act on window B's token. B (not A) must toggle.
        _ = controller.workspaceManager.setManagedFocus(tokenA, in: workspaceId, onMonitor: monitor.id)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == tokenA)
        #expect(controller.workspaceManager.windowMode(for: tokenB) == .tiling)

        let result = controller.toggleWindowFloating(token: tokenB)
        #expect(result == .executed)

        // B flipped to floating; A untouched.
        #expect(controller.workspaceManager.windowMode(for: tokenB) == .floating)
        #expect(controller.workspaceManager.manualLayoutOverride(for: tokenB) == .forceFloat)
        #expect(controller.workspaceManager.windowMode(for: tokenA) == .tiling)
        #expect(controller.workspaceManager.manualLayoutOverride(for: tokenA) == nil)
        // Focus did not move to B.
        #expect(controller.workspaceManager.confirmedManagedFocusToken == tokenA)
    }

    @Test @MainActor func toggleWindowFloatingReturnsNotFoundForUnknownToken() {
        let controller = makeLayoutPlanTestController()
        let unknownToken = WindowToken(pid: 99_999, windowId: 99_999)
        #expect(controller.toggleWindowFloating(token: unknownToken) == .notFound)
    }

    @Test @MainActor func toggleFocusedWindowFloatingStillTargetsFocusAfterRefactor() {
        // No-regression: the focused wrapper delegates to the same body and
        // still targets the focused token.
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for focused-toggle test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 803)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        #expect(controller.toggleFocusedWindowFloating() == .executed)
        #expect(controller.workspaceManager.windowMode(for: token) == .floating)
        #expect(controller.workspaceManager.manualLayoutOverride(for: token) == .forceFloat)
    }

    // MARK: - Assign / Unassign Scratchpad

    @Test @MainActor func assignWindowToScratchpadActsOnExplicitToken() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for assign test")
            return
        }

        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 811)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 812)
        controller.axManager.applyFramesParallel([(
            tokenB.pid,
            tokenB.windowId,
            CGRect(x: 140, y: 120, width: 760, height: 520)
        )])

        // Focus A; assign B. B becomes the scratchpad; A unchanged.
        _ = controller.workspaceManager.setManagedFocus(tokenA, in: workspaceId, onMonitor: monitor.id)

        #expect(controller.assignWindowToScratchpad(token: tokenB) == .executed)
        #expect(controller.workspaceManager.scratchpadToken() == tokenB)
        #expect(controller.workspaceManager.windowMode(for: tokenB) == .floating)
        #expect(controller.workspaceManager.hiddenState(for: tokenB)?.isScratchpad == true)
        // Focused window A is untouched.
        #expect(controller.workspaceManager.windowMode(for: tokenA) == .tiling)
        #expect(controller.workspaceManager.hiddenState(for: tokenA) == nil)
    }

    @Test @MainActor func unassignWindowFromScratchpadActsOnExplicitToken() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for unassign test")
            return
        }

        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 821)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 822)
        controller.axManager.applyFramesParallel([(
            tokenB.pid,
            tokenB.windowId,
            CGRect(x: 160, y: 130, width: 720, height: 500)
        )])

        _ = controller.assignWindowToScratchpad(token: tokenB)
        #expect(controller.workspaceManager.scratchpadToken() == tokenB)

        // Reveal the scratchpad before unassigning (matches the scratchpad-pill
        // right-click UX: the pill is right-clicked while the app is shown).
        controller.toggleScratchpadWindow()
        await waitForLayoutPlanRefreshWork(on: controller)
        #expect(controller.workspaceManager.hiddenState(for: tokenB) == nil)

        // Focus A; unassign B. B is cleaned up and force-tiled; A untouched.
        _ = controller.workspaceManager.setManagedFocus(tokenA, in: workspaceId, onMonitor: monitor.id)

        #expect(controller.unassignWindowFromScratchpad(token: tokenB) == .executed)
        #expect(controller.workspaceManager.scratchpadToken() == nil)
        #expect(controller.workspaceManager.hiddenState(for: tokenB) == nil)
        #expect(controller.workspaceManager.windowMode(for: tokenB) == .tiling)
        #expect(controller.workspaceManager.manualLayoutOverride(for: tokenB) == .forceTile)
        #expect(controller.workspaceManager.windowMode(for: tokenA) == .tiling)
        #expect(controller.workspaceManager.manualLayoutOverride(for: tokenA) == nil)
    }

    @Test @MainActor func unassignWindowFromScratchpadReturnsNotFoundForNonScratchpadToken() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for unassign-reject test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 823)
        // token is not the scratchpad → unassign is a no-op.
        #expect(controller.unassignWindowFromScratchpad(token: token) == .notFound)
        #expect(controller.workspaceManager.windowMode(for: token) == .tiling)
    }

    @Test @MainActor func assignWindowToScratchpadReturnsNotFoundWhenSlotOccupied() {
        // Single-slot collision (#7): a second assignment must return .notFound
        // so the right-click menu item disables rather than silently no-op'ing.
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for collision test")
            return
        }

        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 831)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 832)
        controller.axManager.applyFramesParallel([(
            tokenA.pid,
            tokenA.windowId,
            CGRect(x: 140, y: 120, width: 760, height: 520)
        )])
        controller.axManager.applyFramesParallel([(
            tokenB.pid,
            tokenB.windowId,
            CGRect(x: 980, y: 120, width: 760, height: 520)
        )])

        #expect(controller.assignWindowToScratchpad(token: tokenA) == .executed)
        #expect(controller.workspaceManager.scratchpadToken() == tokenA)

        // Slot is occupied by A → assigning B is rejected.
        #expect(controller.assignWindowToScratchpad(token: tokenB) == .notFound)
        #expect(controller.workspaceManager.scratchpadToken() == tokenA)
        #expect(controller.workspaceManager.hiddenState(for: tokenB) == nil)
        #expect(controller.workspaceManager.windowMode(for: tokenB) == .tiling)
    }

    // MARK: - Close

    @Test @MainActor func closeWindowFromBarTargetsExplicitToken() {
        // The close path resolves the passed token's entry directly (not from
        // focus). A known token returns .executed; an unknown one .notFound.
        // Focus is irrelevant to resolution.
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for close test")
            return
        }

        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 841)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 842)

        // Focus A; close B's token. B resolves (not A's focus), and the entry
        // for B exists so the close path is reachable.
        _ = controller.workspaceManager.setManagedFocus(tokenA, in: workspaceId, onMonitor: monitor.id)
        var closedTokens: [WindowToken] = []
        controller.windowActionHandler.closeWindowForTests = { handle in
            closedTokens.append(handle.id)
        }

        #expect(controller.closeWindowFromBar(token: tokenB) == .executed)
        #expect(closedTokens == [tokenB])

        // Unknown token → notFound and no extra close action.
        let unknownToken = WindowToken(pid: 99_998, windowId: 99_998)
        #expect(controller.closeWindowFromBar(token: unknownToken) == .notFound)
        #expect(closedTokens == [tokenB])
    }

    // MARK: - Move to Workspace

    @Test @MainActor func moveWindowFromBarTargetsExplicitToken() async {
        // The passed token is moved to the target workspace via
        // moveWindow(handle:toWorkspaceId:), independent of focus. Requires the
        // niri engine to be enabled and synced (same setup the navigation
        // handler move tests use).
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing monitor or workspaces for move test")
            return
        }

        controller.enableNiriLayout()
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: workspace1, windowId: 851)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: workspace1, windowId: 852)
        syncNiriWorkspaceState(on: controller, workspaceIds: [workspace1, workspace2])

        // Focus A; move B to workspace 2. B (not A) moves.
        _ = controller.workspaceManager.setManagedFocus(tokenA, in: workspace1, onMonitor: monitor.id)
        syncNiriWorkspaceState(on: controller, workspaceIds: [workspace1, workspace2])

        let result = controller.moveWindowFromBar(token: tokenB, toWorkspaceId: workspace2)
        await waitForLayoutPlanRefreshWork(on: controller)
        #expect(result == .executed)
        #expect(controller.workspaceManager.workspace(for: tokenB) == workspace2)
        // A stays in workspace 1.
        #expect(controller.workspaceManager.workspace(for: tokenA) == workspace1)
    }

    @Test @MainActor func moveWindowFromBarReturnsNotFoundForUnknownToken() {
        let controller = makeLayoutPlanTestController()
        guard let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false) else {
            Issue.record("Missing workspace for move-unknown test")
            return
        }
        let unknownToken = WindowToken(pid: 99_997, windowId: 99_997)
        #expect(controller.moveWindowFromBar(token: unknownToken, toWorkspaceId: workspace1) == .notFound)
    }
}
