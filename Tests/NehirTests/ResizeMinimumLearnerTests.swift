import CoreGraphics
import Foundation
import Testing
@testable import Nehir

/// Characterization tests for the resize-minimum learner (M1, Gap B).
///
/// Nehir already implements the refused-frame -> inferred-minimum -> solver-constraint
/// feedback loop upstream `40934c5` introduced; these tests pin the parts that had zero
/// coverage. See `planned/20260619-m1-refused-frame-feedback-characterization.md`.
@MainActor
@Suite
struct ResizeMinimumLearnerTests {

    // MARK: - Learner loop (Gap B #2/#3)
    //
    // These drive `handleResizeMinimumFrameApplyResult` directly with a synthetic
    // `AXFrameApplyResult`, bypassing the real racy AX readback. This tests the
    // learner *logic* deterministically (pin vs absorb); the readback-race residual
    // is only mitigated by deferred Gap E, not eliminated.

    private func learnerMismatchResult(
        pid: pid_t,
        windowId: Int,
        targetFrame: CGRect,
        observedFrame: CGRect
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: 0,
            pid: pid,
            windowId: windowId,
            targetFrame: targetFrame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                targetFrame: targetFrame,
                observedFrame: observedFrame,
                writeOrder: AXWindowService.frameWriteOrder(
                    currentFrame: nil,
                    targetFrame: targetFrame
                ),
                sizeError: .success,
                positionError: .success,
                failureReason: .verificationMismatch
            )
        )
    }

    /// Gap B #2 — A verificationMismatch that overshoots PAST the 32pt cell-
    /// quantization threshold pins an inferred minimum >= the observed size.
    /// This is the genuine-refusal path (the app clamped a too-small frame back
    /// to its real minimum), not grid-snapping.
    @Test func oversizedVerificationMismatchPinsInferredMinimum() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace for learner-pin test")
            return
        }

        let windowId = 5301
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        #expect(controller.workspaceManager.layoutReason(for: token) == .standard)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.workspaceManager.inferredResizeMinimumSize(for: token) == nil)

        // Target 400x300; app clamps back to 400x400 — a 100pt height overshoot,
        // far past the 32pt quantization threshold, so the learner (not the quant
        // branch) runs.
        let targetFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let observedFrame = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(!LayoutRefreshController.isCellQuantizationOvershoot(target: targetFrame, observed: observedFrame))

        let result = learnerMismatchResult(
            pid: token.pid,
            windowId: windowId,
            targetFrame: targetFrame,
            observedFrame: observedFrame
        )
        controller.layoutRefreshController.handleResizeMinimumFrameApplyResult(result, workspaceId: workspaceId)

        let pinned = controller.workspaceManager.inferredResizeMinimumSize(for: token)
        #expect(pinned != nil)
        #expect(pinned!.height >= observedFrame.height)
        #expect(pinned!.width >= observedFrame.width)
    }

    /// Gap B #3 — A verificationMismatch whose overshoot is WITHIN the 32pt cell-
    /// quantization threshold is absorbed as grid-snapping and does NOT pin an
    /// inferred minimum. Doubles as the M2 rejection evidence: a learned per-window
    /// size quantum is unnecessary because grid-snap overshoot is already absorbed.
    @Test func cellQuantizationOvershootDoesNotPinInferredMinimum() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace for learner-quant test")
            return
        }

        let windowId = 5302
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        #expect(controller.workspaceManager.inferredResizeMinimumSize(for: token) == nil)

        // Target 400x300; terminal snaps to 400x320 — a 20pt height overshoot,
        // within the 32pt threshold on every component, so it is recognized as
        // cell quantization and absorbed, not pinned.
        let targetFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let observedFrame = CGRect(x: 0, y: 0, width: 400, height: 320)
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(target: targetFrame, observed: observedFrame))

        let result = learnerMismatchResult(
            pid: token.pid,
            windowId: windowId,
            targetFrame: targetFrame,
            observedFrame: observedFrame
        )
        controller.layoutRefreshController.handleResizeMinimumFrameApplyResult(result, workspaceId: workspaceId)

        #expect(controller.workspaceManager.inferredResizeMinimumSize(for: token) == nil)
    }

    // MARK: - Quantization detector boundary matrix (Gap B #1)

    /// Pure boundary matrix for `isCellQuantizationOvershoot`, locking the 32.0 pt
    /// threshold. Also serves as the M2 rejection evidence (a learned per-window size
    /// quantum is not needed: grid-snapping overshoot within one cell is already
    /// absorbed and never pinned as a minimum).
    @Test func isCellQuantizationOvershootBoundaryMatrix() {
        // target 100x100@(0,0) baseline
        let base = CGRect(x: 0, y: 0, width: 100, height: 100)

        // 1. Height overshoot within threshold -> true (terminal cell-row snap).
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 0, y: 0, width: 100, height: 112)) == true)

        // 2. Width overshoot within threshold (31pt) -> true.
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 0, y: 0, width: 131, height: 100)) == true)

        // 3. Width overshoot past threshold (33pt) -> false (genuine refusal).
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 0, y: 0, width: 133, height: 100)) == false)

        // 4. Pure shrink (no overshoot axis) -> false (handled by the inferred-min path).
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 0, y: 0, width: 90, height: 90)) == false)

        // 5. Pure origin shift (no size overshoot) -> false.
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 33, y: 0, width: 100, height: 100)) == false)

        // 6. Origin shift + height overshoot, both within threshold -> true.
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 12, y: 0, width: 100, height: 112)) == true)

        // 7. Both axes overshoot within threshold -> true.
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 0, y: 0, width: 120, height: 120)) == true)

        // 8. Overshoot present but origin shift past threshold -> false (origin clamps).
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 40, y: 0, width: 100, height: 112)) == false)

        // Threshold boundary itself: exactly 32pt height overshoot is accepted (<=),
        // 33pt is rejected — pins the 32.0 constant.
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 0, y: 0, width: 100, height: 132)) == true)
        #expect(LayoutRefreshController.isCellQuantizationOvershoot(
            target: base, observed: CGRect(x: 0, y: 0, width: 100, height: 133)) == false)
    }
}
