// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import ApplicationServices
import CoreGraphics
import Foundation
@testable import Nehir
import Testing

private func layoutRefreshControllerTestWriteResult(
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

private func makeUnavailableLayoutPlanTestWindow(windowId: Int) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateApplication(pid_t.max), windowId: windowId)
}

@Suite(.serialized) struct LayoutRefreshControllerTests {
    @Test @MainActor func hiddenEdgeRevealUsesOnePointForAllApps() {
        #expect(LayoutRefreshController.hiddenWindowEdgeRevealEpsilon == 1.0)
    }

    @Test @MainActor func workspaceHiddenPlacementUsesPhysicalFrameNotVisibleFrame() {
        let monitor = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 1),
            frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
            visibleFrame: CGRect(x: 0, y: 0, width: 1956, height: 1290)
        )
        let origin = HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(
            for: CGSize(width: 1016, height: 1274),
            requestedSide: .right,
            targetY: 8,
            baseReveal: LayoutRefreshController.hiddenWindowEdgeRevealEpsilon,
            scale: 1,
            monitor: monitor,
            monitors: [monitor]
        )

        #expect(origin == CGPoint(x: 2055, y: 8))
    }

    @Test @MainActor func workspaceHiddenPlacementAvoidsAdjacentMonitorWhenSourceYBelongsToOtherDisplay() {
        let builtIn = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 1),
            frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
            visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1329)
        )
        let external = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 2),
            frame: CGRect(x: -263, y: 1329, width: 2560, height: 1440),
            visibleFrame: CGRect(x: -263, y: 1329, width: 2560, height: 1440)
        )

        let origin = HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(
            for: CGSize(width: 1268, height: 1424),
            requestedSide: .right,
            targetY: 1337,
            baseReveal: LayoutRefreshController.hiddenWindowEdgeRevealEpsilon,
            scale: 1,
            monitor: builtIn,
            monitors: [builtIn, external]
        )

        #expect(origin == CGPoint(x: 2055, y: -95))
        let parkedFrame = CGRect(origin: origin, size: CGSize(width: 1268, height: 1424))
        let overlap = parkedFrame.intersection(external.frame)
        #expect(overlap.width * overlap.height == 0)
    }

    @Test @MainActor func workspaceHiddenPlacementUsesTargetMonitorLaneWhenTargetYIsOutsideTargetDisplay() {
        let builtIn = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 1),
            frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
            visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1329)
        )
        let external = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 2),
            frame: CGRect(x: -263, y: 1329, width: 2560, height: 1440),
            visibleFrame: CGRect(x: -263, y: 1329, width: 2560, height: 1440)
        )

        let origin = HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(
            for: CGSize(width: 1016, height: 1274),
            requestedSide: .right,
            targetY: 8,
            baseReveal: LayoutRefreshController.hiddenWindowEdgeRevealEpsilon,
            scale: 1,
            monitor: external,
            monitors: [builtIn, external]
        )

        #expect(origin == CGPoint(x: 2296, y: 1329))
    }

    @Test @MainActor func workspaceHiddenPlacementPrefersTargetLaneOverOffBandZeroOverlap() {
        let left = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 1),
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        )
        let target = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 2),
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let right = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 3),
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        )

        let origin = HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(
            for: CGSize(width: 800, height: 600),
            requestedSide: .right,
            targetY: 100,
            baseReveal: LayoutRefreshController.hiddenWindowEdgeRevealEpsilon,
            scale: 1,
            monitor: target,
            monitors: [left, target, right]
        )

        #expect(origin == CGPoint(x: 1919, y: 100))
    }

    @Test @MainActor func buildMonitorSnapshotUsesConfiguredWorkspaceBarInsetInOverlappingMode() {
        let monitor = Monitor(
            id: Monitor.ID(displayId: 91),
            displayId: 91,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 772),
            hasNotch: false,
            name: "Reserved"
        )
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        controller.settings.workspaceBarPosition = .overlappingMenuBar
        controller.settings.workspaceBarHeight = 24
        controller.settings.workspaceBarReserveLayoutSpace = true

        let snapshot = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor)

        #expect(snapshot.visibleFrame == monitor.visibleFrame)
        #expect(snapshot.workingFrame == CGRect(x: 0, y: 0, width: 1000, height: 748))
    }

    @Test @MainActor func nativeFullscreenWindowSnapshotsSkipFastFrameReadAndUseUnconstrainedFallback() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let workspaceId = controller.interactionWorkspace()?.id else {
                Issue.record("Missing active workspace for native fullscreen snapshot test")
                return
            }

            let token = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: 102),
                pid: 102,
                windowId: 102,
                to: workspaceId
            )
            _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
            _ = controller.workspaceManager.markNativeFullscreenSuspended(token)

            var fastFrameReads = 0
            AXWindowService.fastFrameProviderForTests = { window in
                if window.windowId == token.windowId {
                    fastFrameReads += 1
                }
                return fallbackFastFrameForTests(window)
            }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            guard let entry = controller.workspaceManager.entry(for: token) else {
                Issue.record("Missing native fullscreen entry for snapshot test")
                return
            }

            let snapshots = controller.layoutRefreshController.buildWindowSnapshots(for: [entry])

            #expect(fastFrameReads == 0)
            #expect(snapshots.first?.constraints == .unconstrained)
            #expect(snapshots.first?.layoutReason == .nativeFullscreen)
        }
    }

    @Test @MainActor func executeLayoutPlanAppliesFrameDiffAndFocusedBorder() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for layout executor test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 101)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let frame = CGRect(x: 120, y: 80, width: 900, height: 640)
        _ = confirmFocusedBorderForLayoutPlanTests(
            on: controller,
            token: token,
            frame: frame.offsetBy(dx: -20, dy: -20)
        )
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame)

        let plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: workspaceId,
                rememberedFocusToken: token
            ),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(controller.axManager.lastAppliedFrame(for: 101) == frame)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 101)
        #expect(controller.workspaceManager.preferredWorkspaceFocusToken(in: workspaceId) == token)
    }

    @Test @MainActor func executeLayoutPlanPreservesHiddenStateOnHideAndClearsItOnShow() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for layout visibility test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 202)
        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: CGPoint(x: 0.4, y: 0.3),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )

        var hideDiff = WorkspaceLayoutDiff()
        hideDiff.visibilityChanges = [.hide(token, side: .right)]

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: hideDiff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)

        var showDiff = WorkspaceLayoutDiff()
        showDiff.visibilityChanges = [.show(token)]

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: showDiff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
    }

    @Test @MainActor func pendingFrameWriteWinsOverObservedBorderHint() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for pending border frame test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 208)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let pendingFrame = CGRect(x: 240, y: 96, width: 840, height: 600)
        controller.axManager.frameApplyOverrideForTests = { _ in [] }
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, pendingFrame)])
        #expect(controller.axManager.pendingFrameWrite(for: token.windowId) == pendingFrame)

        let observedFrame = CGRect(x: 180, y: 64, width: 820, height: 560)
        let rendered = controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: token),
            preferredFrame: observedFrame,
            preferredFrameSource: .observed
        )

        #expect(rendered)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 208)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == pendingFrame)
    }

    @Test @MainActor func animationsDisabledPromotesCoordinatedFocusedFrameToDirectBorderUpdate() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for disabled animation border test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 210)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let frame = CGRect(x: 160, y: 96, width: 820, height: 540)
        _ = confirmFocusedBorderForLayoutPlanTests(on: controller, token: token, frame: frame)

        var capturedToken: WindowToken?
        controller.focusBorderController.suppressNextRenderForTests = { target in
            capturedToken = target.token
            return false
        }
        defer {
            controller.focusBorderController.suppressNextRenderForTests = nil
        }

        var diff = WorkspaceLayoutDiff()
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame)

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(capturedToken == token)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 210)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == frame)
    }

    @Test @MainActor func coordinatedBorderDefersBeforeObservedFrameResolutionDuringAnimation() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for coordinated border deferral test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 211)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.viewOffsetPixels = .spring(
            SpringAnimation(
                from: 0,
                to: 120,
                startTime: 0,
                config: .snappy
            )
        )
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

        var observedReadCount = 0
        controller.focusBorderController.observedFrameProviderForTests = { _ in
            observedReadCount += 1
            return CGRect(x: 64, y: 64, width: 640, height: 480)
        }
        defer {
            controller.focusBorderController.observedFrameProviderForTests = nil
        }

        let rendered = controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: token)
        )

        #expect(rendered)
        #expect(observedReadCount == 1)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 211)
    }

    @Test @MainActor func directManagedBorderUpdateFallsBackToPreferredFrameBeforeCachedFrameWhenObservedReadMisses() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for managed border fallback test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 207)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)
        controller.appInfoCache.storeInfoForTests(pid: token.pid, bundleId: "com.example.TestApp")

        let staleCachedFrame = CGRect(x: 96, y: 72, width: 720, height: 480)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, staleCachedFrame)])
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == staleCachedFrame)

        controller.axManager.frameApplyOverrideForTests = nil
        controller.focusBorderController.observedFrameProviderForTests = { _ in nil }
        defer {
            controller.focusBorderController.observedFrameProviderForTests = nil
        }

        let freshPreferredFrame = CGRect(x: 132, y: 88, width: 840, height: 560)
        let rendered = controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: token),
            preferredFrame: freshPreferredFrame
        )

        #expect(rendered)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 207)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == freshPreferredFrame)
    }

    @Test @MainActor func managedResizeFailureKeepsConfirmedFrameAndObservedBorder() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for failed resize border test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 207)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let originalFrame = CGRect(x: 96, y: 72, width: 840, height: 540)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, originalFrame)])
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == originalFrame)
        _ = confirmFocusedBorderForLayoutPlanTests(on: controller, token: token, frame: originalFrame)

        controller.focusBorderController.observedFrameProviderForTests = { axRef in
            axRef.windowId == token.windowId ? originalFrame : nil
        }
        defer {
            controller.focusBorderController.observedFrameProviderForTests = nil
        }

        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: AXFrameWriteResult(
                        targetFrame: request.frame,
                        observedFrame: originalFrame,
                        writeOrder: AXWindowService.frameWriteOrder(
                            currentFrame: request.currentFrameHint,
                            targetFrame: request.frame
                        ),
                        sizeError: .success,
                        positionError: .success,
                        failureReason: .verificationMismatch
                    )
                )
            }
        }

        let failedTarget = CGRect(x: 96, y: 72, width: 1040, height: 700)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: failedTarget, forceApply: false)]
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: failedTarget)

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == originalFrame)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == originalFrame)
    }

    @Test @MainActor func liveFrameHideOriginUsesExperimentalPhysicalEdgeParkingForTransientHide() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first else {
            Issue.record("Missing monitor for transient hide-origin test")
            return
        }

        let frame = CGRect(x: 240, y: 180, width: 800, height: 600)
        guard let origin = controller.layoutRefreshController.liveFrameHideOrigin(
            for: frame,
            monitor: monitor,
            side: .left,
            pid: getpid(),
            reason: .layoutTransient
        ) else {
            Issue.record("Expected a live-frame hide origin for transient hide test")
            return
        }

        // Experimental path: park 1pt across the physical screen edge. This only
        // verifies Nehir's requested coordinate, not WindowServer behavior.
        #expect(origin.y == frame.origin.y)
        #expect(origin.x == monitor.frame.minX - frame.width + LayoutRefreshController.hiddenWindowEdgeRevealEpsilon)
    }

    @Test @MainActor func liveFrameHideOriginPreservesWindowYForWorkspaceHideOnVerticalOverride() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: fixture.secondaryMonitor.name,
                monitorDisplayId: fixture.secondaryMonitor.displayId,
                orientation: .vertical
            )
        )

        let frame = CGRect(x: 2160, y: 180, width: 800, height: 600)
        guard let origin = controller.layoutRefreshController.liveFrameHideOrigin(
            for: frame,
            monitor: fixture.secondaryMonitor,
            side: .left,
            pid: getpid(),
            reason: .workspaceInactive
        ) else {
            Issue.record("Expected a live-frame hide origin for workspace hide test")
            return
        }

        #expect(origin.y == frame.origin.y)
        #expect(
            origin.x < fixture.secondaryMonitor.visibleFrame.minX
                || origin.x > fixture.secondaryMonitor.visibleFrame.maxX - 1.0
        )
    }

    @Test @MainActor func liveFrameHideOriginPreservesWindowYForScratchpadHideOnVerticalOverride() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: fixture.secondaryMonitor.name,
                monitorDisplayId: fixture.secondaryMonitor.displayId,
                orientation: .vertical
            )
        )

        let frame = CGRect(x: 2160, y: 180, width: 800, height: 600)
        guard let origin = controller.layoutRefreshController.liveFrameHideOrigin(
            for: frame,
            monitor: fixture.secondaryMonitor,
            side: .right,
            pid: getpid(),
            reason: .scratchpad
        ) else {
            Issue.record("Expected a live-frame hide origin for scratchpad hide test")
            return
        }

        #expect(origin.y == frame.origin.y)
        #expect(origin.x > fixture.secondaryMonitor.visibleFrame.maxX - 1.0)
    }

    @Test @MainActor func liveFrameHideOriginUsesVerticalAxisForTransientHideOnVerticalOverride() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: fixture.secondaryMonitor.name,
                monitorDisplayId: fixture.secondaryMonitor.displayId,
                orientation: .vertical
            )
        )

        let frame = CGRect(x: 2160, y: 180, width: 800, height: 600)
        guard let origin = controller.layoutRefreshController.liveFrameHideOrigin(
            for: frame,
            monitor: fixture.secondaryMonitor,
            side: .left,
            pid: getpid(),
            reason: .layoutTransient
        ) else {
            Issue.record("Expected a live-frame hide origin for vertical transient hide test")
            return
        }

        #expect(origin.x == frame.origin.x)
        #expect(origin.y == fixture.secondaryMonitor.frame.minY - frame.height + LayoutRefreshController
            .hiddenWindowEdgeRevealEpsilon)
    }

    @Test @MainActor func hideInactiveWorkspacesMarksSecondaryWorkspaceWindowHiddenOnVerticalOverride() {
        let primaryMonitor = makeLayoutPlanTestMonitor(
            displayId: 100,
            name: "Primary"
        )
        let secondaryMonitor = makeLayoutPlanTestMonitor(
            displayId: 200,
            name: "Secondary",
            x: 1920
        )
        let controller = makeLayoutPlanTestController(
            monitors: [primaryMonitor, secondaryMonitor],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .secondary),
                WorkspaceConfiguration(name: "3", monitorAssignment: .secondary)
            ]
        )
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: secondaryMonitor.name,
                monitorDisplayId: secondaryMonitor.displayId,
                orientation: .vertical
            )
        )

        guard let visibleWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let hiddenWorkspaceId = controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        else {
            Issue.record("Missing secondary workspaces for inactive hide test")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(visibleWorkspaceId, on: secondaryMonitor.id))

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: hiddenWorkspaceId, windowId: 608)
        controller.axManager.applyFramesParallel(
            [(pid: token.pid, windowId: token.windowId, frame: CGRect(x: 2160, y: 180, width: 800, height: 600))]
        )

        controller.layoutRefreshController.hideInactiveWorkspacesSync()

        #expect(controller.axManager.inactiveWorkspaceWindowIds.contains(token.windowId))
        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }

    @Test @MainActor func executeLayoutPlanRestoresInactiveWindowFromFrameDiffWithoutShow() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for frame-only restore test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 250)
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)

        let frame = CGRect(x: 160, y: 110, width: 820, height: 540)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.restoreChanges = [
            LayoutRestoreChange(
                token: token,
                hiddenState: WindowModel.HiddenState(
                    proportionalPosition: CGPoint(x: 0.5, y: 0.5),
                    referenceMonitorId: monitor.id,
                    workspaceInactive: true
                )
            )
        ]

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 250) == frame)
    }

    @Test @MainActor func executeLayoutPlanPreservesBorderWhenFocusedFrameIsMissing() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for border executor test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 303)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        var primingDiff = WorkspaceLayoutDiff()
        primingDiff.visibilityChanges = [.show(token)]
        primingDiff.focusedFrame = LayoutFocusedFrame(
            token: token,
            frame: CGRect(x: 20, y: 20, width: 400, height: 300)
        )
        _ = confirmFocusedBorderForLayoutPlanTests(
            on: controller,
            token: token,
            frame: CGRect(x: 20, y: 20, width: 400, height: 300)
        )

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: primingDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 303)

        let hideBorderDiff = WorkspaceLayoutDiff()

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: hideBorderDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 303)
    }

    @Test @MainActor func focusedFrameEstablishesBorderForConfirmedManagedFocus() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for focused frame border test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 309)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let frame = CGRect(x: 44, y: 48, width: 460, height: 340)
        var diff = WorkspaceLayoutDiff()
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame)

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(controller.currentBorderTarget()?.token == token)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == frame)
    }

    @Test @MainActor func directBorderUpdateRespectsPreservedNonManagedFocus() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for direct border gating test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 304)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let frame = CGRect(x: 24, y: 24, width: 420, height: 320)
        _ = confirmFocusedBorderForLayoutPlanTests(on: controller, token: token, frame: frame)
        var primingDiff = WorkspaceLayoutDiff()
        primingDiff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame)

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: primingDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 304)

        _ = controller.workspaceManager.enterNonManagedFocus(
            appFullscreen: false,
            preserveFocusedToken: true
        )
        controller.focusBorderController.clear()
        #expect(controller.workspaceManager.confirmedManagedFocusToken == token)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)

        var diff = WorkspaceLayoutDiff()
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame.offsetBy(dx: 12, dy: 8))

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)
    }

    @Test @MainActor func activateWindowPlanReappliesBorderAfterFirstDirectUpdateMisses() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for post-layout border reapply test")
            return
        }

        controller.setBordersEnabled(true)

        let oldToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 307)
        let newToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 308)
        _ = controller.workspaceManager.setManagedFocus(oldToken, in: workspaceId, onMonitor: monitor.id)

        let oldFrame = CGRect(x: 28, y: 28, width: 420, height: 320)
        _ = confirmFocusedBorderForLayoutPlanTests(on: controller, token: oldToken, frame: oldFrame)
        var primingDiff = WorkspaceLayoutDiff()
        primingDiff.focusedFrame = LayoutFocusedFrame(token: oldToken, frame: oldFrame)

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: primingDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 307)

        let newFrame = CGRect(x: 520, y: 32, width: 420, height: 320)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: newToken, frame: newFrame, forceApply: false)]
        diff.focusedFrame = LayoutFocusedFrame(token: newToken, frame: newFrame)

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff,
                animationDirectives: [.activateWindow(token: newToken)]
            )
        )

        #expect(controller.workspaceManager.activeFocusRequestToken == newToken)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 307)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == oldFrame)
    }

    @Test @MainActor func staleBorderUpdatesDoNotReplaceExistingFocusedBorder() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for stale border gating test")
            return
        }

        let focusedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 305)
        let staleToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 306)
        _ = controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let focusedFrame = CGRect(x: 32, y: 32, width: 420, height: 320)
        _ = confirmFocusedBorderForLayoutPlanTests(on: controller, token: focusedToken, frame: focusedFrame)
        var primingDiff = WorkspaceLayoutDiff()
        primingDiff.focusedFrame = LayoutFocusedFrame(token: focusedToken, frame: focusedFrame)

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: primingDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 305)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == focusedFrame)

        let staleFrame = focusedFrame.offsetBy(dx: 80, dy: 24)
        var directDiff = WorkspaceLayoutDiff()
        directDiff.focusedFrame = LayoutFocusedFrame(token: staleToken, frame: staleFrame)

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: directDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 305)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == focusedFrame)

        var coordinatedDiff = WorkspaceLayoutDiff()
        coordinatedDiff.focusedFrame = LayoutFocusedFrame(token: staleToken, frame: staleFrame.offsetBy(dx: 20, dy: 12))

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: coordinatedDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 305)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == focusedFrame)
    }

    @Test @MainActor func executeLayoutPlanDoesNotRestoreInactiveWorkspaceForNonActivePlan() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let inactiveWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let activeWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing monitor or workspaces for inactive restore regression test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: inactiveWorkspaceId, windowId: 404)
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        _ = controller.workspaceManager.setActiveWorkspace(activeWorkspaceId, on: monitor.id)

        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [
            LayoutFrameChange(
                token: token,
                frame: CGRect(x: 220, y: 120, width: 760, height: 520),
                forceApply: false
            )
        ]

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: inactiveWorkspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: inactiveWorkspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }

    @Test @MainActor func executeLayoutPlanRestoresSecondaryWorkspaceWindowOnVisibleMonitor() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller

        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 505
        )
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(
            on: controller,
            token: token,
            monitor: fixture.secondaryMonitor
        )

        let frame = CGRect(x: 2040, y: 140, width: 760, height: 520)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.restoreChanges = [
            LayoutRestoreChange(
                token: token,
                hiddenState: WindowModel.HiddenState(
                    proportionalPosition: CGPoint(x: 0.4, y: 0.4),
                    referenceMonitorId: fixture.secondaryMonitor.id,
                    workspaceInactive: true
                )
            )
        ]

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: fixture.secondaryWorkspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.secondaryMonitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: fixture.secondaryWorkspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 505) == frame)
    }

    @Test @MainActor func unhideWorkspaceRestoresFloatingWindowFromOwnedFloatingState() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for floating restore test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 560),
            pid: 560,
            windowId: 560,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 180, y: 140, width: 520, height: 360)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.3, y: 0.25),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.9, y: 0.9),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )

        controller.layoutRefreshController.unhideWorkspace(workspaceId, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 560) == floatingFrame)
    }

    @Test @MainActor func unhideWorkspaceLeavesScratchpadWindowHidden() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for scratchpad unhide test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 580),
            pid: 580,
            windowId: 580,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: CGRect(x: 220, y: 180, width: 500, height: 340),
                normalizedOrigin: CGPoint(x: 0.25, y: 0.2),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.8, y: 0.75),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )

        controller.layoutRefreshController.unhideWorkspace(workspaceId, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.axManager.lastAppliedFrame(for: 580) == nil)
    }

    @Test @MainActor func restoreScratchpadWindowUsesOwnedFloatingState() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for scratchpad restore test")
                return
            }

            let token = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: 581),
                pid: 581,
                windowId: 581,
                to: workspaceId,
                mode: .floating
            )
            let floatingFrame = CGRect(x: 260, y: 160, width: 540, height: 360)
            controller.workspaceManager.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: CGPoint(x: 0.3, y: 0.25),
                    referenceMonitorId: monitor.id,
                    restoreToFloating: true
                ),
                for: token
            )
            controller.workspaceManager.setHiddenState(
                .init(
                    proportionalPosition: CGPoint(x: 0.85, y: 0.8),
                    referenceMonitorId: monitor.id,
                    reason: .scratchpad
                ),
                for: token
            )

            guard let entry = controller.workspaceManager.entry(for: token) else {
                Issue.record("Missing entry for scratchpad restore test")
                return
            }

            controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)

            #expect(controller.workspaceManager.hiddenState(for: token) == nil)
            #expect(controller.axManager.lastAppliedFrame(for: 581) == floatingFrame)
        }
    }

    @Test @MainActor func restoreScratchpadWindowKeepsHiddenStateUntilAsyncRevealCompletes() async throws {
        await withAppAXContextIsolationForTests {
            await withAXFrameProviderIsolationForTests {
                let controller = makeLayoutPlanTestController()
                guard let monitor = controller.workspaceManager.monitors.first,
                      let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
                else {
                    Issue.record("Missing monitor or active workspace for async scratchpad reveal test")
                    return
                }

                let token = controller.workspaceManager.addWindow(
                    makeLayoutPlanTestWindow(windowId: 582),
                    pid: 5_582,
                    windowId: 582,
                    to: workspaceId,
                    mode: .floating
                )
                let floatingFrame = CGRect(x: 300, y: 180, width: 560, height: 380)
                controller.workspaceManager.setFloatingState(
                    .init(
                        lastFrame: floatingFrame,
                        normalizedOrigin: CGPoint(x: 0.35, y: 0.3),
                        referenceMonitorId: monitor.id,
                        restoreToFloating: true
                    ),
                    for: token
                )
                controller.workspaceManager.setHiddenState(
                    .init(
                        proportionalPosition: CGPoint(x: 0.82, y: 0.76),
                        referenceMonitorId: monitor.id,
                        reason: .scratchpad
                    ),
                    for: token
                )

                guard let entry = controller.workspaceManager.entry(for: token) else {
                    Issue.record("Missing entry for async scratchpad reveal test")
                    return
                }

                var pendingCompletion: (() -> Void)?
                controller.axManager.frameApplyAsyncOverrideForTests = { requests, complete in
                    let results = requests.map { request in
                        AXFrameApplyResult(
                            requestId: request.requestId,
                            pid: request.pid,
                            windowId: request.windowId,
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            writeResult: layoutRefreshControllerTestWriteResult(
                                targetFrame: request.frame,
                                currentFrameHint: request.currentFrameHint,
                                observedFrame: request.frame,
                                failureReason: nil
                            )
                        )
                    }
                    if requests.contains(where: { $0.windowId == token.windowId }) {
                        pendingCompletion = {
                            complete(results)
                        }
                        return
                    }
                    complete(results)
                }
                defer {
                    controller.axManager.frameApplyAsyncOverrideForTests = nil
                }

                controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)

                #expect(pendingCompletion != nil)
                #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
                #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId))

                pendingCompletion?()

                let completedReveal = await waitForConditionForTests {
                    controller.workspaceManager.hiddenState(for: token) == nil
                        && controller.axManager.hasPendingFrameWrite(for: token.windowId) == false
                }

                #expect(completedReveal)
                #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == floatingFrame)
            }
        }
    }

    @Test @MainActor func restoreScratchpadWindowWithoutRestoreGeometryKeepsHiddenStateAndSkipsSuccessAction() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for scratchpad no-geometry test")
                return
            }

            let windowId = 587
            let token = controller.workspaceManager.addWindow(
                makeUnavailableLayoutPlanTestWindow(windowId: windowId),
                pid: pid_t(windowId),
                windowId: windowId,
                to: workspaceId,
                mode: .floating
            )
            AXWindowService.fastFrameProviderForTests = { window in
                window.windowId == windowId ? nil : fallbackFastFrameForTests(window)
            }
            defer {
                AXWindowService.fastFrameProviderForTests = nil
            }
            controller.workspaceManager.setHiddenState(
                .init(
                    proportionalPosition: CGPoint(x: 0.6, y: 0.6),
                    referenceMonitorId: monitor.id,
                    reason: .scratchpad
                ),
                for: token
            )

            guard let entry = controller.workspaceManager.entry(for: token) else {
                Issue.record("Missing entry for scratchpad no-geometry test")
                return
            }

            var successCount = 0
            controller.layoutRefreshController.restoreScratchpadWindow(
                entry,
                monitor: monitor,
                onSuccess: { successCount += 1 }
            )

            #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
            #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)
            #expect(successCount == 0)
        }
    }

    @Test @MainActor func restoreScratchpadWindowVerificationMismatchCompletesAfterDelayedVerification() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for delayed verification mismatch test")
                return
            }

            let token = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: 588),
                pid: 588,
                windowId: 588,
                to: workspaceId,
                mode: .floating
            )
            let floatingFrame = CGRect(x: 260, y: 160, width: 620, height: 420)
            var observedFrame = CGRect(x: -1400, y: 160, width: 620, height: 420)
            controller.workspaceManager.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: CGPoint(x: 0.3, y: 0.24),
                    referenceMonitorId: monitor.id,
                    restoreToFloating: true
                ),
                for: token
            )
            controller.workspaceManager.setHiddenState(
                .init(
                    proportionalPosition: CGPoint(x: 0.82, y: 0.7),
                    referenceMonitorId: monitor.id,
                    reason: .scratchpad
                ),
                for: token
            )
            AXWindowService.fastFrameProviderForTests = { window in
                window.windowId == token.windowId ? observedFrame : fallbackFastFrameForTests(window)
            }
            defer {
                AXWindowService.fastFrameProviderForTests = nil
            }

            controller.axManager.frameApplyOverrideForTests = { requests in
                requests.map { request in
                    AXFrameApplyResult(
                        requestId: request.requestId,
                        pid: request.pid,
                        windowId: request.windowId,
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        writeResult: layoutRefreshControllerTestWriteResult(
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            observedFrame: observedFrame,
                            failureReason: .verificationMismatch
                        )
                    )
                }
            }

            guard let entry = controller.workspaceManager.entry(for: token) else {
                Issue.record("Missing entry for delayed verification mismatch test")
                return
            }

            controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)
            observedFrame = floatingFrame

            let completedReveal = controller.layoutRefreshController.runPendingRevealVerificationForTests(
                windowId: token.windowId
            )

            #expect(completedReveal)
            #expect(controller.workspaceManager.hiddenState(for: token) == nil)
            #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == floatingFrame)
        }
    }

    @Test @MainActor func restoreScratchpadWindowReadbackFailureCompletesAfterDelayedVerification() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for delayed readback-failure test")
                return
            }

            let token = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: 589),
                pid: 589,
                windowId: 589,
                to: workspaceId,
                mode: .floating
            )
            let floatingFrame = CGRect(x: 280, y: 180, width: 580, height: 380)
            var observedFrame = CGRect(x: -1500, y: 180, width: 580, height: 380)
            controller.workspaceManager.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: CGPoint(x: 0.32, y: 0.26),
                    referenceMonitorId: monitor.id,
                    restoreToFloating: true
                ),
                for: token
            )
            controller.workspaceManager.setHiddenState(
                .init(
                    proportionalPosition: CGPoint(x: 0.84, y: 0.72),
                    referenceMonitorId: monitor.id,
                    reason: .scratchpad
                ),
                for: token
            )
            AXWindowService.fastFrameProviderForTests = { window in
                window.windowId == token.windowId ? observedFrame : fallbackFastFrameForTests(window)
            }
            defer {
                AXWindowService.fastFrameProviderForTests = nil
            }

            controller.axManager.frameApplyOverrideForTests = { requests in
                requests.map { request in
                    AXFrameApplyResult(
                        requestId: request.requestId,
                        pid: request.pid,
                        windowId: request.windowId,
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        writeResult: layoutRefreshControllerTestWriteResult(
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            observedFrame: nil,
                            failureReason: .readbackFailed
                        )
                    )
                }
            }

            guard let entry = controller.workspaceManager.entry(for: token) else {
                Issue.record("Missing entry for delayed readback-failure test")
                return
            }

            controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)
            observedFrame = floatingFrame

            let completedReveal = controller.layoutRefreshController.runPendingRevealVerificationForTests(
                windowId: token.windowId
            )

            #expect(completedReveal)
            #expect(controller.workspaceManager.hiddenState(for: token) == nil)
            #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == floatingFrame)
        }
    }

    @Test @MainActor func restoreScratchpadWindowSizeWriteFailureCompletesAfterDelayedVisibleFrameVerification() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for delayed size-write failure test")
                return
            }

            let token = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: 591),
                pid: 591,
                windowId: 591,
                to: workspaceId,
                mode: .floating
            )
            let floatingFrame = CGRect(x: 300, y: 200, width: 540, height: 360)
            var liveFrame = CGRect(x: monitor.frame.maxX + 80, y: 200, width: 540, height: 360)
            controller.workspaceManager.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: CGPoint(x: 0.34, y: 0.28),
                    referenceMonitorId: monitor.id,
                    restoreToFloating: true
                ),
                for: token
            )
            controller.workspaceManager.setHiddenState(
                .init(
                    proportionalPosition: CGPoint(x: 0.86, y: 0.74),
                    referenceMonitorId: monitor.id,
                    reason: .scratchpad
                ),
                for: token
            )
            AXWindowService.fastFrameProviderForTests = { window in
                window.windowId == token.windowId ? liveFrame : fallbackFastFrameForTests(window)
            }
            defer {
                AXWindowService.fastFrameProviderForTests = nil
            }

            controller.axManager.frameApplyOverrideForTests = { requests in
                requests.map { request in
                    AXFrameApplyResult(
                        requestId: request.requestId,
                        pid: request.pid,
                        windowId: request.windowId,
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        writeResult: layoutRefreshControllerTestWriteResult(
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            observedFrame: request.frame,
                            failureReason: .sizeWriteFailed(.attributeUnsupported)
                        )
                    )
                }
            }

            guard let entry = controller.workspaceManager.entry(for: token) else {
                Issue.record("Missing entry for delayed size-write failure test")
                return
            }

            controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)

            #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
            #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == floatingFrame)

            liveFrame = floatingFrame

            let completedReveal = controller.layoutRefreshController.runPendingRevealVerificationForTests(
                windowId: token.windowId
            )

            #expect(completedReveal)
            #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        }
    }

    @Test @MainActor func restoreScratchpadWindowStaleElementConfirmedFrameCompletesAfterDelayedVerification() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for stale-element confirmation test")
                return
            }

            let token = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: 593),
                pid: 593,
                windowId: 593,
                to: workspaceId,
                mode: .floating
            )
            let floatingFrame = CGRect(x: 310, y: 210, width: 520, height: 340)
            var liveFrame = CGRect(x: monitor.frame.maxX + 60, y: 210, width: 520, height: 340)
            controller.workspaceManager.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: CGPoint(x: 0.35, y: 0.29),
                    referenceMonitorId: monitor.id,
                    restoreToFloating: true
                ),
                for: token
            )
            controller.workspaceManager.setHiddenState(
                .init(
                    proportionalPosition: CGPoint(x: 0.86, y: 0.74),
                    referenceMonitorId: monitor.id,
                    reason: .scratchpad
                ),
                for: token
            )
            AXWindowService.fastFrameProviderForTests = { window in
                window.windowId == token.windowId ? liveFrame : fallbackFastFrameForTests(window)
            }
            defer {
                AXWindowService.fastFrameProviderForTests = nil
            }
            controller.axManager.frameApplyOverrideForTests = { requests in
                requests.map { request in
                    AXFrameApplyResult(
                        requestId: request.requestId,
                        pid: request.pid,
                        windowId: request.windowId,
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        writeResult: layoutRefreshControllerTestWriteResult(
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            observedFrame: request.frame,
                            failureReason: .staleElement
                        )
                    )
                }
            }

            guard let entry = controller.workspaceManager.entry(for: token) else {
                Issue.record("Missing entry for stale-element confirmation test")
                return
            }

            controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)
            #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)

            liveFrame = floatingFrame

            let completedReveal = controller.layoutRefreshController.runPendingRevealVerificationForTests(
                windowId: token.windowId
            )

            #expect(completedReveal)
            #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        }
    }

    @Test @MainActor func restoreScratchpadWindowFailurePreservesHiddenStateAndRetryCanSucceed() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for scratchpad failure retry test")
                return
            }

            let token = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: 583),
                pid: 583,
                windowId: 583,
                to: workspaceId,
                mode: .floating
            )
            let floatingFrame = CGRect(x: 320, y: 190, width: 520, height: 350)
            controller.workspaceManager.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: CGPoint(x: 0.33, y: 0.28),
                    referenceMonitorId: monitor.id,
                    restoreToFloating: true
                ),
                for: token
            )
            controller.workspaceManager.setHiddenState(
                .init(
                    proportionalPosition: CGPoint(x: 0.8, y: 0.7),
                    referenceMonitorId: monitor.id,
                    reason: .scratchpad
                ),
                for: token
            )

            var shouldFail = true
            controller.axManager.frameApplyOverrideForTests = { requests in
                requests.map { request in
                    AXFrameApplyResult(
                        requestId: request.requestId,
                        pid: request.pid,
                        windowId: request.windowId,
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        writeResult: layoutRefreshControllerTestWriteResult(
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            observedFrame: shouldFail ? request.currentFrameHint : request.frame,
                            failureReason: shouldFail ? .suppressed : nil
                        )
                    )
                }
            }

            guard let entry = controller.workspaceManager.entry(for: token) else {
                Issue.record("Missing entry for scratchpad failure retry test")
                return
            }

            controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)

            #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
            #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
            #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)

            shouldFail = false
            controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)

            #expect(controller.workspaceManager.hiddenState(for: token) == nil)
            #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == floatingFrame)
        }
    }

    @Test @MainActor func unhideWindowFailureDoesNotRestoreWorkspaceHiddenState() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for workspace unhide failure test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 584),
            pid: 584,
            windowId: 584,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 180, y: 120, width: 500, height: 320)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.25, y: 0.2),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.78, y: 0.74),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: .suppressed
                    )
                )
            }
        }

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for workspace unhide failure test")
            return
        }

        controller.layoutRefreshController.unhideWindow(entry, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == .suppressed)
    }

    @Test @MainActor func executeLayoutPlanShowWithCachedVisibleFrameClearsHiddenStateWithoutRevealTransaction() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for cached reveal frame test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 590)
        let frame = CGRect(x: 220, y: 140, width: 760, height: 520)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, frame)])
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)

        var attemptCount = 0
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += requests.count
            return requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                )
            }
        }

        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges = [.show(token)]
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(attemptCount == 0)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == frame)
    }

    @Test @MainActor func pendingRevealTransactionSurvivesManagedRekeyDuringDelayedVerification() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for reveal rekey test")
                return
            }

            let originalToken = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: 591),
                pid: 591,
                windowId: 591,
                to: workspaceId,
                mode: .floating
            )
            let floatingFrame = CGRect(x: 300, y: 170, width: 560, height: 360)
            var observedFrame = CGRect(x: -1300, y: 170, width: 560, height: 360)
            var observedWindowIds: Set<Int> = [originalToken.windowId]
            controller.workspaceManager.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: CGPoint(x: 0.34, y: 0.24),
                    referenceMonitorId: monitor.id,
                    restoreToFloating: true
                ),
                for: originalToken
            )
            controller.workspaceManager.setHiddenState(
                .init(
                    proportionalPosition: CGPoint(x: 0.83, y: 0.71),
                    referenceMonitorId: monitor.id,
                    reason: .scratchpad
                ),
                for: originalToken
            )
            AXWindowService.fastFrameProviderForTests = { window in
                observedWindowIds.contains(window.windowId) ? observedFrame : fallbackFastFrameForTests(window)
            }
            defer {
                AXWindowService.fastFrameProviderForTests = nil
            }

            controller.axManager.frameApplyOverrideForTests = { requests in
                requests.map { request in
                    AXFrameApplyResult(
                        requestId: request.requestId,
                        pid: request.pid,
                        windowId: request.windowId,
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        writeResult: layoutRefreshControllerTestWriteResult(
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            observedFrame: observedFrame,
                            failureReason: .verificationMismatch
                        )
                    )
                }
            }

            guard let originalEntry = controller.workspaceManager.entry(for: originalToken) else {
                Issue.record("Missing entry for reveal rekey test")
                return
            }

            controller.layoutRefreshController.restoreScratchpadWindow(originalEntry, monitor: monitor)

            let newToken = WindowToken(pid: originalToken.pid, windowId: 592)
            observedWindowIds.insert(newToken.windowId)
            let newAXRef = makeLayoutPlanTestWindow(windowId: newToken.windowId)
            guard let newEntry = controller.workspaceManager.rekeyWindow(
                from: originalToken,
                to: newToken,
                newAXRef: newAXRef
            ) else {
                Issue.record("Failed to rekey window during reveal rekey test")
                return
            }

            controller.axManager.rekeyWindowState(
                pid: newToken.pid,
                oldWindowId: originalToken.windowId,
                newWindow: newAXRef
            )
            controller.layoutRefreshController.rekeyPendingRevealTransaction(
                from: originalToken,
                to: newToken,
                entry: newEntry
            )

            observedFrame = floatingFrame

            let completedReveal = controller.layoutRefreshController.runPendingRevealVerificationForTests(
                windowId: newToken.windowId
            )

            #expect(completedReveal)
            #expect(controller.workspaceManager.hiddenState(for: newToken) == nil)
            #expect(controller.axManager.lastAppliedFrame(for: newToken.windowId) == floatingFrame)
        }
    }

    @Test @MainActor func executeLayoutPlanRestoreFrameFailureDoesNotRehideWorkspaceInactiveWindow() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for layout restore failure test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 585)
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        let frame = CGRect(x: 200, y: 120, width: 760, height: 520)
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: .suppressed
                    )
                )
            }
        }

        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.restoreChanges = [
            LayoutRestoreChange(
                token: token,
                hiddenState: WindowModel.HiddenState(
                    proportionalPosition: CGPoint(x: 0.5, y: 0.5),
                    referenceMonitorId: monitor.id,
                    workspaceInactive: true
                )
            )
        ]

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == .suppressed)
    }

    @Test @MainActor func unhideWindowPositionPlanRevealClearsHiddenStateSynchronously() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for position-plan unhide test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 586)
        let hiddenFrame = CGRect(x: -1400, y: 200, width: 720, height: 460)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, hiddenFrame)])
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.2, y: 0.25),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for position-plan unhide test")
            return
        }

        controller.layoutRefreshController.unhideWindow(entry, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == nil)
    }

    @Test @MainActor func hideWindowWithoutResolvedGeometryDoesNotMarkWindowHidden() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or workspace for unavailable hide test")
                return
            }

            let windowId = 606
            let token = controller.workspaceManager.addWindow(
                makeUnavailableLayoutPlanTestWindow(windowId: windowId),
                pid: pid_t(windowId),
                windowId: windowId,
                to: workspaceId,
                mode: .tiling
            )
            AXWindowService.fastFrameProviderForTests = { window in
                window.windowId == windowId ? nil : fallbackFastFrameForTests(window)
            }
            defer {
                AXWindowService.fastFrameProviderForTests = nil
            }
            guard let entry = controller.workspaceManager.entry(for: token) else {
                Issue.record("Missing entry for unavailable hide test")
                return
            }

            controller.layoutRefreshController.hideWindow(
                entry,
                monitor: monitor,
                side: .left,
                reason: .workspaceInactive
            )

            #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        }
    }

    // MARK: - Selection revision guard

    @Test @MainActor func staleRelayoutPatchDoesNotOverwriteNewerSelection() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace")
            return
        }

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 201)

        // Live selection: selectedNodeId = A (bumps revision)
        let nodeA = NodeId()
        controller.workspaceManager.setSelection(nodeA, for: workspaceId)
        let plannedRevision = controller.workspaceManager.selectionRevision(for: workspaceId)

        // Simulate a user focus change between plan-build and plan-apply:
        // selectedNodeId = C bumps the revision past plannedRevision.
        let nodeC = NodeId()
        controller.workspaceManager.setSelection(nodeC, for: workspaceId)
        #expect(controller.workspaceManager.selectionRevision(for: workspaceId) > plannedRevision)

        // Stale plan built at plannedRevision with selectedNodeId = B.
        var staleViewport = controller.workspaceManager.niriViewportState(for: workspaceId)
        let nodeB = NodeId()
        staleViewport.selectedNodeId = nodeB

        let plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: staleViewport,
                plannedSelectionRevision: plannedRevision
            ),
            diff: WorkspaceLayoutDiff()
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        // The stale plan's selectedNodeId (B) must NOT overwrite the live one (C).
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == nodeC)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId != nodeB)
    }
}
