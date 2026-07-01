// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import Nehir
import Testing

private func makeMouseEventTestDefaults() -> UserDefaults {
    let suiteName = "dev.guria.nehir.mouse-event.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeMouseEventTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private func makeGestureTouchSamples(
    xPositions: [CGFloat],
    yPosition: CGFloat = 0.5,
    phase: NSTouch.Phase = .touching
) -> [MouseEventHandler.GestureTouchSample] {
    xPositions.map { xPosition in
        MouseEventHandler.GestureTouchSample(
            phase: phase,
            normalizedPosition: CGPoint(x: xPosition, y: yPosition)
        )
    }
}

@MainActor
private func sendCommittingTrackpadGesture(
    to handler: MouseEventHandler,
    at location: CGPoint
) {
    let baseTime = CACurrentMediaTime()
    handler.receiveTapGestureEvent(
        .init(
            location: location,
            phaseRawValue: NSEvent.Phase.began.rawValue,
            timestamp: baseTime,
            touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
        )
    )
    handler.receiveTapGestureEvent(
        .init(
            location: location,
            phaseRawValue: NSEvent.Phase.changed.rawValue,
            timestamp: baseTime + 0.016,
            touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
        )
    )
}

@MainActor
/// Builds a raw `CGWindowList` window record for an unmanaged overlay covering
/// `appKitFrame`. Bounds are emitted in WindowServer/Quartz space (top-left
/// origin) and converted to AppKit by the occlusion predicate, matching how the
/// live `CGWindowListCopyWindowInfo` snapshot is consumed. Lets FFM occlusion
/// tests inject a deterministic overlay without depending on real on-screen
/// windows.
private func makeUnmanagedOverlayWindowInfo(
    windowId: Int,
    pid: pid_t,
    appKitFrame: CGRect,
    layer: Int = 0,
    ownerName: String = "TestOverlay"
) -> [String: Any] {
    let quartz = ScreenCoordinateSpace.toWindowServer(rect: appKitFrame)
    return [
        kCGWindowNumber as String: NSNumber(value: windowId),
        kCGWindowOwnerPID as String: NSNumber(value: pid),
        kCGWindowOwnerName as String: ownerName,
        kCGWindowLayer as String: NSNumber(value: layer),
        kCGWindowIsOnscreen as String: NSNumber(value: true),
        kCGWindowBounds as String: [
            "X": NSNumber(value: Double(quartz.minX)),
            "Y": NSNumber(value: Double(quartz.minY)),
            "Width": NSNumber(value: Double(quartz.width)),
            "Height": NSNumber(value: Double(quartz.height))
        ]
    ]
}

private func makeOwnedUtilityTestWindow(
    frame: CGRect = CGRect(x: 40, y: 40, width: 240, height: 180)
) -> NSWindow {
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    return window
}

@MainActor
private func makeOwnedMouseWindowRegistry(frontmostWindow: @escaping () -> NSWindow?) -> OwnedWindowRegistry {
    OwnedWindowRegistry(
        surfaceCoordinator: SurfaceCoordinator(
            scene: SurfaceScene(
                frontmostInteractiveResolver: SurfaceFrontmostInteractiveResolver { window in
                    frontmostWindow().map { window === $0 } ?? false
                }
            )
        )
    )
}

@MainActor
private func makeMouseEventTestController(
    workspaceConfigurations: [WorkspaceConfiguration]? = nil,
    ownedWindowRegistry: OwnedWindowRegistry = .shared
) -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let settings = SettingsStore(defaults: makeMouseEventTestDefaults())
    if let workspaceConfigurations {
        settings.workspaceConfigurations = workspaceConfigurations
    }
    let controller = WMController(
        settings: settings,
        windowFocusOperations: operations,
        ownedWindowRegistry: ownedWindowRegistry
    )
    controller.lockScreenObserver.frontmostApplicationProvider = { nil }
    controller.unmanagedWindowServerWindowFramesProvider = { _ in [] }
    controller.unmanagedOverlayWindowServerWindowCoversOverride = { _ in false }
    controller.unmanagedOverlayWindowInfoProvider = { [] }
    let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let monitor = Monitor(
        id: Monitor.ID(displayId: 1),
        displayId: 1,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: "Main"
    )
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])
    return controller
}

@MainActor
private func prepareMouseResizeFixture(
    constraints: WindowSizeConstraints = .unconstrained,
    ownedWindowRegistry: OwnedWindowRegistry = .shared
) async -> (
    controller: WMController,
    handler: MouseEventHandler,
    handle: WindowHandle,
    workspaceId: WorkspaceDescriptor.ID,
    nodeId: NodeId,
    nodeFrame: CGRect,
    location: CGPoint
) {
    let controller = makeMouseEventTestController(ownedWindowRegistry: ownedWindowRegistry)
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let workspaceId = controller.interactionWorkspace()?.id else {
        fatalError("Missing interaction workspace for mouse fixture")
    }

    let token = controller.workspaceManager.addWindow(
        makeMouseEventTestWindow(windowId: 901),
        pid: getpid(),
        windowId: 901,
        to: workspaceId
    )
    controller.workspaceManager.setCachedConstraints(constraints, for: token)
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Missing bridge handle for mouse fixture")
    }
    _ = controller.workspaceManager.rememberFocus(handle, in: workspaceId)

    guard let engine = controller.niriEngine else {
        fatalError("Missing Niri engine for mouse fixture")
    }

    let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
    _ = engine.syncWindows(
        handles,
        in: workspaceId,
        selectedNodeId: nil,
        focusedHandle: handle
    )

    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    guard let node = engine.findNode(for: handle),
          let nodeFrame = node.frame,
          let monitor = controller.workspaceManager.monitor(for: workspaceId)
    else {
        fatalError("Failed to prepare interactive resize fixture")
    }

    controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
        state.selectedNodeId = node.id
    }

    let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
    return (controller, controller.mouseEventHandler, handle, workspaceId, node.id, nodeFrame, location)
}

@MainActor
private func prepareCommittedTrackpadGestureFixture() async -> (
    controller: WMController,
    handler: MouseEventHandler,
    workspaceId: WorkspaceDescriptor.ID,
    location: CGPoint
) {
    let controller = makeMouseEventTestController()
    controller.settings.scrollGestureEnabled = true
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let workspaceId = controller.interactionWorkspace()?.id,
          let monitor = controller.workspaceManager.monitor(for: workspaceId),
          let engine = controller.niriEngine
    else {
        fatalError("Missing Niri context for committed gesture fixture")
    }

    populateNiriWorkspaceForMouseTests(
        controller: controller,
        engine: engine,
        workspaceId: workspaceId,
        monitor: monitor,
        startingWindowId: 540
    )
    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    let handler = controller.mouseEventHandler
    let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
    let baseTime = CACurrentMediaTime()

    handler.receiveTapGestureEvent(
        .init(
            location: location,
            phaseRawValue: NSEvent.Phase.began.rawValue,
            timestamp: baseTime,
            touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
        )
    )
    handler.receiveTapGestureEvent(
        .init(
            location: location,
            phaseRawValue: NSEvent.Phase.changed.rawValue,
            timestamp: baseTime + 0.016,
            touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
        )
    )

    return (controller, handler, workspaceId, location)
}

@MainActor
@discardableResult
private func populateNiriWorkspaceForMouseTests(
    controller: WMController,
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    monitor: Monitor,
    startingWindowId: Int,
    count: Int = 3
) -> WindowHandle {
    var focusedHandle: WindowHandle?
    for index in 0 ..< count {
        let windowId = startingWindowId + index
        let token = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: windowId),
            pid: getpid(),
            windowId: windowId,
            to: workspaceId
        )
        if focusedHandle == nil {
            focusedHandle = controller.workspaceManager.handle(for: token)
        }
    }

    guard let focusedHandle else {
        fatalError("Missing focused handle for niri mouse fixture")
    }

    let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
    _ = engine.syncWindows(
        handles,
        in: workspaceId,
        selectedNodeId: nil,
        focusedHandle: focusedHandle
    )
    _ = controller.workspaceManager.setManagedFocus(focusedHandle, in: workspaceId, onMonitor: monitor.id)
    return focusedHandle
}

@MainActor
private func prepareMouseWheelScrollFixture(
    ownedWindowRegistry: OwnedWindowRegistry = .shared
) async -> (
    controller: WMController,
    handler: MouseEventHandler,
    workspaceId: WorkspaceDescriptor.ID,
    location: CGPoint
) {
    let controller = makeMouseEventTestController(ownedWindowRegistry: ownedWindowRegistry)
    controller.settings.scrollGestureEnabled = true
    controller.settings.scrollSensitivity = 1.0
    let frame = CGRect(x: 0, y: 0, width: 640, height: 800)
    let monitor = Monitor(
        id: Monitor.ID(displayId: 1),
        displayId: 1,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: "Main"
    )
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let workspaceId = controller.interactionWorkspace()?.id,
          let monitor = controller.workspaceManager.monitor(for: workspaceId),
          let engine = controller.niriEngine
    else {
        fatalError("Missing Niri context for mouse wheel fixture")
    }

    populateNiriWorkspaceForMouseTests(
        controller: controller,
        engine: engine,
        workspaceId: workspaceId,
        monitor: monitor,
        startingWindowId: 580,
        count: 5
    )

    controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
        state.viewOffsetPixels = .static(0)
    }
    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
    return (controller, controller.mouseEventHandler, workspaceId, location)
}

@MainActor
private func prepareMouseWheelScrollFixtureWithDefaultSensitivity() async -> (
    controller: WMController,
    handler: MouseEventHandler,
    workspaceId: WorkspaceDescriptor.ID,
    location: CGPoint
) {
    let fixture = await prepareMouseWheelScrollFixture()
    fixture.controller.settings.scrollSensitivity = SettingsExport.defaults().scrollSensitivity
    return fixture
}

@Suite(.serialized) struct MouseEventHandlerTests {
    @Test func niriScrollTrackerMatchesWheelTickSemantics() {
        var tracker = NiriScrollTracker(tick: 120)

        #expect(tracker.accumulate(60) == 0)
        #expect(tracker.accumulate(60) == 1)
        #expect(tracker.accumulate(-60) == 0)
        #expect(tracker.accumulate(-60) == -1)

        tracker.reset()
        #expect(tracker.accumulate(20_000) == 127)
        #expect(abs(tracker.accumulator - 80) < 0.001)
    }

