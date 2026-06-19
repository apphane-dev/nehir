import ApplicationServices
import CoreGraphics
import Foundation
@testable import Nehir
import Testing

private func axManagerTestWriteResult(
    targetFrame: CGRect,
    currentFrameHint: CGRect?,
    observedFrame: CGRect?,
    failureReason: AXFrameWriteFailureReason?
) -> AXFrameWriteResult {
    AXFrameWriteResult(
        targetFrame: targetFrame,
        observedFrame: observedFrame,
        writeOrder: AXWindowService.frameWriteOrder(
            currentFrame: currentFrameHint,
            targetFrame: targetFrame
        ),
        sizeError: .success,
        positionError: .success,
        failureReason: failureReason
    )
}

@Suite(.serialized) struct AXManagerTests {
    @Test func observedTargetFrameConfirmsApplyResultDespiteAttributeWriteFailure() {
        let targetFrame = CGRect(x: 120, y: 90, width: 640, height: 420)
        let result = AXFrameApplyResult(
            pid: 910,
            windowId: 910,
            targetFrame: targetFrame,
            currentFrameHint: nil,
            writeResult: axManagerTestWriteResult(
                targetFrame: targetFrame,
                currentFrameHint: nil,
                observedFrame: targetFrame,
                failureReason: .sizeWriteFailed(.attributeUnsupported)
            )
        )

        #expect(result.confirmedFrame == targetFrame)
    }

