import ApplicationServices
import CoreGraphics
import Foundation
@testable import Nehir
import Testing

private enum ScratchpadFocusOperationEvent: Equatable {
    case activate(pid_t)
    case focus(pid_t, UInt32)
    case raise
}

private final class ScratchpadFocusRecorder {
    var events: [ScratchpadFocusOperationEvent] = []
}

private func scratchpadTestWriteResult(
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

@MainActor
private func makeScratchpadFocusOperations(
    recorder: ScratchpadFocusRecorder
) -> WindowFocusOperations {
    WindowFocusOperations(
        activateApp: { pid in
            recorder.events.append(.activate(pid))
        },
        focusSpecificWindow: { pid, windowId, _ in
            recorder.events.append(.focus(pid, windowId))
        },
        raiseWindow: { _ in
            recorder.events.append(.raise)
        }
    )
}

@MainActor
private func setScratchpadTestFrame(
    on controller: WMController,
    token: WindowToken,
    frame: CGRect
) {
    controller.axManager.applyFramesParallel([(token.pid, token.windowId, frame)])
}

@Suite(.serialized) struct WMControllerScratchpadTests {
    @Test @MainActor func assignFocusedWindowToScratchpadHidesTiledWindowAndRejectsSecondAssignment() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad assignment test")
            return
        }

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 700)
        let secondToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 701)
        let firstFrame = CGRect(x: 140, y: 120, width: 760, height: 520)
        let secondFrame = CGRect(x: 980, y: 120, width: 760, height: 520)
        setScratchpadTestFrame(on: controller, token: firstToken, frame: firstFrame)
        setScratchpadTestFrame(on: controller, token: secondToken, frame: secondFrame)

        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)
        #expect(controller.assignFocusedWindowToScratchpad() == .executed)

        guard let scratchpadFloatingState = controller.workspaceManager.floatingState(for: firstToken) else {
            Issue.record("Expected scratchpad floating state")
            return
        }
        #expect(controller.workspaceManager.scratchpadToken() == firstToken)
        #expect(controller.workspaceManager.windowMode(for: firstToken) == .floating)
        #expect(controller.workspaceManager.hiddenState(for: firstToken)?.isScratchpad == true)
        #expect(scratchpadFloatingState.restoreToFloating)
        #expect(scratchpadFloatingState.referenceMonitorId == monitor.id)
        #expect(scratchpadFloatingState.lastFrame.width > 0)
        #expect(scratchpadFloatingState.lastFrame.height > 0)
        #expect(controller.workspaceManager.activeFocusRequestToken == secondToken)

        _ = controller.workspaceManager.setManagedFocus(secondToken, in: workspaceId, onMonitor: monitor.id)
        #expect(controller.assignFocusedWindowToScratchpad() == .notFound)

        #expect(controller.workspaceManager.scratchpadToken() == firstToken)
        #expect(controller.workspaceManager.hiddenState(for: secondToken) == nil)
        #expect(controller.workspaceManager.windowMode(for: secondToken) == .tiling)
    }

    @Test @MainActor func failedScratchpadAssignmentDoesNotLeaveManualFloatOverride() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad failure test")
            return
        }

        let scratchpadToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 703)
        let rejectedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 704)
        setScratchpadTestFrame(
            on: controller,
            token: scratchpadToken,
            frame: CGRect(x: 140, y: 120, width: 760, height: 520)
        )

        _ = controller.workspaceManager.setManagedFocus(scratchpadToken, in: workspaceId, onMonitor: monitor.id)
        #expect(controller.assignFocusedWindowToScratchpad() == .executed)
        #expect(controller.workspaceManager.scratchpadToken() == scratchpadToken)

        _ = controller.workspaceManager.setManagedFocus(rejectedToken, in: workspaceId, onMonitor: monitor.id)

        #expect(controller.assignFocusedWindowToScratchpad() == .notFound)
        #expect(controller.workspaceManager.scratchpadToken() == scratchpadToken)
        #expect(controller.workspaceManager.hiddenState(for: rejectedToken) == nil)
        #expect(controller.workspaceManager.manualLayoutOverride(for: rejectedToken) == nil)
        #expect(controller.workspaceManager.windowMode(for: rejectedToken) == .tiling)
    }

    @Test @MainActor func toggleScratchpadWindowRestoresAndRecapturesFloatingFrame() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad toggle test")
            return
        }

        let windowId = 71_010
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        let initialFrame = CGRect(x: 180, y: 140, width: 700, height: 460)
        setScratchpadTestFrame(on: controller, token: token, frame: initialFrame)

        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.assignFocusedWindowToScratchpad()
        controller.toggleScratchpadWindow()

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: windowId) == initialFrame)
        #expect(controller.workspaceManager.activeFocusRequestToken == token)

        let movedFrame = initialFrame.offsetBy(dx: 120, dy: 90)
        setScratchpadTestFrame(on: controller, token: token, frame: movedFrame)

        controller.toggleScratchpadWindow()
        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.workspaceManager.floatingState(for: token)?.lastFrame == movedFrame)

        controller.toggleScratchpadWindow()
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: windowId) == movedFrame)
    }

    @Test @MainActor func scratchpadVisibilityChangesRequestWorkspaceBarRefresh() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad refresh test")
            return
        }

        let windowId = 71_011
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        let frame = CGRect(x: 180, y: 140, width: 700, height: 460)
        setScratchpadTestFrame(on: controller, token: token, frame: frame)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        controller.assignFocusedWindowToScratchpad()
        #expect(controller.workspaceBarRefreshDebugState.requestCount > 0)

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        controller.toggleScratchpadWindow()
        #expect(controller.workspaceBarRefreshDebugState.requestCount > 0)

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        controller.toggleScratchpadWindow()
        #expect(controller.workspaceBarRefreshDebugState.requestCount > 0)
    }

    @Test @MainActor func appTerminationUnpinsHiddenScratchpadAXElement() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad app termination test")
            return
        }

        let pid: pid_t = 71_012
        let windowId = 71_012
        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: windowId,
            pid: pid
        )
        #expect(controller.workspaceManager.setScratchpadToken(token))
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: .zero,
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )
        AXWindowService.pinAXElement(AXUIElementCreateSystemWide(), for: UInt32(windowId))
        defer { AXWindowService.clearPinnedAXElementsForTests() }

        #expect(AXWindowService.hasPinnedAXElementForTests(for: UInt32(windowId)))

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onFullRescan = { _ in true }
        controller.serviceLifecycleManager.handleAppTerminated(pid: pid)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(!AXWindowService.hasPinnedAXElementForTests(for: UInt32(windowId)))
        #expect(controller.workspaceManager.scratchpadToken() == nil)
        #expect(controller.workspaceManager.entry(for: token) == nil)
    }

    @Test @MainActor func assignFocusedWindowToScratchpadClearsVisibleScratchpadSlotWhenRepeated() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad unassign test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 720)
        setScratchpadTestFrame(
            on: controller,
            token: token,
            frame: CGRect(x: 220, y: 180, width: 620, height: 420)
        )

        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.assignFocusedWindowToScratchpad()
        controller.toggleScratchpadWindow()
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        controller.assignFocusedWindowToScratchpad()

        #expect(controller.workspaceManager.scratchpadToken() == nil)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.workspaceManager.windowMode(for: token) == .tiling)
        #expect(controller.workspaceManager.manualLayoutOverride(for: token) == .forceTile)
    }

    @Test @MainActor func assignFocusedWindowToScratchpadUnassignsVisibleFloatingWindowBackToTiling() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for floating scratchpad unassign test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 725),
            pid: 725,
            windowId: 725,
            to: workspaceId,
            mode: .floating
        )
        let frame = CGRect(x: 260, y: 190, width: 540, height: 360)
        setScratchpadTestFrame(on: controller, token: token, frame: frame)

        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.assignFocusedWindowToScratchpad()
        controller.toggleScratchpadWindow()
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        controller.assignFocusedWindowToScratchpad()

        #expect(controller.workspaceManager.scratchpadToken() == nil)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.workspaceManager.windowMode(for: token) == .tiling)
        #expect(controller.workspaceManager.manualLayoutOverride(for: token) == .forceTile)
    }

    @Test @MainActor func toggleScratchpadWindowSummonsToCurrentWorkspaceAndMonitor() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller

        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 730
        )
        let initialFrame = CGRect(x: 180, y: 140, width: 640, height: 420)
        setScratchpadTestFrame(on: controller, token: token, frame: initialFrame)

        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )
        controller.assignFocusedWindowToScratchpad()
        _ = controller.workspaceManager.setInteractionMonitor(fixture.secondaryMonitor.id)

        guard let expectedFrame = controller.workspaceManager.resolvedFloatingFrame(
            for: token,
            preferredMonitor: fixture.secondaryMonitor
        ) else {
            Issue.record("Missing resolved floating frame for summoned scratchpad window")
            return
        }

        controller.toggleScratchpadWindow()

        #expect(controller.workspaceManager.workspace(for: token) == fixture.secondaryWorkspaceId)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 730) == expectedFrame)
        #expect(controller.workspaceManager.activeFocusRequestToken == token)
    }

    @Test @MainActor func toggleScratchpadWindowFrontsWindowOnlyAfterAsyncRevealSucceeds() async throws {
        await withAppAXContextIsolationForTests {
            await withAXFrameProviderIsolationForTests {
                let recorder = ScratchpadFocusRecorder()
                let fixture = makeTwoMonitorLayoutPlanTestController(
                    primaryMonitor: makeLayoutPlanPrimaryTestMonitor(name: "Primary"),
                    secondaryMonitor: makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920),
                    windowFocusOperations: makeScratchpadFocusOperations(recorder: recorder)
                )
                let controller = fixture.controller

                let token = addLayoutPlanTestWindow(
                    on: controller,
                    workspaceId: fixture.primaryWorkspaceId,
                    windowId: 731,
                    pid: 7_731
                )
                let visibleToken = addLayoutPlanTestWindow(
                    on: controller,
                    workspaceId: fixture.secondaryWorkspaceId,
                    windowId: 732,
                    pid: 7_732
                )
                let initialFrame = CGRect(x: 220, y: 160, width: 620, height: 400)
                setScratchpadTestFrame(on: controller, token: token, frame: initialFrame)

                _ = controller.workspaceManager.setManagedFocus(
                    token,
                    in: fixture.primaryWorkspaceId,
                    onMonitor: fixture.primaryMonitor.id
                )
                controller.assignFocusedWindowToScratchpad()
                _ = controller.workspaceManager.setManagedFocus(
                    visibleToken,
                    in: fixture.secondaryWorkspaceId,
                    onMonitor: fixture.secondaryMonitor.id
                )
                _ = controller.workspaceManager.setInteractionMonitor(fixture.secondaryMonitor.id)

                guard let expectedFrame = controller.workspaceManager.resolvedFloatingFrame(
                    for: token,
                    preferredMonitor: fixture.secondaryMonitor
                ) else {
                    Issue.record("Missing expected frame for async scratchpad focus test")
                    return
                }

                var pendingCompletion: (() -> Void)?
                let liveFrame = expectedFrame.offsetBy(dx: fixture.secondaryMonitor.frame.width + 80, dy: 0)
                AXWindowService.fastFrameProviderForTests = { window in
                    window.windowId == token.windowId ? liveFrame : fallbackFastFrameForTests(window)
                }
                controller.axManager.frameApplyAsyncOverrideForTests = { requests, complete in
                    let results = requests.map { request in
                        AXFrameApplyResult(
                            requestId: request.requestId,
                            pid: request.pid,
                            windowId: request.windowId,
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            writeResult: scratchpadTestWriteResult(
                                targetFrame: request.frame,
                                currentFrameHint: request.currentFrameHint,
                                observedFrame: request.frame,
                                failureReason: .sizeWriteFailed(.attributeUnsupported)
                            )
                        )
                    }
                    if requests.contains(where: { $0.windowId == token.windowId && $0.frame == expectedFrame }) {
                        pendingCompletion = {
                            complete(results)
                        }
                        return
                    }
                    complete(results)
                }
                defer {
                    AXWindowService.fastFrameProviderForTests = nil
                    controller.axManager.frameApplyAsyncOverrideForTests = nil
                }

                controller.toggleScratchpadWindow()

                #expect(pendingCompletion != nil)
                #expect(recorder.events.isEmpty)

                pendingCompletion?()

                let delayedReveal = await waitForConditionForTests(timeoutNanoseconds: 5_000_000_000) {
                    controller.axManager.lastAppliedFrame(for: token.windowId) == expectedFrame
                        && controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true
                }

                #expect(delayedReveal)
                #expect(recorder.events.isEmpty)
            }
        }
    }

    @Test @MainActor func toggleScratchpadWindowFailedHiddenRevealKeepsScratchpadStateAndSkipsFocus() {
        let recorder = ScratchpadFocusRecorder()
        let controller = makeLayoutPlanTestController(
            windowFocusOperations: makeScratchpadFocusOperations(recorder: recorder)
        )
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad failure focus test")
            return
        }

        let visibleToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 733)
        _ = controller.workspaceManager.setManagedFocus(visibleToken, in: workspaceId, onMonitor: monitor.id)

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 734),
            pid: 734,
            windowId: 734,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: CGRect(x: 240, y: 170, width: 600, height: 390),
                normalizedOrigin: CGPoint(x: 0.3, y: 0.22),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.84, y: 0.74),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )
        #expect(controller.workspaceManager.setScratchpadToken(token))

        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: scratchpadTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: .suppressed
                    )
                )
            }
        }

        controller.toggleScratchpadWindow()

        #expect(controller.workspaceManager.scratchpadToken() == token)
        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == visibleToken)
        #expect(controller.workspaceManager.activeFocusRequestToken != token)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(recorder.events.isEmpty)
    }
}
