// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
import Testing

/// Cross-workspace behavior for the "Focus Previous Window" command
/// (`HotkeyCommand.focusPrevious`, default Option-Tab).
///
/// These tests pin the fix for OmniWM #240: the command is a global MRU window
/// switcher (keywords "last focused" / "recent window"), so it must return to the
/// globally most-recently-focused window even when that window lives on a
/// different workspace — and, per the chosen policy, a different monitor.
@Suite(.serialized) @MainActor struct FocusPreviousCrossWorkspaceTests {
    /// Cross-workspace MRU returns to the origin window on a different workspace
    /// (same monitor). With C (oldest) < A < B (current), the global MRU excluding
    /// the current window B is A on workspace 1, so Option-Tab must switch back to
    /// workspace 1 and focus A — not C, and not a window on workspace 2.
    @Test @MainActor func crossWorkspaceMRUReturnsToOriginWindow() async {
        let fixture = makeFocusPreviousFixture(
            assignments: [
                (workspaceName: "1", windowId: 101), // A
                (workspaceName: "1", windowId: 103), // C
                (workspaceName: "2", windowId: 102) // B
            ]
        )
        let tokenA = fixture.tokens[101]!
        let tokenB = fixture.tokens[102]!
        let tokenC = fixture.tokens[103]!
        let ws1 = fixture.workspaceIds["1"]!
        let ws2 = fixture.workspaceIds["2"]!

        // MRU ordering: C (oldest) < A < B (newest). Current focus is B on ws2.
        setLastFocusedTime(tokenC, to: t(100), on: fixture.controller)
        setLastFocusedTime(tokenA, to: t(200), on: fixture.controller)
        setLastFocusedTime(tokenB, to: t(300), on: fixture.controller)
        focusWindowInFixture(tokenB, workspaceId: ws2, on: fixture.controller)

        #expect(fixture.controller.interactionWorkspace()?.id == ws2)

        fixture.controller.niriLayoutHandler.focusPrevious()
        await waitForRefreshWork(on: fixture.controller)

        // The command switched back to workspace 1 and focused A (the global MRU),
        // not C, and never stayed on workspace 2.
        #expect(fixture.controller.interactionWorkspace()?.id == ws1)
        #expect(fixture.controller.workspaceManager.activeFocusRequestToken == tokenA)
        #expect(selectedNodeId(for: ws1, on: fixture.controller) == nodeId(tokenA, on: fixture.controller))
    }

    /// Same-workspace MRU is unchanged: with both A and B on the current workspace,
    /// Option-Tab moves focus to A and stays on the same workspace.
    @Test @MainActor func sameWorkspaceMRUIsUnchanged() async {
        let fixture = makeFocusPreviousFixture(
            assignments: [
                (workspaceName: "1", windowId: 101), // A
                (workspaceName: "1", windowId: 102) // B
            ]
        )
        let tokenA = fixture.tokens[101]!
        let tokenB = fixture.tokens[102]!
        let ws1 = fixture.workspaceIds["1"]!

        setLastFocusedTime(tokenA, to: t(100), on: fixture.controller)
        setLastFocusedTime(tokenB, to: t(200), on: fixture.controller)
        focusWindowInFixture(tokenB, workspaceId: ws1, on: fixture.controller)

        #expect(fixture.controller.interactionWorkspace()?.id == ws1)

        fixture.controller.niriLayoutHandler.focusPrevious()
        await waitForRefreshWork(on: fixture.controller)

        // Still on workspace 1, now focused on A — the pre-existing per-workspace
        // MRU behavior is preserved.
        #expect(fixture.controller.interactionWorkspace()?.id == ws1)
        #expect(selectedNodeId(for: ws1, on: fixture.controller) == nodeId(tokenA, on: fixture.controller))
    }