    @Test @MainActor func failedWriteRetriesOnceAndPromotesConfirmedFrameAfterSuccess() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager retry test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 910)
        let targetFrame = CGRect(x: 140, y: 88, width: 960, height: 620)

        var attemptCount = 0
        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                let writeResult = if attemptCount == 1 {
                    axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: .cacheMiss
                    )
                } else {
                    axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                }

                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: writeResult
                )
            }
        }

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        let observedTerminalResult = await waitForConditionForTests {
            observerResults.count == 1
        }

        #expect(attemptCount == 2)
        #expect(observedTerminalResult)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.confirmedFrame == targetFrame)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == targetFrame)
    }

    @Test @MainActor func terminalObserverFiresOnceAfterRetriesExhaustOnFailure() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager terminal failure test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 911)
        let targetFrame = CGRect(x: 200, y: 120, width: 840, height: 540)

        var attemptCount = 0
        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                let failureReason: AXFrameWriteFailureReason = if attemptCount == 1 {
                    .cacheMiss
                } else {
                    .verificationMismatch
                }
                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: failureReason
                    )
                )
            }
        }

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        let observedTerminalResult = await waitForConditionForTests {
            observerResults.count == 1
        }

        #expect(observedTerminalResult)
        #expect(attemptCount == 2)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.writeResult.failureReason == .verificationMismatch)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == .verificationMismatch)
    }

    @Test @MainActor func shouldSuppressFrameChangeRelayoutAfterRecentFrameWriteFailure() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for P4 suppression test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 913)
        let targetFrame = CGRect(x: 200, y: 120, width: 840, height: 540)

        var attemptCount = 0
        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                let failureReason: AXFrameWriteFailureReason = if attemptCount == 1 {
                    .cacheMiss
                } else {
                    .verificationMismatch
                }
                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: failureReason
                    )
                )
            }
        }

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        let observedTerminalResult = await waitForConditionForTests {
            observerResults.count == 1
        }

        #expect(observedTerminalResult)
        #expect(observerResults.first?.writeResult.failureReason == .verificationMismatch)

        // Post-failure state: no pending write, no confirmed last-applied frame, failure recorded.
        #expect(controller.axManager.pendingFrameWrite(for: token.windowId) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == .verificationMismatch)

        // The app's snap-back notification must be suppressed for any observed frame (or none),
        // breaking the snap-back -> relayout -> re-enqueue loop.
        let unrelatedObservedFrame = CGRect(x: 10, y: 10, width: 10, height: 10)
        #expect(controller.axManager.shouldSuppressFrameChangeRelayout(for: token.windowId, observedFrame: unrelatedObservedFrame))
        #expect(controller.axManager.shouldSuppressFrameChangeRelayout(for: token.windowId, observedFrame: nil))
    }

    @Test @MainActor func frameChangeRelayoutSuppressionEndsAfterEnqueueClearsFailure() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for P4 bounded-clearing test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 914)
        let failedTargetFrame = CGRect(x: 200, y: 120, width: 840, height: 540)

        var attemptCount = 0
        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                let failureReason: AXFrameWriteFailureReason = if attemptCount == 1 {
                    .cacheMiss
                } else {
                    .verificationMismatch
                }
                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: failureReason
                    )
                )
            }
        }

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, failedTargetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        let observedTerminalResult = await waitForConditionForTests {
            observerResults.count == 1
        }
        #expect(observedTerminalResult)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == .verificationMismatch)

        // Swap to a success override and enqueue a fresh target. The enqueue path clears the
        // failure flag, bounding the suppression window to the failed-write period.
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                )
            }
        }

        var secondObserverResults: [AXFrameApplyResult] = []
        let freshTargetFrame = CGRect(x: 300, y: 200, width: 1000, height: 700)
        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, freshTargetFrame)],
            terminalObserver: { secondObserverResults.append($0) }
        )

        let observedSecondResult = await waitForConditionForTests {
            secondObserverResults.count == 1
        }
        #expect(observedSecondResult)

        // The failure flag is cleared on enqueue and the fresh write confirmed.
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == freshTargetFrame)

        // Suppression no longer applies to an unrelated observed frame.
        let unrelatedObservedFrame = CGRect(x: 10, y: 10, width: 10, height: 10)
        #expect(controller.axManager.shouldSuppressFrameChangeRelayout(for: token.windowId, observedFrame: unrelatedObservedFrame) == false)
    }

    @Test @MainActor func terminalObserverCompletesImmediatelyWhenTargetFrameAlreadyCached() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager cached-frame observer test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 912)
        let targetFrame = CGRect(x: 160, y: 96, width: 900, height: 580)

        var attemptCount = 0
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                )
            }
        }

        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])

        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        #expect(attemptCount == 1)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.confirmedFrame == targetFrame)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == targetFrame)
    }

    @Test @MainActor func laterTrackedWriteDoesNotConsumeSupersededObserver() async throws {
        await withAppAXContextIsolationForTests {
            await withAXFrameProviderIsolationForTests {
                let controller = makeLayoutPlanTestController()
                guard let monitor = controller.workspaceManager.monitors.first,
                      let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
                else {
                    Issue.record("Missing monitor or active workspace for AXManager observer scoping test")
                    return
                }

                let token = addLayoutPlanTestWindow(
                    on: controller,
                    workspaceId: workspaceId,
                    windowId: 913,
                    pid: 9_913
                )

                let firstFrame = CGRect(x: 180, y: 100, width: 880, height: 560)
                let secondFrame = CGRect(x: 260, y: 140, width: 760, height: 500)
                let startedFirstWrite = DispatchSemaphore(value: 0)
                let releaseFirstWrite = DispatchSemaphore(value: 0)
                let startedSecondWrite = DispatchSemaphore(value: 0)
                let releaseSecondWrite = DispatchSemaphore(value: 0)

                controller.axManager.frameApplyAsyncOverrideForTests = { requests, complete in
                    Task { @MainActor in
                        let results = requests.map { request in
                            AXFrameApplyResult(
                                requestId: request.requestId,
                                pid: request.pid,
                                windowId: request.windowId,
                                targetFrame: request.frame,
                                currentFrameHint: request.currentFrameHint,
                                writeResult: axManagerTestWriteResult(
                                    targetFrame: request.frame,
                                    currentFrameHint: request.currentFrameHint,
                                    observedFrame: request.frame,
                                    failureReason: nil
                                )
                            )
                        }

                        if requests.contains(where: { $0.frame == firstFrame }) {
                            startedFirstWrite.signal()
                            _ = await Task.detached {
                                waitForSemaphoreForTests(releaseFirstWrite, timeout: .now() + 5)
                            }.value
                        }
                        if requests.contains(where: { $0.frame == secondFrame }) {
                            startedSecondWrite.signal()
                            _ = await Task.detached {
                                waitForSemaphoreForTests(releaseSecondWrite, timeout: .now() + 5)
                            }.value
                        }

                        complete(results)
                    }
                }
                defer {
                    controller.axManager.frameApplyAsyncOverrideForTests = nil
                }

                var firstObserverResults: [AXFrameApplyResult] = []
                var secondObserverResults: [AXFrameApplyResult] = []

                controller.axManager.applyFramesParallel(
                    [(token.pid, token.windowId, firstFrame)],
                    terminalObserver: { firstObserverResults.append($0) }
                )

                let sawFirstStart = await Task.detached {
                    waitForSemaphoreForTests(startedFirstWrite, timeout: .now() + 5) == .success
                }.value
                #expect(sawFirstStart)

                controller.axManager.applyFramesParallel(
                    [(token.pid, token.windowId, secondFrame)],
                    terminalObserver: { secondObserverResults.append($0) }
                )

                releaseFirstWrite.signal()

                let sawSecondStart = await Task.detached {
                    waitForSemaphoreForTests(startedSecondWrite, timeout: .now() + 5) == .success
                }.value
                #expect(sawSecondStart)

                releaseSecondWrite.signal()

                let observedSecondTerminalResult = await waitForConditionForTests {
                    secondObserverResults.count == 1
                }

                #expect(observedSecondTerminalResult)
                #expect(firstObserverResults.isEmpty)
                #expect(secondObserverResults.count == 1)
                #expect(secondObserverResults.first?.targetFrame == secondFrame)
                #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == secondFrame)
            }
        }
    }

    @Test @MainActor func removeWindowStateClearsFrameStateAndCancelsPendingObserver() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager removal cleanup test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 914)
        let targetFrame = CGRect(x: 220, y: 140, width: 760, height: 500)

        controller.axManager.frameApplyOverrideForTests = { _ in [] }
        defer { controller.axManager.frameApplyOverrideForTests = nil }

        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )
        controller.axManager.markWindowInactive(token.windowId)
        controller.axManager.forceApplyNextFrame(for: token.windowId)

        let before = controller.axManager.windowStateDebugSnapshot()
        #expect(before.pendingFrameWriteCount == 1)
        #expect(before.retryBudgetCount == 1)
        #expect(before.forceApplyWindowIdCount == 1)
        #expect(before.pendingFrameObserverCount == 1)
        #expect(before.observerRequestIdCount == 1)
        #expect(before.inactiveWorkspaceWindowIdCount == 1)

        controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)

        #expect(observerResults.count == 1)
        #expect(observerResults.first?.writeResult.failureReason == .cancelled)

        let after = controller.axManager.windowStateDebugSnapshot()
        #expect(after.lastAppliedFrameCount == 0)
        #expect(after.pendingFrameWriteCount == 0)
        #expect(after.recentFrameWriteFailureCount == 0)
        #expect(after.retryBudgetCount == 0)
        #expect(after.forceApplyWindowIdCount == 0)
        #expect(after.pendingFrameObserverCount == 0)
        #expect(after.observerRequestIdCount == 0)
        #expect(after.rekeyedWindowIdCount == 0)
        #expect(after.inactiveWorkspaceWindowIdCount == 0)
    }

    @Test @MainActor func oldWindowRemovalKeepsRekeyMappingForLateFrameResult() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager rekey cleanup test")
            return
        }

        let oldToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 915)
        let newWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 916)
        let targetFrame = CGRect(x: 240, y: 160, width: 720, height: 480)
        var didRekeyAndRemoveOldState = false

        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                if !didRekeyAndRemoveOldState {
                    didRekeyAndRemoveOldState = true
                    controller.axManager.rekeyWindowState(
                        pid: oldToken.pid,
                        oldWindowId: oldToken.windowId,
                        newWindow: newWindow
                    )
                    controller.axManager.removeWindowState(pid: oldToken.pid, windowId: oldToken.windowId)
                }
                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: oldToken.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                )
            }
        }
        defer { controller.axManager.frameApplyOverrideForTests = nil }

        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.applyFramesParallel(
            [(oldToken.pid, oldToken.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        #expect(didRekeyAndRemoveOldState)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.windowId == newWindow.windowId)
        #expect(controller.axManager.lastAppliedFrame(for: newWindow.windowId) == targetFrame)
        #expect(controller.axManager.windowStateDebugSnapshot().rekeyedWindowIdCount == 0)
    }

    @Test @MainActor func oldWindowRemovalDropsRekeyMappingWhenOnlyForceApplyMoved() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager force apply rekey test")
            return
        }

        let oldToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 917)
        let newWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 918)

        controller.axManager.forceApplyNextFrame(for: oldToken.windowId)
        controller.axManager.rekeyWindowState(pid: oldToken.pid, oldWindowId: oldToken.windowId, newWindow: newWindow)
        controller.axManager.removeWindowState(pid: oldToken.pid, windowId: oldToken.windowId)

        let snapshot = controller.axManager.windowStateDebugSnapshot()
        #expect(snapshot.rekeyedWindowIdCount == 0)
        #expect(snapshot.forceApplyWindowIdCount == 1)
    }
}