    @Test @MainActor func mouseWheelAxisResolutionPrefersPhysicalHorizontalInput() {
        let belowAxisEpsilonDelta: CGFloat = 0.0005

        #expect(MouseEventHandler.resolvedWheelAxisDelta(pointDelta: 3, fixedPointDelta: 9) == 3)
        #expect(MouseEventHandler.resolvedWheelAxisDelta(pointDelta: 0, fixedPointDelta: 9) == 9)
        #expect(
            MouseEventHandler.resolvedMouseWheelColumnDeltaValue(
                deltaX: 12,
                deltaY: 120,
                allowVerticalFallback: true
            ) == 12
        )
        #expect(
            MouseEventHandler.resolvedMouseWheelColumnDeltaValue(
                deltaX: 0,
                deltaY: 12,
                allowVerticalFallback: true
            ) == 12
        )
        #expect(
            MouseEventHandler.resolvedMouseWheelColumnDeltaValue(
                deltaX: 0,
                deltaY: 12,
                allowVerticalFallback: false
            ) == nil
        )
        #expect(
            MouseEventHandler.resolvedMouseWheelColumnDeltaValue(
                deltaX: belowAxisEpsilonDelta,
                deltaY: belowAxisEpsilonDelta,
                allowVerticalFallback: true
            ) == nil
        )
    }

    @Test @MainActor func mouseWheelModifierMatchingUsesExactNiriBindModifiers() {
        let required: CGEventFlags = [.maskAlternate, .maskShift]

        #expect(MouseEventHandler.mouseWheelModifiersMatch(required, required: required))
        #expect(MouseEventHandler.mouseWheelModifiersMatch(
            [.maskAlternate, .maskShift, .maskCommand],
            required: required
        ) == false)
        #expect(MouseEventHandler.mouseWheelModifiersMatch([.maskAlternate], required: required) == false)
    }

    @Test func mouseResizeModifierMappingsMatchExactly() {
        let relevantFlags: [CGEventFlags] = [.maskAlternate, .maskControl, .maskCommand, .maskShift]

        for key in MouseResizeModifierKey.allCases {
            let required = key.cgEventFlag
            #expect(MouseEventHandler.modifierFlagsMatch(required, required: required))

            for flag in relevantFlags where required.contains(flag) {
                #expect(MouseEventHandler.modifierFlagsMatch(required.subtracting(flag), required: required) == false)
            }

            if let extraFlag = relevantFlags.first(where: { !required.contains($0) }) {
                #expect(MouseEventHandler.modifierFlagsMatch(required.union(extraFlag), required: required) == false)
            }
        }
    }

    @Test @MainActor func mouseWheelHorizontalAxisWinsAndFocusesNextColumn() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 1_000,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex + 1)
        #expect(after.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func mouseWheelAccumulatesDiscreteNiriTicksBeforeFocusingColumn() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 60,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let afterSmallDelta = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(afterSmallDelta.activeColumnIndex == before.activeColumnIndex)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 60,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex + 1)
        #expect(after.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func mouseWheelDefaultSensitivityDoesNotMultiplyNiriTicks() async {
        let fixture = await prepareMouseWheelScrollFixtureWithDefaultSensitivity()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex + 1)
    }

    @Test @MainActor func mouseWheelVerticalShiftFallbackFocusesNextColumn() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 0,
            deltaY: 120,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex + 1)
        #expect(after.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func mouseWheelExtraModifiersDoNotTriggerConfiguredScroll() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag.union(.maskCommand)
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex)
        #expect(after.selectedNodeId == before.selectedNodeId)
    }

    @Test @MainActor func mouseWheelScrollRebasesActiveColumnAfterCrossingColumnBoundary() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let focusedTokenBeforeScroll = fixture.controller.workspaceManager.confirmedManagedFocusToken
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 1_000,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == min(before.activeColumnIndex + Int(1_000 / 120), 4))
        #expect(after.viewOffsetPixels.isGesture == false)
        #expect(after.selectionProgress == 0)

        guard let engine = fixture.controller.niriEngine else {
            Issue.record("Missing Niri engine after mouse wheel scroll")
            return
        }
        let columns = engine.columns(in: fixture.workspaceId)
        guard columns.indices.contains(after.activeColumnIndex) else {
            Issue.record("Mouse wheel scroll rebased to an invalid active column")
            return
        }
        let activeColumn = columns[after.activeColumnIndex]
        let windows = activeColumn.windowNodes
        guard !windows.isEmpty else {
            Issue.record("Mouse wheel scroll rebased to an empty active column")
            return
        }
        let expectedWindow = windows[activeColumn.activeTileIdx.clamped(to: 0 ... (windows.count - 1))]
        #expect(after.selectedNodeId == expectedWindow.id)
        #expect(fixture.controller.workspaceManager.rememberedTiledFocusToken(in: fixture.workspaceId) == expectedWindow
            .token)
        #expect(fixture.controller.workspaceManager.confirmedManagedFocusToken == focusedTokenBeforeScroll)
    }

    @Test @MainActor func trackpadLikeScrollWheelEventDoesNotUseMouseWheelPath() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 50,
            deltaY: 0,
            momentumPhase: 1,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )
        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 70,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex)
        #expect(after.selectedNodeId == before.selectedNodeId)
        #expect(after.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func focusFollowsMouseRefreshesAfterScrollAnimationSettles() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for post-animation focus-follow regression test")
            return
        }

        let focusedHandle = populateNiriWorkspaceForMouseTests(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            monitor: monitor,
            startingWindowId: 960,
            count: 3
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let hoverTarget = engine.columns(in: workspaceId)
            .flatMap(\.windowNodes)
            .compactMap { node -> (WindowModel.Entry, CGPoint)? in
                guard node.token != focusedHandle.token,
                      let entry = controller.workspaceManager.entry(for: node.handle),
                      let frame = node.renderedFrame ?? node.frame
                else { return nil }

                let point = frame.center
                guard engine.hitTestFocusableWindow(point: point, in: workspaceId)?.token == entry.token else {
                    return nil
                }
                return (entry, point)
            }
            .first

        guard let hoverTarget else {
            Issue
                .record(
                    "Expected a hit-testable non-focused Niri window for post-animation focus-follow regression test"
                )
            return
        }

        controller.mouseEventHandler.mouseLocationProvider = { hoverTarget.1 }
        #expect(controller.niriLayoutHandler.registerScrollAnimation(
            workspaceId,
            on: monitor.displayId
        ))

        controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: CACurrentMediaTime() + 5,
            displayId: monitor.displayId
        )

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
        #expect(controller.workspaceManager.pendingFocusedHandle == hoverTarget.0.handle)
    }

    @Test @MainActor func trackpadGestureStartsFromCurrentAnimationOffset() async {
        let fixture = await prepareMouseWheelScrollFixture()
        guard let engine = fixture.controller.niriEngine,
              let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        else {
            Issue.record("Missing Niri context for animation handoff regression test")
            return
        }

        let animationStart = CACurrentMediaTime()
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.viewOffsetPixels = .spring(
                SpringAnimation(
                    from: 20,
                    to: 500,
                    startTime: animationStart,
                    config: .niriHorizontalViewMovement
                )
            )
        }

        fixture.handler.applyTrackpadViewportScrollDelta(
            0,
            engine: engine,
            wsId: fixture.workspaceId,
            monitor: monitor,
            timestamp: animationStart
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let gesture = after.viewOffsetPixels.gestureRef else {
            Issue.record("Expected new trackpad gesture after interrupting animation")
            return
        }
        #expect(abs(gesture.stationaryViewOffset - 20) < 5)
    }

    @Test @MainActor func lockedInputHandlersAreNoOps() async {
        let controller = makeMouseEventTestController()
        controller.isLockScreenActive = true

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        let handler = controller.mouseEventHandler
        handler.dispatchMouseMoved(at: CGPoint(x: 50, y: 50))
        handler.dispatchMouseDown(at: CGPoint(x: 50, y: 50), modifiers: [])
        handler.dispatchMouseDragged(at: CGPoint(x: 60, y: 60))
        handler.dispatchMouseUp(at: CGPoint(x: 60, y: 60))
        handler.dispatchScrollWheel(
            at: CGPoint(x: 50, y: 50),
            deltaX: 0,
            deltaY: 12,
            momentumPhase: 0,
            phase: 0,
            modifiers: []
        )

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ) else {
            Issue.record("Failed to create CGEvent")
            return
        }
        handler.dispatchGestureEvent(from: cgEvent)

        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(handler.state.isMoving == false)
        #expect(handler.state.isResizing == false)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
    }

    @Test @MainActor func receiveTapGestureEventIsSuppressedWhileLocked() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler
        let initialState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        handler.resetDebugStateForTests()
        handler.receiveTapMouseMoved(at: fixture.location)
        controller.isLockScreenActive = true

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        let baseTime = CACurrentMediaTime()
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.70, 0.75, 0.80])
            )
        )

        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let after = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(abs(after.viewOffsetPixels.current() - initialState.viewOffsetPixels.current()) < 0.001)
        #expect(after.activeColumnIndex == initialState.activeColumnIndex)
        #expect(after.selectedNodeId == initialState.selectedNodeId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
        #expect(debugSnapshot.queuedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 0)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func receiveTapScrollWheelDropsLockedEventsBeforeQueueing() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler
        let initialState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let focusedTokenBeforeScroll = controller.workspaceManager.confirmedManagedFocusToken
        controller.isLockScreenActive = true
        handler.resetDebugStateForTests()

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        handler.receiveTapScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: controller.settings.scrollModifierKey.cgEventFlag
        )

        controller.isLockScreenActive = false
        handler.flushPendingTapEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let after = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(after.activeColumnIndex == initialState.activeColumnIndex)
        #expect(after.selectedNodeId == initialState.selectedNodeId)
        #expect(abs(after.viewOffsetPixels.current() - initialState.viewOffsetPixels.current()) < 0.001)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == focusedTokenBeforeScroll)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
        #expect(debugSnapshot.queuedTransientEvents == 0)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func lockTransitionDropsQueuedScrollBeforeUnlock() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler
        let initialState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        handler.resetDebugStateForTests()

        handler.receiveTapScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: controller.settings.scrollModifierKey.cgEventFlag
        )
        #expect(handler.state.pendingTapEvents.hasPendingEvents)

        controller.isLockScreenActive = true
        controller.isLockScreenActive = false
        handler.flushPendingTapEventsForTests()

        let after = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(handler.state.pendingTapEvents.hasPendingEvents == false)
        #expect(after.activeColumnIndex == initialState.activeColumnIndex)
        #expect(after.selectedNodeId == initialState.selectedNodeId)
        #expect(debugSnapshot.queuedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 0)
    }

    @Test @MainActor func resizeEndUsesInteractiveGestureImmediateRelayout() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))

        fixture.handler.state.isResizing = true

        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        fixture.controller.layoutRefreshController.resetDebugState()
        fixture.controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return true
        }

        fixture.handler.dispatchMouseUp(at: fixture.location)
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutEvents.map(\.0) == [.interactiveGesture])
        #expect(relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(fixture.handler.state.isResizing == false)
    }

    @Test @MainActor func queuedMouseMovesCollapseToLatestLocationWithoutArmingResizeHover() async {
        let fixture = await prepareMouseResizeFixture()

        let center = CGPoint(x: fixture.nodeFrame.midX, y: fixture.nodeFrame.midY)
        let rightEdge = CGPoint(x: fixture.nodeFrame.maxX - 1, y: fixture.nodeFrame.midY)

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseMoved(at: center)
        fixture.handler.receiveTapMouseMoved(at: rightEdge)
        fixture.handler.flushPendingTapEventsForTests()

        let debugSnapshot = fixture.handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 2)
        #expect(debugSnapshot.coalescedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 1)
        #expect(fixture.handler.state.currentHoveredEdges == [])
    }

    @Test @MainActor func plainLeftMouseDownOnResizeEdgeDoesNotStartResize() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        let rightEdge = CGPoint(x: fixture.nodeFrame.maxX - 1, y: fixture.nodeFrame.midY)
        fixture.handler.dispatchMouseMoved(at: rightEdge)
        fixture.handler.dispatchMouseDown(at: rightEdge, modifiers: [])

        #expect(fixture.handler.state.isResizing == false)
        #expect(engine.interactiveResize == nil)
        #expect(fixture.handler.state.currentHoveredEdges == [])
    }

    @Test @MainActor func optionRightMouseDragStartsAndUpdatesResize() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine,
              let resizeWindow = engine.findNode(for: fixture.handle),
              let column = engine.findColumn(containing: resizeWindow, in: fixture.workspaceId),
              let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        else {
            Issue.record("Missing Niri resize state")
            return
        }

        let originalWidth = column.cachedWidth
        let insetFrame = fixture.controller.insetWorkingFrame(for: monitor)
        let maxWidth = insetFrame.width
        let expectedWidth = min(originalWidth + 24, maxWidth)
        let start = CGPoint(x: fixture.nodeFrame.maxX - 20, y: fixture.nodeFrame.midY)
        let end = CGPoint(x: start.x + 24, y: start.y)

        fixture.handler.pressedMouseButtonsProvider = { 2 }
        fixture.handler.dispatchMouseDown(at: start, modifiers: [.maskAlternate], button: .right)
        fixture.handler.dispatchMouseDragged(at: end, button: .right)
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: end, button: .right)
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(fixture.handler.state.isResizing == false)
        #expect(engine.interactiveResize == nil)
        #expect(abs(column.cachedWidth - expectedWidth) < 0.001)
    }

    @Test @MainActor func configuredRightMouseResizeModifierStartsResize() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine,
              let resizeWindow = engine.findNode(for: fixture.handle),
              let column = engine.findColumn(containing: resizeWindow, in: fixture.workspaceId),
              let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        else {
            Issue.record("Missing Niri resize state")
            return
        }

        fixture.controller.settings.mouseResizeModifierKey = .controlShift
        let originalWidth = column.cachedWidth
        let insetFrame = fixture.controller.insetWorkingFrame(for: monitor)
        let maxWidth = insetFrame.width
        let expectedWidth = min(originalWidth + 24, maxWidth)
        let start = CGPoint(x: fixture.nodeFrame.maxX - 20, y: fixture.nodeFrame.midY)
        let end = CGPoint(x: start.x + 24, y: start.y)

        fixture.handler.pressedMouseButtonsProvider = { 2 }
        fixture.handler.dispatchMouseDown(at: start, modifiers: [.maskControl, .maskShift], button: .right)
        fixture.handler.dispatchMouseDragged(at: end, button: .right)
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: end, button: .right)
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(fixture.handler.state.isResizing == false)
        #expect(engine.interactiveResize == nil)
        #expect(abs(column.cachedWidth - expectedWidth) < 0.001)
    }

    @Test @MainActor func configuredRightMouseResizeModifierRejectsDefaultAndExtraModifiers() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        fixture.controller.settings.mouseResizeModifierKey = .controlShift
        let start = CGPoint(x: fixture.nodeFrame.maxX - 20, y: fixture.nodeFrame.midY)

        fixture.handler.dispatchMouseDown(at: start, modifiers: [.maskAlternate], button: .right)
        #expect(fixture.handler.state.isResizing == false)
        #expect(engine.interactiveResize == nil)

        fixture.handler.dispatchMouseDown(
            at: start,
            modifiers: [.maskControl, .maskShift, .maskAlternate],
            button: .right
        )
        #expect(fixture.handler.state.isResizing == false)
        #expect(engine.interactiveResize == nil)
    }

    @Test @MainActor func optionRightMouseTapCallbackSuppressesClaimedResizeEvents() async {
        let fixture = await prepareMouseResizeFixture()

        func makeRightMouseEvent(_ type: CGEventType, at location: CGPoint) -> CGEvent? {
            let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: ScreenCoordinateSpace.toWindowServer(point: location),
                mouseButton: .right
            )
            event?.flags = [.maskAlternate]
            return event
        }

        let start = CGPoint(x: fixture.nodeFrame.maxX - 20, y: fixture.nodeFrame.midY)
        let end = CGPoint(x: start.x + 24, y: start.y)

        guard let dragged = makeRightMouseEvent(.rightMouseDragged, at: end),
              let up = makeRightMouseEvent(.rightMouseUp, at: end)
        else {
            Issue.record("Failed to create right mouse CGEvents")
            return
        }

        fixture.handler.pressedMouseButtonsProvider = { 2 }
        let suppressDown = fixture.handler.receiveTapMouseDown(
            at: start,
            modifiers: [.maskAlternate],
            button: .right
        )
        let suppressDragged = fixture.handler.handleTapCallbackForTests(
            type: .rightMouseDragged,
            event: dragged,
            isMainThread: true
        )
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        let suppressUp = fixture.handler.handleTapCallbackForTests(
            type: .rightMouseUp,
            event: up,
            isMainThread: true
        )
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(suppressDown)
        #expect(suppressDragged)
        #expect(suppressUp)
        #expect(fixture.handler.state.isResizing == false)
    }

    @Test @MainActor func queuedResizeDragFlushesBeforeMouseUpUsingLatestLocation() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine,
              let resizeWindow = engine.findNode(for: fixture.handle),
              let column = engine.findColumn(containing: resizeWindow, in: fixture.workspaceId),
              let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        else {
            Issue.record("Missing Niri resize state")
            return
        }

        let originalWidth = column.cachedWidth
        let insetFrame = fixture.controller.insetWorkingFrame(for: monitor)
        let maxWidth = insetFrame.width
        let expectedWidth = min(originalWidth + 24, maxWidth)

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))

        fixture.handler.state.isResizing = true
        fixture.handler.resetDebugStateForTests()

        fixture.handler.receiveTapMouseDragged(
            at: CGPoint(x: fixture.location.x + 8, y: fixture.location.y)
        )
        fixture.handler.receiveTapMouseDragged(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.receiveTapMouseUp(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        let debugSnapshot = fixture.handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 2)
        #expect(debugSnapshot.coalescedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 1)
        #expect(debugSnapshot.flushedBeforeImmediateDispatch == 1)
        #expect(abs(column.cachedWidth - expectedWidth) < 0.001)
        #expect(fixture.handler.state.isResizing == false)
    }

    @Test @MainActor func queuedResizeDragClampsToColumnMaxWidthConstraint() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine,
              let resizeWindow = engine.findNode(for: fixture.handle),
              let column = engine.findColumn(containing: resizeWindow, in: fixture.workspaceId)
        else {
            Issue.record("Missing Niri resize state for max-width regression test")
            return
        }

        let originalWidth = column.cachedWidth
        let cappedWidth = originalWidth + 12
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: 1),
            maxSize: CGSize(width: cappedWidth, height: 0),
            isFixed: false
        )

        fixture.controller.workspaceManager.setCachedConstraints(constraints, for: fixture.handle.id)
        engine.updateWindowConstraints(for: fixture.handle, constraints: constraints)

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))

        fixture.handler.state.isResizing = true
        fixture.handler.receiveTapMouseDragged(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.receiveTapMouseUp(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(abs(column.cachedWidth - cappedWidth) < 0.001)
        #expect(column.cachedWidth <= cappedWidth)
        #expect(fixture.handler.state.isResizing == false)
    }

    @Test @MainActor func mouseTapCallbackStoresWindowUnderPointerForQueuedMouseMove() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 120, y: 140),
            mouseButton: .left
        ) else {
            Issue.record("Failed to create mouse moved event")
            return
        }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 12_345)

        let suppress = handler.handleTapCallbackForTests(
            type: .mouseMoved,
            event: event,
            isMainThread: true
        )

        #expect(suppress == false)
        #expect(handler.state.pendingTapEvents.mouseMovedPayload?.windowUnderPointer == 12_345)
    }

    @Test @MainActor func offMainThreadMouseTapCallbackFailsOpenWithoutQueueingState() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 50, y: 50),
            mouseButton: .left
        ) else {
            Issue.record("Failed to create CGEvent")
            return
        }

        let processed = handler.handleTapCallbackForTests(
            type: .mouseMoved,
            event: event,
            isMainThread: false
        )

        #expect(processed == false)
        #expect(handler.mouseTapDebugSnapshot() == .init())
        #expect(handler.state.pendingTapEvents.hasPendingEvents == false)
        #expect(handler.state.currentHoveredEdges == [])
    }

    @Test @MainActor func offMainThreadGestureTapCallbackFailsOpenWithoutMutatingGestureState() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 50, y: 50),
            mouseButton: .left
        ) else {
            Issue.record("Failed to create CGEvent")
            return
        }

        guard let gestureType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue)) else {
            Issue.record("Failed to create gesture CGEventType")
            return
        }

        let processed = handler.handleGestureTapCallbackForTests(
            type: gestureType,
            event: event,
            isMainThread: false
        )

        #expect(processed == false)
        #expect(handler.state.pendingTapEvents.hasPendingEvents == false)
    }

    @Test @MainActor func gestureTouchAverageRejectsInvalidTouchPositions() {
        let touches: [MouseEventHandler.GestureTouchSample] = [
            .init(phase: .touching, normalizedPosition: CGPoint(x: 0.25, y: 0.5)),
            .init(phase: .touching, normalizedPosition: nil)
        ]

        let average = MouseEventHandler.averageGestureTouchPosition(
            requiredFingers: 2,
            touches: touches
        )

        #expect(average == nil)
    }

    @Test @MainActor func trackpadGestureFinalizesViewportGesture() async {
        let controller = makeMouseEventTestController()
        controller.settings.scrollGestureEnabled = true
        controller.settings.gestureInvertDirection = false
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context for gesture diagnostic trace test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 551),
            pid: getpid(),
            windowId: 551,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 552),
            pid: getpid(),
            windowId: 552,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              controller.workspaceManager.handle(for: secondToken) != nil
        else {
            Issue.record("Missing handles for gesture diagnostic trace test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.ended.rawValue,
                timestamp: baseTime + 0.032,
                touches: []
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(finalizedState.viewOffsetPixels.isGesture == false)
        #expect(finalizedState.viewOffsetPixels.isAnimating)
    }

    @Test @MainActor func unmanagedOverlayWindowServerOverlayPredicateIncludesPositiveLayers() {
        let appFrame = CGRect(x: 50, y: 50, width: 200, height: 160)
        let windowServerFrame = ScreenCoordinateSpace.toWindowServer(rect: appFrame)
        let windows: [[String: Any]] = [
            [
                kCGWindowNumber as String: NSNumber(value: 91_000),
                kCGWindowLayer as String: NSNumber(value: 3),
                kCGWindowIsOnscreen as String: NSNumber(value: true),
                kCGWindowOwnerPID as String: NSNumber(value: 123),
                kCGWindowBounds as String: [
                    "X": NSNumber(value: windowServerFrame.origin.x),
                    "Y": NSNumber(value: windowServerFrame.origin.y),
                    "Width": NSNumber(value: windowServerFrame.width),
                    "Height": NSNumber(value: windowServerFrame.height)
                ]
            ]
        ]

        let covers = WMController.visibleUnmanagedOverlayWindowServerWindowCovers(
            point: appFrame.center,
            windows: windows,
            ownerActivationPolicyProvider: { _ in .regular }
        )

        #expect(covers == true)
    }

    @Test @MainActor func trackpadGestureIgnoresSnapshotOnlyOverlayWhenEventWindowIsMissing() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler
        let baseTime = CACurrentMediaTime()
        var overlayProbeCount = 0
        controller.unmanagedOverlayWindowServerWindowCoversOverride = { _ in
            overlayProbeCount += 1
            return true
        }
        controller.toggleRuntimeTraceCapture(desiredState: .active)

        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
            )
        )

        let mouseTraces = controller.runtimeMouseTraceRecordsForTests()
        let viewportTraces = controller.runtimeViewportTraceRecordsForTests()
        #expect(overlayProbeCount == 0)
        #expect(mouseTraces.contains { $0.contains("gesture.skip reason=unmanagedOverlay") } == false)
        #expect(mouseTraces.contains { $0.contains("gesture.skip reason=suppressed") } == false)
        #expect(viewportTraces.contains { $0.contains("reason=touch_scroll_gesture_armed") })
        #expect(viewportTraces.contains { $0.contains("reason=touch_scroll_gesture_committed") })
        #expect(handler.state.gesturePhase == .committed)
        #expect(handler.state.lockedGestureContext != nil)
        #expect(handler.state.suppressGestureUntilTouchesEnd == false)
    }

    @Test @MainActor func trackpadGestureSuppressesViaEventWindowUnderPointerWithoutSnapshot() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler
        let baseTime = CACurrentMediaTime()
        var snapshotCalls = 0
        controller.unmanagedWindowServerWindowFramesProvider = { _ in
            snapshotCalls += 1
            return []
        }
        controller.toggleRuntimeTraceCapture(desiredState: .active)

        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                windowUnderPointer: 55_555,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                windowUnderPointer: 55_555,
                touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
            )
        )

        let mouseTraces = controller.runtimeMouseTraceRecordsForTests()
        #expect(snapshotCalls == 0)
        #expect(mouseTraces.contains {
            $0.contains("gesture.skip reason=unmanagedOverlay")
                && $0.contains("windowUnderPointer=55555")
                && $0.contains("snapshotProbe=false")
        })
        #expect(mouseTraces.contains {
            $0.contains("gesture.skip reason=suppressed")
        })
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(handler.state.suppressGestureUntilTouchesEnd == true)
    }

    @Test @MainActor func suppressedTrackpadGestureClearsOnEndedCancelledOrNoActiveTouches() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let handler = fixture.handler
        let baseTime = CACurrentMediaTime()

        handler.state.suppressGestureUntilTouchesEnd = true
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.ended.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30], phase: .ended)
            )
        )
        #expect(handler.state.suppressGestureUntilTouchesEnd == false)

        handler.state.suppressGestureUntilTouchesEnd = true
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.cancelled.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30], phase: .cancelled)
            )
        )
        #expect(handler.state.suppressGestureUntilTouchesEnd == false)

        handler.state.suppressGestureUntilTouchesEnd = true
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.032,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30], phase: .ended)
            )
        )
        #expect(handler.state.suppressGestureUntilTouchesEnd == false)
    }

    @Test @MainActor func trackpadGestureFocusSuppressesMouseMoveToFocusedWindow() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        controller.settings.gestureInvertDirection = false
        controller.settings.scrollGestureEnabled = true
        controller.setMoveMouseToFocusedWindow(true)

        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine for trackpad focus warp suppression test")
            return
        }

        let baseTime = CACurrentMediaTime()
        fixture.handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        fixture.handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
            )
        )
        fixture.handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.ended.rawValue,
                timestamp: baseTime + 0.032,
                touches: []
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let selectedNodeId = finalizedState.selectedNodeId,
              let selectedWindow = engine.findNode(by: selectedNodeId) as? NiriWindow
        else {
            Issue.record("Missing selected niri window after trackpad gesture")
            return
        }

        #expect(controller.shouldSuppressMouseMoveToFocusedWindow(for: selectedWindow.token))
    }

    @Test @MainActor func trackpadGestureDoesNotCommitSelectedFocusWhenFocusFollowsMouseIsEnabled() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        controller.settings.gestureInvertDirection = false
        controller.settings.scrollGestureEnabled = true
        controller.setFocusFollowsMouse(true)

        guard let engine = controller.niriEngine,
              let focusedBefore = controller.workspaceManager.confirmedManagedFocusToken
        else {
            Issue.record("Missing Niri engine or focused token for FFM gesture focus test")
            return
        }

        let baseTime = CACurrentMediaTime()
        fixture.handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        fixture.handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
            )
        )
        fixture.handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.ended.rawValue,
                timestamp: baseTime + 0.032,
                touches: []
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let selectedNodeId = finalizedState.selectedNodeId,
              let selectedWindow = engine.findNode(by: selectedNodeId) as? NiriWindow
        else {
            Issue.record("Missing selected niri window after trackpad gesture")
            return
        }

        #expect(selectedWindow.token != focusedBefore)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == focusedBefore)
    }

    @Test @MainActor func trackpadGestureWaitsForNiriRecognitionThreshold() async {
        let controller = makeMouseEventTestController()
        controller.settings.scrollGestureEnabled = true
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for gesture recognition threshold test")
            return
        }

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
        let baselineState = controller.workspaceManager.niriViewportState(for: workspaceId)
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.50, 0.50, 0.50])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.51, 0.51, 0.51])
            )
        )

        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .armed)
        #expect(handler.state.lockedGestureContext?.workspaceId == workspaceId)
        #expect(updatedState.viewOffsetPixels.target() == baselineState.viewOffsetPixels.target())
        #expect(updatedState.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func trackpadGestureCommitAppliesCumulativeArmedDelta() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        controller.settings.gestureInvertDirection = false
        let handler = fixture.handler
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.20, 0.20])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.215, 0.215, 0.215])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.032,
                touches: makeGestureTouchSamples(xPositions: [0.235, 0.235, 0.235])
            )
        )

        let updatedState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let monitor = controller.workspaceManager.monitor(for: fixture.workspaceId) else {
            Issue.record("Missing monitor for trackpad cumulative-delta regression test")
            return
        }
        let viewportWidth = controller.insetWorkingFrame(for: monitor).width
        guard let gesture = updatedState.viewOffsetPixels.gestureRef else {
            Issue.record("Expected in-flight viewport gesture after crossing threshold")
            return
        }
        let expectedAppliedDelta = CGFloat((0.235 - 0.20) * 500.0) * viewportWidth / 1200.0
        let actualAppliedDelta = CGFloat(gesture.currentViewOffset - gesture.stationaryViewOffset)
        #expect(handler.state.gesturePhase == .committed)
        #expect(abs(actualAppliedDelta - expectedAppliedDelta) < 0.1)
    }

    @Test @MainActor func trackpadGestureCommitDoesNotReverseOnThresholdJitter() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        controller.settings.gestureInvertDirection = false
        let handler = fixture.handler
        let baseTime = CACurrentMediaTime()

        func touches(x: CGFloat, y: CGFloat) -> [MouseEventHandler.GestureTouchSample] {
            makeGestureTouchSamples(xPositions: [x, x, x], yPosition: y)
        }

        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: touches(x: 0.20, y: 0.50)
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: touches(x: 0.225, y: 0.50)
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.032,
                touches: touches(x: 0.224, y: 0.522)
            )
        )

        let updatedState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let gesture = updatedState.viewOffsetPixels.gestureRef else {
            Issue.record("Expected in-flight viewport gesture after crossing threshold")
            return
        }
        let actualAppliedDelta = CGFloat(gesture.currentViewOffset - gesture.stationaryViewOffset)
        #expect(handler.state.gesturePhase == .committed)
        #expect(actualAppliedDelta > 0)
    }

    @Test @MainActor func committedTrackpadGestureKeepsSubPixelDeltasForVelocity() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        controller.settings.gestureInvertDirection = false
        let handler = fixture.handler
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.20, 0.20])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.24, 0.24, 0.24])
            )
        )

        let beforeTinyDelta = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let beforeGesture = beforeTinyDelta.viewOffsetPixels.gestureRef else {
            Issue.record("Expected committed gesture before tiny delta")
            return
        }
        let beforeOffset = beforeGesture.currentViewOffset

        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.032,
                touches: makeGestureTouchSamples(xPositions: [0.2404, 0.2404, 0.2404])
            )
        )

        let afterTinyDelta = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let afterGesture = afterTinyDelta.viewOffsetPixels.gestureRef else {
            Issue.record("Expected committed gesture after tiny delta")
            return
        }
        #expect(afterGesture.currentViewOffset > beforeOffset)
    }

    @Test @MainActor func verticalDominantThreeFingerGestureDoesNotScrollViewport() async {
        let controller = makeMouseEventTestController()
        controller.settings.scrollGestureEnabled = true
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for vertical gesture rejection test")
            return
        }

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
        let baselineState = controller.workspaceManager.niriViewportState(for: workspaceId)
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.50, 0.50, 0.50])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(
                    xPositions: [0.51, 0.51, 0.51],
                    yPosition: 0.62
                )
            )
        )

        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(updatedState.viewOffsetPixels.target() == baselineState.viewOffsetPixels.target())
        #expect(updatedState.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func committedTrackpadGestureFinalizesWhenFingerSetDropsDuringLift() async {
        let controller = makeMouseEventTestController()
        controller.settings.scrollGestureEnabled = true
        controller.settings.gestureInvertDirection = false
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context for trackpad release regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 561),
            pid: getpid(),
            windowId: 561,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 562),
            pid: getpid(),
            windowId: 562,
            to: workspaceId
        )
        _ = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 563),
            pid: getpid(),
            windowId: 563,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken) else {
            Issue.record("Missing first handle for trackpad release regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        guard engine.findNode(for: secondToken) != nil else {
            Issue.record("Missing second node for trackpad release regression test")
            return
        }
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 900
            column.cachedHeight = 800
        }
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        let focusedTokenBeforeGesture = controller.workspaceManager.confirmedManagedFocusToken
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
            )
        )

        let inFlightState = controller.workspaceManager.niriViewportState(for: workspaceId)
        guard let gesture = inFlightState.viewOffsetPixels.gestureRef else {
            Issue.record("Expected committed gesture before partial finger lift")
            return
        }
        let columns = engine.columns(in: workspaceId)
        let expectedActiveColumnIndex = columns.count - 1
        guard columns.indices.contains(expectedActiveColumnIndex),
              !columns[expectedActiveColumnIndex].windowNodes.isEmpty
        else {
            Issue.record("Expected a target Niri column for trackpad release regression test")
            return
        }
        let expectedSelectedNode = columns[expectedActiveColumnIndex].windowNodes[
            columns[expectedActiveColumnIndex].activeTileIdx
                .clamped(to: 0 ... (columns[expectedActiveColumnIndex].windowNodes.count - 1))
        ]
        _ = gesture

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: 0,
                timestamp: baseTime + 0.032,
                touches: [
                    .init(phase: .touching, normalizedPosition: CGPoint(x: 0.62, y: 0.5)),
                    .init(phase: .ended, normalizedPosition: CGPoint(x: 0.65, y: 0.5)),
                    .init(phase: .ended, normalizedPosition: CGPoint(x: 0.70, y: 0.5))
                ]
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(finalizedState.viewOffsetPixels.isGesture == false)
        #expect(finalizedState.viewOffsetPixels.isAnimating == true)
        #expect(finalizedState.activeColumnIndex == expectedActiveColumnIndex)
        #expect(finalizedState.selectedNodeId == expectedSelectedNode.id)
        #expect(controller.workspaceManager.rememberedTiledFocusToken(in: workspaceId) == expectedSelectedNode.token)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == focusedTokenBeforeGesture)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
    }

    @Test @MainActor func committedTrackpadGestureResetsWhenControllerIsDisabled() async {
        let (controller, handler, workspaceId, location) = await prepareCommittedTrackpadGestureFixture()
        #expect(handler.state.gesturePhase == .committed)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).viewOffsetPixels.isGesture)

        controller.isEnabled = false
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                touches: makeGestureTouchSamples(xPositions: [0.70, 0.75, 0.80])
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(finalizedState.viewOffsetPixels.isGesture == false)
        #expect(finalizedState.viewOffsetPixels.isAnimating)
    }

    @Test @MainActor func committedTrackpadGestureResetsWhenScrollGesturesAreDisabled() async {
        let (controller, handler, workspaceId, location) = await prepareCommittedTrackpadGestureFixture()
        #expect(handler.state.gesturePhase == .committed)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).viewOffsetPixels.isGesture)

        controller.settings.scrollGestureEnabled = false
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                touches: makeGestureTouchSamples(xPositions: [0.70, 0.75, 0.80])
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(finalizedState.viewOffsetPixels.isGesture == false)
        #expect(finalizedState.viewOffsetPixels.isAnimating)
    }

    @Test @MainActor func scrollBurstOnlyMergesWithinMatchingModifierAndPhaseGroups() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        handler.resetDebugStateForTests()
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 0,
            deltaY: 4,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate]
        )
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 0,
            deltaY: 6,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate]
        )
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 0,
            deltaY: 8,
            momentumPhase: 1,
            phase: 0,
            modifiers: [.maskAlternate]
        )
        handler.flushPendingTapEventsForTests()

        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 3)
        #expect(debugSnapshot.coalescedTransientEvents == 1)
        #expect(debugSnapshot.drainRuns == 2)
        #expect(debugSnapshot.drainedTransientEvents == 2)
    }

    @Test @MainActor func scrollBurstFlushesBeforeDirectionChanges() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        handler.resetDebugStateForTests()
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 60,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate, .maskShift]
        )
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: -60,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate, .maskShift]
        )
        handler.flushPendingTapEventsForTests()

        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 2)
        #expect(debugSnapshot.coalescedTransientEvents == 0)
        #expect(debugSnapshot.drainRuns == 2)
        #expect(debugSnapshot.drainedTransientEvents == 2)
    }

    @Test @MainActor func ownedWindowMouseDownDropsQueuedTapEventsInsteadOfFlushingThem() {
        var frontmostWindow: NSWindow?
        let registry = makeOwnedMouseWindowRegistry { frontmostWindow }
        let controller = makeMouseEventTestController(ownedWindowRegistry: registry)
        let handler = controller.mouseEventHandler
        let window = makeOwnedUtilityTestWindow()

        frontmostWindow = window
        registry.register(window)
        defer {
            registry.unregister(window)
            window.close()
            registry.resetForTests()
        }

        handler.resetDebugStateForTests()
        let pointInsideOwnedWindow = CGPoint(x: window.frame.midX, y: window.frame.midY)

        handler.receiveTapMouseMoved(at: CGPoint(x: 10, y: 10))
        #expect(handler.state.pendingTapEvents.hasPendingEvents)
        #expect(registry.contains(point: pointInsideOwnedWindow))

        handler.receiveTapMouseDown(at: pointInsideOwnedWindow, modifiers: [])

        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.flushedBeforeImmediateDispatch == 0)
        #expect(debugSnapshot.drainRuns == 0)
        #expect(debugSnapshot.drainedTransientEvents == 0)
        #expect(handler.state.pendingTapEvents.hasPendingEvents == false)
    }

    @Test @MainActor func visibleNonFrontmostUtilityWindowDoesNotAbortTrackpadGesture() async {
        var frontmostWindow: NSWindow?
        let registry = makeOwnedMouseWindowRegistry { frontmostWindow }
        let fixture = await prepareMouseWheelScrollFixture(ownedWindowRegistry: registry)
        let window = NSWindow(
            contentRect: CGRect(x: fixture.location.x - 40, y: fixture.location.y - 40, width: 80, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let frontWindow = makeOwnedUtilityTestWindow(
            frame: CGRect(x: fixture.location.x - 50, y: fixture.location.y - 50, width: 100, height: 100)
        )
        frontmostWindow = frontWindow
        registry.register(window)
        defer {
            registry.unregister(window)
            window.close()
            frontWindow.close()
            registry.resetForTests()
        }

        #expect(window.isVisible)
        #expect(registry.contains(point: fixture.location) == false)
        sendCommittingTrackpadGesture(to: fixture.handler, at: fixture.location)

        #expect(fixture.handler.state.gesturePhase == .committed)
    }

    @Test @MainActor func frontmostUtilityWindowStillBlocksTrackpadGesture() async {
        var frontmostWindow: NSWindow?
        let registry = makeOwnedMouseWindowRegistry { frontmostWindow }
        let fixture = await prepareMouseWheelScrollFixture(ownedWindowRegistry: registry)
        let window = makeOwnedUtilityTestWindow(
            frame: CGRect(x: fixture.location.x - 40, y: fixture.location.y - 40, width: 80, height: 80)
        )
        frontmostWindow = window
        registry.register(window)
        defer {
            registry.unregister(window)
            window.close()
            registry.resetForTests()
        }

        #expect(registry.contains(point: fixture.location))
        sendCommittingTrackpadGesture(to: fixture.handler, at: fixture.location)

        #expect(fixture.handler.state.gesturePhase == .idle)
    }

    @Test @MainActor func ownedWindowDragCancelsActiveNiriMoveAndResize() async {
        var frontmostWindow: NSWindow?
        let registry = makeOwnedMouseWindowRegistry { frontmostWindow }
        let fixture = await prepareMouseResizeFixture(ownedWindowRegistry: registry)
        guard let engine = fixture.controller.niriEngine,
              let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        else {
            Issue.record("Missing Niri context for owned-window drag cancellation test")
            return
        }

        let ownedWindow = makeOwnedUtilityTestWindow(
            frame: CGRect(x: fixture.location.x - 40, y: fixture.location.y - 40, width: 80, height: 80)
        )
        frontmostWindow = ownedWindow
        registry.register(ownedWindow)
        defer {
            registry.unregister(ownedWindow)
            ownedWindow.close()
            registry.resetForTests()
        }

        var moveStarted = false
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            moveStarted = engine.interactiveMoveBegin(
                windowId: fixture.nodeId,
                windowHandle: fixture.handle,
                startLocation: fixture.location,
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.controller.insetWorkingFrame(for: monitor),
                gaps: fixture.controller.gapSize(for: monitor)
            )
        }
        #expect(moveStarted)
        fixture.handler.state.isMoving = true

        fixture.handler.dispatchMouseDragged(at: fixture.location)

        #expect(fixture.handler.state.isMoving == false)
        #expect(engine.interactiveMove == nil)

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))
        fixture.handler.state.isResizing = true

        fixture.handler.dispatchMouseDragged(at: fixture.location)

        #expect(fixture.handler.state.isResizing == false)
        #expect(engine.interactiveResize == nil)
    }

    @Test @MainActor func queuedFocusFollowsMouseUsesCurrentPointerForStaleMouseMove() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for stale queued focus-follow regression test")
            return
        }

        let focusedHandle = populateNiriWorkspaceForMouseTests(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            monitor: monitor,
            startingWindowId: 970,
            count: 2
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let focusedNode = engine.findNode(for: focusedHandle),
              let focusedFrame = focusedNode.renderedFrame ?? focusedNode.frame,
              let staleHoverNode = engine.columns(in: workspaceId)
              .flatMap(\.windowNodes)
              .first(where: { $0.token != focusedHandle.token }),
              let staleHoverFrame = staleHoverNode.renderedFrame ?? staleHoverNode.frame
        else {
            Issue.record("Missing node frames for stale queued focus-follow regression test")
            return
        }

        controller.mouseEventHandler.mouseLocationProvider = { focusedFrame.center }
        controller.mouseEventHandler.receiveTapMouseMoved(at: staleHoverFrame.center)
        controller.mouseEventHandler.flushPendingTapEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.confirmedManagedFocusToken == focusedHandle.token)
        #expect(controller.workspaceManager.activeFocusRequestToken == nil)
    }

    @Test @MainActor func focusFollowsMouseReassertsConfirmedWindowWhenPointerReturnsBeforePendingFocusConfirms() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for pending focus-follow reassertion regression test")
            return
        }

        let focusedHandle = populateNiriWorkspaceForMouseTests(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            monitor: monitor,
            startingWindowId: 980,
            count: 2
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let focusedNode = engine.findNode(for: focusedHandle),
              let focusedFrame = focusedNode.renderedFrame ?? focusedNode.frame,
              let otherNode = engine.columns(in: workspaceId)
              .flatMap(\.windowNodes)
              .first(where: { $0.token != focusedHandle.token }),
              let otherFrame = otherNode.renderedFrame ?? otherNode.frame
        else {
            Issue.record("Missing node frames for pending focus-follow reassertion regression test")
            return
        }

        controller.mouseEventHandler.dispatchMouseMoved(at: otherFrame.center)
        #expect(controller.workspaceManager.activeFocusRequestToken == otherNode.token)

        controller.mouseEventHandler.dispatchMouseMoved(at: focusedFrame.center)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == focusedHandle.token)
        #expect(controller.workspaceManager.activeFocusRequestToken == focusedHandle.token)
    }

    @Test @MainActor func focusFollowsMouseAllowsRapidTargetChangeInsideDebounceWindow() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for rapid focus-follow regression test")
            return
        }

        let focusedHandle = populateNiriWorkspaceForMouseTests(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            monitor: monitor,
            startingWindowId: 990,
            count: 2
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let otherNode = engine.columns(in: workspaceId)
            .flatMap(\.windowNodes)
            .first(where: { $0.token != focusedHandle.token }),
            let otherFrame = otherNode.renderedFrame ?? otherNode.frame
        else {
            Issue.record("Missing node frame for rapid focus-follow regression test")
            return
        }

        controller.mouseEventHandler.state.lastFocusFollowsMouseTime = Date()
        controller.mouseEventHandler.state.lastFocusFollowsMouseToken = focusedHandle.token

        controller.mouseEventHandler.dispatchMouseMoved(at: otherFrame.center)

        #expect(controller.workspaceManager.confirmedManagedFocusToken == focusedHandle.token)
        #expect(controller.workspaceManager.activeFocusRequestToken == otherNode.token)
    }

    @Test @MainActor func focusFollowsMouseIgnoresCoveredTileBehindManagedFullscreen() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for fullscreen focus-follow regression test")
            return
        }

        let coveredToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 921),
            pid: getpid(),
            windowId: 921,
            to: workspaceId
        )
        let fullscreenToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 922),
            pid: getpid(),
            windowId: 922,
            to: workspaceId
        )
        guard let coveredHandle = controller.workspaceManager.handle(for: coveredToken),
              let fullscreenHandle = controller.workspaceManager.handle(for: fullscreenToken)
        else {
            Issue.record("Missing handles for fullscreen focus-follow regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: fullscreenHandle
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let coveredNode = engine.findNode(for: coveredHandle),
              let coveredFrame = coveredNode.frame,
              let fullscreenNode = engine.findNode(for: fullscreenHandle)
        else {
            Issue.record("Missing node frames for fullscreen focus-follow regression test")
            return
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = fullscreenNode.id
            engine.toggleFullscreen(fullscreenNode, state: &state)
        }
        _ = controller.workspaceManager.setManagedFocus(fullscreenHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let overlapPoint = CGPoint(x: coveredFrame.midX, y: coveredFrame.midY)
        #expect(coveredFrame.contains(overlapPoint))

        controller.mouseEventHandler.dispatchMouseMoved(at: overlapPoint)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.focusedHandle == fullscreenHandle)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
    }

    @Test @MainActor func focusFollowsMouseDoesNotActivateTiledWindowBehindFloatingWindow() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for floating hover occlusion regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 931),
            pid: getpid(),
            windowId: 931,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 932),
            pid: getpid(),
            windowId: 932,
            to: workspaceId
        )
        let floatingToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 933),
            pid: getpid(),
            windowId: 933,
            to: workspaceId,
            mode: .floating
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for floating hover occlusion regression test")
            return
        }

        let tiledHandles = [firstHandle, secondHandle]
        _ = engine.syncWindows(
            tiledHandles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let secondFrame = secondNode.frame
        else {
            Issue.record("Missing tiled target frame for floating hover occlusion regression test")
            return
        }

        let floatingFrame = CGRect(
            x: secondFrame.midX - 80,
            y: secondFrame.midY - 60,
            width: 160,
            height: 120
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: floatingFrame,
            for: floatingToken,
            restoreToFloating: true
        )

        controller.mouseEventHandler.dispatchMouseMoved(at: floatingFrame.center)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.confirmedManagedFocusToken == firstToken)
        #expect(controller.workspaceManager.activeFocusRequestToken == nil)
    }

    @Test @MainActor func focusFollowsMouseDoesNotActivateTiledWindowBehindUnmanagedWindow() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for unmanaged hover occlusion regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 934),
            pid: getpid(),
            windowId: 934,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 935),
            pid: getpid(),
            windowId: 935,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for unmanaged hover occlusion regression test")
            return
        }

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let secondFrame = secondNode.frame
        else {
            Issue.record("Missing tiled target frame for unmanaged hover occlusion regression test")
            return
        }

        let unmanagedFrame = CGRect(
            x: secondFrame.midX - 80,
            y: secondFrame.midY - 60,
            width: 160,
            height: 120
        )
        controller.unmanagedOverlayWindowInfoProvider = {
            [makeUnmanagedOverlayWindowInfo(windowId: 9340, pid: 55555, appKitFrame: unmanagedFrame)]
        }
        controller.ownerAppIsInteractiveApplicationProvider = { _ in true }

        controller.mouseEventHandler.dispatchMouseMoved(at: unmanagedFrame.center)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.confirmedManagedFocusToken == firstToken)
        #expect(controller.workspaceManager.activeFocusRequestToken == nil)
    }

    @Test @MainActor func mouseDraggedDoesNotPollWindowServerSnapshotWhenEventWindowIsUnavailable() {
        let controller = makeMouseEventTestController()
        var snapshotCalls = 0
        controller.unmanagedWindowServerWindowFramesProvider = { _ in
            snapshotCalls += 1
            return [CGRect(x: 0, y: 0, width: 200, height: 200)]
        }

        controller.mouseEventHandler.dispatchMouseDragged(at: CGPoint(x: 100, y: 100))

        #expect(snapshotCalls == 0)
    }

    @Test @MainActor func focusFollowsMouseSuppressesViaEventWindowUnderPointerWithoutSnapshot() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for event-window unmanaged hover test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 936),
            pid: getpid(),
            windowId: 936,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 937),
            pid: getpid(),
            windowId: 937,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for event-window unmanaged hover test")
            return
        }

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let secondFrame = secondNode.frame
        else {
            Issue.record("Missing tiled target frame for event-window unmanaged hover test")
            return
        }

        var snapshotCalls = 0
        controller.unmanagedWindowServerWindowFramesProvider = { _ in
            snapshotCalls += 1
            return []
        }

        controller.mouseEventHandler.dispatchMouseMoved(
            at: secondFrame.center,
            windowUnderPointer: 44_444
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(snapshotCalls == 0)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == firstToken)
        #expect(controller.workspaceManager.activeFocusRequestToken == nil)
    }

    @Test @MainActor func focusFollowsMouseDoesNotActivateTiledWindowWhileFloatingWindowIsVisible() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for visible floating focus-follow regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 929),
            pid: getpid(),
            windowId: 929,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 930),
            pid: getpid(),
            windowId: 930,
            to: workspaceId
        )
        let floatingToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 928),
            pid: getpid(),
            windowId: 928,
            to: workspaceId,
            mode: .floating
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken),
              let floatingHandle = controller.workspaceManager.handle(for: floatingToken)
        else {
            Issue.record("Missing handles for visible floating focus-follow regression test")
            return
        }

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(floatingHandle, in: workspaceId, onMonitor: monitor.id)
        let floatingFrame = CGRect(
            x: monitor.visibleFrame.midX - 100,
            y: monitor.visibleFrame.midY - 80,
            width: 200,
            height: 160
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: floatingFrame,
            for: floatingToken,
            restoreToFloating: true
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let secondFrame = secondNode.frame
        else {
            Issue.record("Missing tiled target frame for visible floating focus-follow regression test")
            return
        }
        let tiledPointOutsideFloating = CGPoint(x: secondFrame.midX, y: secondFrame.minY + 24)
        #expect(secondFrame.contains(tiledPointOutsideFloating))
        #expect(!floatingFrame.contains(tiledPointOutsideFloating))

        controller.mouseEventHandler.dispatchMouseMoved(at: tiledPointOutsideFloating)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.confirmedManagedFocusToken == floatingToken)
        #expect(controller.workspaceManager.activeFocusRequestToken == nil)
    }

    @Test @MainActor func focusFollowsMouseActivatesTiledWindowWhenFloatingWindowIsBehindActiveTile() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for behind-floating focus-follow regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 931),
            pid: getpid(),
            windowId: 931,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 932),
            pid: getpid(),
            windowId: 932,
            to: workspaceId
        )
        let floatingToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 933),
            pid: getpid(),
            windowId: 933,
            to: workspaceId,
            mode: .floating
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for behind-floating focus-follow regression test")
            return
        }

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(
                x: monitor.visibleFrame.midX - 100,
                y: monitor.visibleFrame.midY - 80,
                width: 200,
                height: 160
            ),
            for: floatingToken,
            restoreToFloating: true
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let secondFrame = secondNode.frame
        else {
            Issue.record("Missing tiled target frame for behind-floating focus-follow regression test")
            return
        }

        controller.mouseEventHandler.dispatchMouseMoved(at: CGPoint(x: secondFrame.midX, y: secondFrame.minY + 24))
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.pendingFocusedHandle == secondHandle)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == firstToken)
    }

    @Test @MainActor func floatingMouseInitiatedFocusDoesNotMoveMouseToFocusedWindow() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setMoveMouseToFocusedWindow(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for floating mouse warp regression test")
            return
        }

        let tiledToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 939),
            pid: getpid(),
            windowId: 939,
            to: workspaceId
        )
        let floatingToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 940),
            pid: getpid(),
            windowId: 940,
            to: workspaceId,
            mode: .floating
        )
        guard let tiledHandle = controller.workspaceManager.handle(for: tiledToken),
              let floatingEntry = controller.workspaceManager.entry(for: floatingToken)
        else {
            Issue.record("Missing handles for floating mouse warp regression test")
            return
        }

        _ = engine.syncWindows(
            [tiledHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: tiledHandle
        )
        _ = controller.workspaceManager.setManagedFocus(tiledHandle, in: workspaceId, onMonitor: monitor.id)
        let floatingFrame = CGRect(x: 200, y: 120, width: 300, height: 220)
        controller.workspaceManager.updateFloatingGeometry(
            frame: floatingFrame,
            for: floatingToken,
            restoreToFloating: true
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        var warpedPoints: [CGPoint] = []
        controller.warpMouseCursorPosition = { point in
            warpedPoints.append(point)
        }

        controller.mouseEventHandler.dispatchMouseDown(at: floatingFrame.center, modifiers: [])
        controller.axEventHandler.handleManagedAppActivation(
            entry: floatingEntry,
            isWorkspaceActive: true,
            appFullscreen: false,
            source: .focusedWindowChanged,
            confirmRequest: true
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.confirmedManagedFocusToken == floatingToken)
        #expect(warpedPoints.isEmpty)
    }

    @Test @MainActor func focusFollowsMouseDoesNotStealFocusDuringRecentFloatingPointerInteraction() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for floating pointer interaction regression test")
            return
        }

        let tiledToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 936),
            pid: getpid(),
            windowId: 936,
            to: workspaceId
        )
        let secondTiledToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 937),
            pid: getpid(),
            windowId: 937,
            to: workspaceId
        )
        let floatingToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 938),
            pid: getpid(),
            windowId: 938,
            to: workspaceId,
            mode: .floating
        )
        guard let tiledHandle = controller.workspaceManager.handle(for: tiledToken),
              let secondTiledHandle = controller.workspaceManager.handle(for: secondTiledToken),
              let floatingHandle = controller.workspaceManager.handle(for: floatingToken)
        else {
            Issue.record("Missing handles for floating pointer interaction regression test")
            return
        }

        _ = engine.syncWindows(
            [tiledHandle, secondTiledHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: tiledHandle
        )
        _ = controller.workspaceManager.setManagedFocus(floatingHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondTiledHandle),
              let secondFrame = secondNode.frame
        else {
            Issue.record("Missing tiled target frame for floating pointer interaction regression test")
            return
        }

        let floatingFrame = CGRect(
            x: secondFrame.midX - 120,
            y: secondFrame.midY - 80,
            width: 160,
            height: 120
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: floatingFrame,
            for: floatingToken,
            restoreToFloating: true
        )

        let tiledPointOutsideFloating = CGPoint(x: floatingFrame.maxX + 40, y: floatingFrame.midY)
        #expect(secondFrame.contains(tiledPointOutsideFloating))
        #expect(!floatingFrame.contains(tiledPointOutsideFloating))

        controller.mouseEventHandler.dispatchMouseDown(at: floatingFrame.center, modifiers: [])
        controller.mouseEventHandler.dispatchMouseDragged(at: tiledPointOutsideFloating)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.confirmedManagedFocusToken == floatingToken)
        #expect(controller.workspaceManager.activeFocusRequestToken == nil)
    }

    @Test @MainActor func mouseInitiatedFocusDoesNotMoveMouseToFocusedWindow() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setMoveMouseToFocusedWindow(true)
        controller.setFocusFollowsMouse(false)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for mouse-initiated focus warp regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 941),
            pid: getpid(),
            windowId: 941,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 942),
            pid: getpid(),
            windowId: 942,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken),
              let secondEntry = controller.workspaceManager.entry(for: secondToken)
        else {
            Issue.record("Missing handles for mouse-initiated focus warp regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let secondFrame = secondNode.frame
        else {
            Issue.record("Missing clicked node frame for mouse-initiated focus warp regression test")
            return
        }

        var warpedPoints: [CGPoint] = []
        controller.warpMouseCursorPosition = { point in
            warpedPoints.append(point)
        }

        controller.mouseEventHandler.dispatchMouseDown(
            at: CGPoint(x: secondFrame.midX, y: secondFrame.midY),
            modifiers: []
        )
        controller.axEventHandler.handleManagedAppActivation(
            entry: secondEntry,
            isWorkspaceActive: true,
            appFullscreen: false,
            source: .focusedWindowChanged,
            confirmRequest: true
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.confirmedManagedFocusToken == secondToken)
        #expect(warpedPoints.isEmpty)
    }

    @Test @MainActor func focusFollowsMouseReactivatesLastHoveredWindowAfterGestureFocusChange() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for repeated hover focus regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 951),
            pid: getpid(),
            windowId: 951,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 952),
            pid: getpid(),
            windowId: 952,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for repeated hover focus regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let secondFrame = secondNode.renderedFrame ?? secondNode.frame
        else {
            Issue.record("Missing second node frame for repeated hover focus regression test")
            return
        }

        let hoverPoint = CGPoint(x: secondFrame.midX, y: secondFrame.midY)
        controller.mouseEventHandler.dispatchMouseMoved(at: hoverPoint)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        #expect(controller.workspaceManager.pendingFocusedHandle == secondHandle)

        _ = controller.workspaceManager.confirmManagedFocus(
            firstToken,
            in: workspaceId,
            onMonitor: monitor.id,
            appFullscreen: false,
            activateWorkspaceOnMonitor: false
        )
        controller.mouseEventHandler.resetFocusFollowsMouseTimeForTesting()

        controller.mouseEventHandler.dispatchMouseMoved(at: hoverPoint)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.pendingFocusedHandle == secondHandle)
    }

    @Test @MainActor func focusFollowsMouseActivatesVisibleNiriWindowWithoutRecenteringViewport() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for hover focus-follow viewport regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 931),
            pid: getpid(),
            windowId: 931,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 932),
            pid: getpid(),
            windowId: 932,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for Niri hover focus-follow viewport regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let secondColumn = engine.column(of: secondNode),
              let secondColumnIndex = engine.columnIndex(of: secondColumn, in: workspaceId),
              let hoveredFrame = secondNode.frame
        else {
            Issue.record("Missing second node frame for Niri hover focus-follow viewport regression test")
            return
        }

        let initialState = controller.workspaceManager.niriViewportState(for: workspaceId)

        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: hoveredFrame.midX, y: hoveredFrame.midY)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(controller.workspaceManager.focusedHandle == firstHandle)
        #expect(controller.workspaceManager.pendingFocusedHandle == secondHandle)
        #expect(updatedState.selectedNodeId == secondNode.id)
        #expect(secondColumnIndex != initialState.activeColumnIndex)
        #expect(updatedState.activeColumnIndex == initialState.activeColumnIndex)
        #expect(updatedState.viewOffsetPixels.target() == initialState.viewOffsetPixels.target())
        // allowsSelectionOffscreen removed in viewport refactor; active column may differ from selection
        #expect(updatedState.activeColumnIndex == initialState.activeColumnIndex)
        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
    }

    // MARK: - M5 step 1: gesture skip/abort trace capture

    @Test @MainActor func gestureSkipTraceRecordsOverCountReason() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler

        controller.toggleRuntimeTraceCapture(desiredState: .active)

        // 4 active touches vs requiredFingers 3 → matcher returns nil → overCount skip.
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: CACurrentMediaTime(),
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30, 0.35])
            )
        )

        let mouseTraces = controller.runtimeMouseTraceRecordsForTests()
        #expect(mouseTraces.contains { $0.contains("gesture.skip reason=overCount") })
    }

    @Test @MainActor func gestureAbortTraceRecordsArmedAbortReason() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler
        let baseTime = CACurrentMediaTime()

        controller.toggleRuntimeTraceCapture(desiredState: .active)

        // Arm with a horizontal 3-finger began.
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        #expect(handler.state.gesturePhase == .armed)

        // Vertical-dominant changed past threshold → nonHorizontal skip + armed abort.
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30], yPosition: 0.9)
            )
        )

        let mouseTraces = controller.runtimeMouseTraceRecordsForTests()
        #expect(mouseTraces.contains { $0.contains("gesture.skip reason=nonHorizontal") })

        let viewportTraces = controller.runtimeViewportTraceRecordsForTests()
        #expect(viewportTraces.contains { $0.contains("reason=touch_scroll_gesture_abort") })
    }

    // MARK: - #64: click-through overlays must not suppress focus-follows-mouse

    @Test @MainActor func windowUnderPointerReconcilesClickThroughTopmostWindow() {
        // Click-through overlay (e.g. the standalone Borders app) is geometrically
        // topmost (`direct`) but does not handle events, so `canHandle` reports the
        // tile beneath. Resolve to the tile so FFM is not suppressed by it (#64).
        #expect(MouseEventHandler.windowUnderPointer(direct: 5000, canHandle: 4000) == 4000)
        // Interactive overlay (e.g. Ghostty Quick terminal): both fields agree, so
        // the overlay is still reported and correctly suppresses FFM — no
        // regression of the completed overlay fix.
        #expect(MouseEventHandler.windowUnderPointer(direct: 5000, canHandle: 5000) == 5000)
        // Neither field populated → nil.
        #expect(MouseEventHandler.windowUnderPointer(direct: 0, canHandle: 0) == nil)
        // Fallback for owners/event types that populate only the geometric field.
        #expect(MouseEventHandler.windowUnderPointer(direct: 6000, canHandle: 0) == 6000)
        // Only the event-handling field populated → prefer it.
        #expect(MouseEventHandler.windowUnderPointer(direct: 0, canHandle: 7000) == 7000)
    }

    @Test @MainActor func focusFollowsMouseFiresThroughClickThroughOverlay() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for click-through hover test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8801),
            pid: getpid(),
            windowId: 8801,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8802),
            pid: getpid(),
            windowId: 8802,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for click-through hover test")
            return
        }

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let hoveredFrame = secondNode.frame
        else {
            Issue.record("Missing hovered tile frame for click-through hover test")
            return
        }

        var snapshotCalls = 0
        controller.unmanagedWindowServerWindowFramesProvider = { _ in
            snapshotCalls += 1
            return []
        }

        // A decorative click-through overlay sits geometrically over the tile
        // (direct=8900) but the event-handling field resolves to the managed tile
        // beneath (canHandle=8802). windowUnderPointer(direct:canHandle:) yields
        // 8802 (the managed tile), so FFM must fire on it instead of freezing.
        let resolvedWindow = MouseEventHandler.windowUnderPointer(direct: 8900, canHandle: 8802)
        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: hoveredFrame.midX, y: hoveredFrame.midY),
            windowUnderPointer: resolvedWindow
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(resolvedWindow == 8802)
        #expect(controller.workspaceManager.pendingFocusedHandle == secondHandle)
        #expect(snapshotCalls == 0)
    }

    @Test @MainActor func focusFollowsMouseSuppressesOverInteractiveOverlay() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for interactive overlay regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8811),
            pid: getpid(),
            windowId: 8811,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8812),
            pid: getpid(),
            windowId: 8812,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for interactive overlay regression test")
            return
        }

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let hoveredFrame = secondNode.frame
        else {
            Issue.record("Missing hovered tile frame for interactive overlay regression test")
            return
        }

        var snapshotCalls = 0
        controller.unmanagedWindowServerWindowFramesProvider = { _ in
            snapshotCalls += 1
            return []
        }

        // Interactive overlay (e.g. Ghostty Quick terminal): it handles events, so
        // direct==canHandle==8899. The reconcile keeps the overlay window number;
        // it is unmanaged and unowned → FFM must stay suppressed (completed fix).
        let resolvedWindow = MouseEventHandler.windowUnderPointer(direct: 8899, canHandle: 8899)
        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: hoveredFrame.midX, y: hoveredFrame.midY),
            windowUnderPointer: resolvedWindow
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(resolvedWindow == 8899)
        #expect(snapshotCalls == 0)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == firstToken)
        #expect(controller.workspaceManager.activeFocusRequestToken == nil)
    }

    @Test @MainActor func focusFollowsMouseNotSuppressedByOwnedPassthroughBorder() async {
        let registry = makeOwnedMouseWindowRegistry { nil }
        let controller = makeMouseEventTestController(ownedWindowRegistry: registry)
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for owned border hover test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8821),
            pid: getpid(),
            windowId: 8821,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8822),
            pid: getpid(),
            windowId: 8822,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for owned border hover test")
            return
        }

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let hoveredFrame = secondNode.frame
        else {
            Issue.record("Missing hovered tile frame for owned border hover test")
            return
        }

        // Register a Nehir-owned passthrough border surface (the built-in border).
        let borderWindowNumber = 8898
        registry.registerWindowNumber(
            surfaceId: "test-owned-border",
            kind: .border,
            windowNumber: borderWindowNumber,
            frameProvider: { hoveredFrame },
            visibilityProvider: { true },
            hitTestPolicy: .passthrough,
            capturePolicy: .excluded,
            suppressesManagedFocusRecovery: false
        )
        defer {
            registry.unregister(surfaceId: "test-owned-border")
            registry.resetForTests()
        }

        var snapshotCalls = 0
        controller.unmanagedWindowServerWindowFramesProvider = { _ in
            snapshotCalls += 1
            return []
        }

        // The built-in border is click-through: geometrically topmost (direct) but
        // the tile beneath handles events (canHandle=8822). The reconcile yields
        // the managed tile, and even if the border number reached the occlusion
        // check it is owned → not unmanaged → FFM fires on the tile.
        let resolvedWindow = MouseEventHandler.windowUnderPointer(direct: borderWindowNumber, canHandle: 8822)
        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: hoveredFrame.midX, y: hoveredFrame.midY),
            windowUnderPointer: resolvedWindow
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(resolvedWindow == 8822)
        #expect(controller.workspaceManager.pendingFocusedHandle == secondHandle)
        #expect(snapshotCalls == 0)
    }

    // MARK: - #64: snapshot-fallback path (windowUnderPointer == nil)

    // These exercise the path the bug actually takes in the field: on some
    // macOS builds the CGEvent window-under-pointer fields are never populated
    // for mouse-moved events, so FFM's occlusion decision falls to the
    // WindowServer snapshot. A decorative click-through overlay owned by a
    // faceless process (e.g. the JankyBorders binary: bundleId == nil,
    // activationPolicy == nil) must not suppress FFM there, while an
    // interactive overlay owned by a real bundled app (e.g. the Ghostty Quick
    // terminal) must still suppress it.

    @Test @MainActor func focusFollowsMouseFiresThroughFacelessClickThroughOverlayOnSnapshotFallback() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for faceless overlay hover test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8831),
            pid: getpid(),
            windowId: 8831,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8832),
            pid: getpid(),
            windowId: 8832,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for faceless overlay hover test")
            return
        }

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let hoveredFrame = secondNode.frame
        else {
            Issue.record("Missing hovered tile frame for faceless overlay hover test")
            return
        }

        // A decorative click-through overlay covers the tile geometrically and
        // is reported by the WindowServer snapshot (JankyBorders-style).
        // windowUnderPointer is nil (the real field-empty case), forcing the
        // snapshot fallback.
        controller.unmanagedOverlayWindowInfoProvider = {
            [makeUnmanagedOverlayWindowInfo(
                windowId: 8890,
                pid: 55556,
                appKitFrame: hoveredFrame,
                ownerName: "borders"
            )]
        }
        // The overlay's owner is a faceless process: not a registered app, so
        // it cannot host an interactive surface → excluded from occlusion.
        controller.ownerAppIsInteractiveApplicationProvider = { _ in false }

        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: hoveredFrame.midX, y: hoveredFrame.midY),
            windowUnderPointer: nil
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.pendingFocusedHandle == secondHandle)
    }

    @Test @MainActor func focusFollowsMouseSuppressesOverInteractiveAppOverlayOnSnapshotFallback() async {
        // Regression guard for the Ghostty Quick terminal: an interactive
        // overlay owned by a real bundled app must still suppress FFM on the
        // snapshot-fallback path, even though windowUnderPointer is nil.
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.interactionWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for interactive app overlay test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8841),
            pid: getpid(),
            windowId: 8841,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 8842),
            pid: getpid(),
            windowId: 8842,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for interactive app overlay test")
            return
        }

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let hoveredFrame = secondNode.frame
        else {
            Issue.record("Missing hovered tile frame for interactive app overlay test")
            return
        }

        // The interactive overlay covers the tile above the normal app layer
        // and is reported by the snapshot. Ghostty's Quick terminal can appear
        // faceless/unregistered on this path, but because its owner is not the
        // decorative border utility, it must still occlude FFM.
        controller.unmanagedOverlayWindowInfoProvider = {
            [makeUnmanagedOverlayWindowInfo(
                windowId: 8899,
                pid: 55557,
                appKitFrame: hoveredFrame,
                layer: 25,
                ownerName: "Ghostty"
            )]
        }
        controller.ownerAppIsInteractiveApplicationProvider = { _ in false }

        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: hoveredFrame.midX, y: hoveredFrame.midY),
            windowUnderPointer: nil
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.confirmedManagedFocusToken == firstToken)
        #expect(controller.workspaceManager.activeFocusRequestToken == nil)
    }
}
