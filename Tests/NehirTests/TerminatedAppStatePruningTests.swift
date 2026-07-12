// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Darwin
@testable import Nehir
import Testing

@Suite(.serialized) @MainActor struct TerminatedAppStatePruningTests {
    @Test func terminationPrunesPidAndTokenKeyedFocusDiagnostics() throws {
        let controller = makeLayoutPlanTestController()
        let handler = controller.axEventHandler
        defer {
            handler.resetDebugStateForTests()
            resetSharedControllerStateForTests()
        }

        let workspaceId = try #require(controller.interactionWorkspace()?.id)
        let terminatedPID: pid_t = 51_001
        let survivingPID: pid_t = 51_002
        handler.seedFocusStateForTerminationPruningTests(
            pid: terminatedPID,
            workspaceId: workspaceId,
            windowId: 7001
        )
        handler.seedFocusStateForTerminationPruningTests(
            pid: survivingPID,
            workspaceId: workspaceId,
            windowId: 7002
        )
        handler.seedPendingStateForTerminationPruningTests(
            pid: terminatedPID,
            workspaceId: workspaceId,
            windowId: 7001
        )
        handler.seedPendingStateForTerminationPruningTests(
            pid: survivingPID,
            workspaceId: workspaceId,
            windowId: 7002
        )

        let before = handler.memoryDebugSnapshot()
        #expect(before.recentManagedWorkspaceByPidCount == 2)
        #expect(before.recentAppActivationByPidCount == 2)
        #expect(before.recentSameAppWindowCloseByPidCount == 2)
        #expect(before.recentNonManagedFocusByPidCount == 2)
        #expect(before.overlayCapablePidCount == 2)
        #expect(before.focusedWindowLossClosePrecursorByPidCount == 2)
        #expect(before.sameAppRecoveryRedirectLatchCount == 2)
        #expect(before.recentParkedFocusFollowByTokenCount == 2)
        #expect(before.parkedFollowHoldByPidCount == 2)
        #expect(before.recentManagedAdmissionByTokenCount == 2)
        #expect(before.pendingManagedReplacementBurstCount == 2)
        #expect(before.pendingManagedReplacementTaskCount == 2)
        #expect(before.deferredInactiveNativeActivationTokenCount == 2)
        #expect(before.deferredSameAppActiveNativeActivationTokenCount == 2)
        #expect(before.pendingNativeFullscreenFollowupTaskCount == 2)
        #expect(before.pendingNativeFullscreenStaleCleanupTaskCount == 2)
        #expect(before.pendingWindowRuleReevaluationTaskCount == 1)
        #expect(before.pendingWindowRuleReevaluationTargetCount == 2)
        #expect(before.pendingWindowStabilizationTaskCount == 2)
        #expect(before.pendingPostCreateLifecycleVerificationTaskCount == 2)
        #expect(before.pendingDestroyLivenessVerificationTaskCount == 2)
        #expect(before.pendingCreatedWindowRetryTaskCount == 2)
        #expect(before.createdWindowRetryCount == 2)

        handler.cleanupFocusStateForTerminatedApp(pid: terminatedPID)

        let after = handler.memoryDebugSnapshot()
        #expect(after.recentManagedWorkspaceByPidCount == 1)
        #expect(after.recentAppActivationByPidCount == 1)
        #expect(after.recentSameAppWindowCloseByPidCount == 1)
        #expect(after.recentNonManagedFocusByPidCount == 1)
        #expect(after.overlayCapablePidCount == 1)
        #expect(after.focusedWindowLossClosePrecursorByPidCount == 1)
        #expect(after.sameAppRecoveryRedirectLatchCount == 1)
        #expect(after.recentParkedFocusFollowByTokenCount == 1)
        #expect(after.parkedFollowHoldByPidCount == 1)
        #expect(after.recentManagedAdmissionByTokenCount == 1)
        #expect(after.pendingManagedReplacementBurstCount == 1)
        #expect(after.pendingManagedReplacementTaskCount == 1)
        #expect(after.deferredInactiveNativeActivationTokenCount == 1)
        #expect(after.deferredSameAppActiveNativeActivationTokenCount == 1)
        #expect(after.pendingNativeFullscreenFollowupTaskCount == 1)
        #expect(after.pendingNativeFullscreenStaleCleanupTaskCount == 1)
        #expect(after.pendingWindowRuleReevaluationTaskCount == 1)
        #expect(after.pendingWindowRuleReevaluationTargetCount == 1)
        #expect(after.pendingWindowStabilizationTaskCount == 1)
        #expect(after.pendingPostCreateLifecycleVerificationTaskCount == 1)
        #expect(after.pendingDestroyLivenessVerificationTaskCount == 1)
        #expect(after.pendingCreatedWindowRetryTaskCount == 1)
        #expect(after.createdWindowRetryCount == 1)
    }
}