    /// Single-window target workspace: workspace 2 has only B, so the legacy
    /// per-workspace search had no candidate and did nothing. The global search
    /// now finds A on workspace 1 and switches there.
    @Test @MainActor func singleWindowTargetWorkspaceSucceeds() async {
        let fixture = makeFocusPreviousFixture(
            assignments: [
                (workspaceName: "1", windowId: 101), // A
                (workspaceName: "2", windowId: 102) // B (only window on ws2)
            ]
        )
        let tokenA = fixture.tokens[101]!
        let tokenB = fixture.tokens[102]!
        let ws1 = fixture.workspaceIds["1"]!
        let ws2 = fixture.workspaceIds["2"]!

        setLastFocusedTime(tokenA, to: t(100), on: fixture.controller)
        setLastFocusedTime(tokenB, to: t(200), on: fixture.controller)
        focusWindowInFixture(tokenB, workspaceId: ws2, on: fixture.controller)

        #expect(fixture.controller.interactionWorkspace()?.id == ws2)

        fixture.controller.niriLayoutHandler.focusPrevious()
        await waitForRefreshWork(on: fixture.controller)

        #expect(fixture.controller.interactionWorkspace()?.id == ws1)
        #expect(fixture.controller.workspaceManager.activeFocusRequestToken == tokenA)
        #expect(selectedNodeId(for: ws1, on: fixture.controller) == nodeId(tokenA, on: fixture.controller))
    }

    /// Monitor policy (GLOBAL MRU): the target window lives on another monitor's
    /// workspace. Option-Tab is allowed to cross monitors — the interaction
    /// monitor follows the target window and focus lands on it.
    @Test @MainActor func globalMRUCrossesMonitorsToTargetWindow() async {
        let fixture = makeTwoMonitorFocusPreviousFixture()
        let tokenA = fixture.tokens[101]!
        let tokenB = fixture.tokens[102]!
        let ws1 = fixture.workspaceIds["1"]!
        let ws2 = fixture.workspaceIds["2"]!

        setLastFocusedTime(tokenA, to: t(100), on: fixture.controller)
        setLastFocusedTime(tokenB, to: t(200), on: fixture.controller)
        // Currently interacting with the secondary monitor / workspace 2 / B.
        focusWindowInFixture(
            tokenB,
            workspaceId: ws2,
            on: fixture.controller
        )

        #expect(fixture.controller.interactionWorkspace()?.id == ws2)
        #expect(
            fixture.controller.workspaceManager.interactionMonitorId
                == fixture.secondaryMonitor?.id
        )

        fixture.controller.niriLayoutHandler.focusPrevious()
        await waitForRefreshWork(on: fixture.controller)

        // Global MRU winner A is on workspace 1 / primary monitor. The interaction
        // monitor follows it there, and focus lands on A.
        #expect(fixture.controller.interactionWorkspace()?.id == ws1)
        #expect(
            fixture.controller.workspaceManager.interactionMonitorId
                == fixture.primaryMonitor.id
        )
        #expect(fixture.controller.workspaceManager.activeFocusRequestToken == tokenA)
    }
}

// MARK: - Fixture helpers

@MainActor private struct FocusPreviousFixture {
    let controller: WMController
    let tokens: [Int: WindowToken]
    let workspaceIds: [String: WorkspaceDescriptor.ID]
    let primaryMonitor: Monitor
    let secondaryMonitor: Monitor?
}

