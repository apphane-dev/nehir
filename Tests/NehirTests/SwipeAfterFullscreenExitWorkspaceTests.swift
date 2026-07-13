// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import ApplicationServices
@testable import Nehir
import Testing

/// Regression coverage for "swipe after fullscreen video exit lands on the wrong
/// workspace".
///
/// Two workspaces of one display each host a window of the *same* app. A video
/// plays fullscreen on the active workspace. When it exits, macOS re-homes
/// keyboard focus to the app's *other* window on the inactive workspace and
/// delivers it as an external `focusedWindowChanged`. Honoring it switches the
/// active workspace to the inactive one, so a following swipe scrolls the wrong
/// workspace. The fix suppresses that re-home while the app's managed border
/// target still sits on the active workspace, within the same-app teardown grace.
@MainActor
struct SwipeAfterFullscreenExitWorkspaceTests {
    @Test @MainActor
    func externalSameAppRehomeAfterFullscreenTeardownKeepsActiveWorkspace() {
        let controller = makeLayoutPlanTestController()
        controller.hasStartedServices = true
        controller.setBordersEnabled(true)
        defer { controller.axEventHandler.resetDebugStateForTests() }

        guard let videoWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let otherWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let monitorId = controller.workspaceManager.monitorId(for: videoWorkspaceId)
        else {
            Issue.record("Missing workspace fixture")
            return
        }

        let appPid: pid_t = 16_913
        let videoToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: videoWorkspaceId,
            windowId: 47_748,
            pid: appPid
        )
        let otherToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: otherWorkspaceId,
            windowId: 47_139,
            pid: appPid
        )

        // The video's workspace is active; the video window is the app's managed
        // border target. Confirmed managed focus is intentionally left unset — the
        // teardown clears it in the real bug, which is why the guard must anchor on
        // the durable border target instead.
        #expect(controller.workspaceManager.setActiveWorkspace(videoWorkspaceId, on: monitorId))
        confirmFocusedBorderForLayoutPlanTests(on: controller, token: videoToken)
        #expect(controller.currentBorderTarget()?.token == videoToken)

        // Drive the real native-fullscreen suspend path for the video so the
        // same-app teardown signal is recorded by production code (not seeded by
        // the test). This keeps the video entry and its border target intact.
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            pid == appPid ? AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: videoToken.windowId) : nil
        }
        controller.axEventHandler.isFullscreenProvider = { _ in true }
        controller.axEventHandler.handleAppActivation(
            pid: appPid,
            source: .workspaceDidActivateApplication,
            origin: .external
        )
        #expect(controller.currentBorderTarget()?.token == videoToken)
        #expect(controller.workspaceManager.activeWorkspace(on: monitorId)?.id == videoWorkspaceId)

        // macOS re-homes keyboard focus to the app's other window on the inactive
        // workspace and delivers it as an external focusedWindowChanged.
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            pid == appPid ? AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: otherToken.windowId) : nil
        }
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.axEventHandler.handleAppActivation(
            pid: appPid,
            source: .focusedWindowChanged,
            origin: .external
        )

        // The active workspace must stay on the video's workspace — not jump to the
        // inactive one the re-home pointed at.
        #expect(controller.workspaceManager.activeWorkspace(on: monitorId)?.id == videoWorkspaceId)
        #expect(controller.workspaceManager.activeWorkspace(on: monitorId)?.id != otherWorkspaceId)
        #expect(controller.currentBorderTarget()?.token == videoToken)
    }
}