@MainActor
private func makeFocusPreviousFixture(
    assignments: [(workspaceName: String, windowId: Int)]
) -> FocusPreviousFixture {
    let controller = makeLayoutPlanTestController()
    controller.enableNiriLayout()
    controller.syncMonitorsToNiriEngine()

    var tokens: [Int: WindowToken] = [:]
    var workspaceIds: [String: WorkspaceDescriptor.ID] = [:]
    var tokensByWorkspace: [WorkspaceDescriptor.ID: [WindowToken]] = [:]

    for (workspaceName, windowId) in assignments {
        guard let workspaceId = controller.workspaceManager.workspaceId(
            for: workspaceName,
            createIfMissing: false
        ) else {
            fatalError("Missing workspace fixture: \(workspaceName)")
        }
        workspaceIds[workspaceName] = workspaceId
        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: windowId
        )
        tokens[windowId] = token
        tokensByWorkspace[workspaceId, default: []].append(token)
    }

    // Materialize engine nodes for each workspace so MRU lookups have candidates.
    if let engine = controller.niriEngine {
        for (workspaceId, wsTokens) in tokensByWorkspace {
            let selectedNodeId = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId
            _ = engine.syncWindows(wsTokens, in: workspaceId, selectedNodeId: selectedNodeId)
        }
    }

    let primaryMonitor = controller.workspaceManager.monitors.first!
    return FocusPreviousFixture(
        controller: controller,
        tokens: tokens,
        workspaceIds: workspaceIds,
        primaryMonitor: primaryMonitor,
        secondaryMonitor: nil
    )
}

@MainActor
private func makeTwoMonitorFocusPreviousFixture() -> FocusPreviousFixture {
    let primaryMonitor = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
    let secondaryMonitor = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
    let controller = makeLayoutPlanTestController(
        monitors: [primaryMonitor, secondaryMonitor],
        workspaceConfigurations: [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
    )
    controller.enableNiriLayout()
    controller.syncMonitorsToNiriEngine()

    guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
          let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
    else {
        fatalError("Failed to create two-monitor focus-previous fixture")
    }

    _ = controller.workspaceManager.setActiveWorkspace(ws1, on: primaryMonitor.id)
    _ = controller.workspaceManager.setActiveWorkspace(ws2, on: secondaryMonitor.id)
    _ = controller.workspaceManager.setInteractionMonitor(primaryMonitor.id)

    let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 101)
    let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: ws2, windowId: 102)

    if let engine = controller.niriEngine {
        _ = engine.syncWindows([tokenA], in: ws1, selectedNodeId: nil)
        _ = engine.syncWindows([tokenB], in: ws2, selectedNodeId: nil)
    }

    return FocusPreviousFixture(
        controller: controller,
        tokens: [101: tokenA, 102: tokenB],
        workspaceIds: ["1": ws1, "2": ws2],
        primaryMonitor: primaryMonitor,
        secondaryMonitor: secondaryMonitor
    )
}

/// Drives the fixture into "workspace `workspaceId` is active and `token` is the
/// focused/selected window" — the state `focusPrevious()` reads from.
@MainActor
private func focusWindowInFixture(
    _ token: WindowToken,
    workspaceId: WorkspaceDescriptor.ID,
    on controller: WMController
) {
    guard let monitorId = controller.workspaceManager.monitorForWorkspace(workspaceId)?.id,
          let nodeId = controller.niriEngine?.findNode(for: token)?.id
    else {
        fatalError("Missing monitor or engine node for focus-previous fixture setup")
    }
    _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitorId)
    _ = controller.workspaceManager.commitWorkspaceSelection(
        nodeId: nodeId,
        focusedToken: token,
        in: workspaceId
    )
    _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitorId)
}

@MainActor
private func setLastFocusedTime(
    _ token: WindowToken,
    to time: Date,
    on controller: WMController
) {
    guard let window = controller.niriEngine?.findNode(for: token) else {
        fatalError("Missing engine node for token \(token)")
    }
    window.lastFocusedTime = time
}

@MainActor
private func nodeId(
    _ token: WindowToken,
    on controller: WMController
) -> NodeId? {
    controller.niriEngine?.findNode(for: token)?.id
}

@MainActor
private func selectedNodeId(
    for workspaceId: WorkspaceDescriptor.ID,
    on controller: WMController
) -> NodeId? {
    controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId
}

@MainActor
private func waitForRefreshWork(on controller: WMController) async {
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
}

/// Deterministic timestamp helper so MRU ordering never depends on `Date()`
/// resolution.
private func t(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}
