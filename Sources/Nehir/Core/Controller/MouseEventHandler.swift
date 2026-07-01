// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

private let niriTouchpadGestureRecognitionThreshold: CGFloat = 16.0
// AppKit gives normalized touch positions rather than libinput gesture deltas.
// This maps normalized movement into the delta space that ViewportState later
// normalizes with VIEW_GESTURE_WORKING_AREA_MOVEMENT.
private let macNormalizedTouchPositionToNiriGestureUnits: CGFloat = 500.0
private let mouseWheelAxisEpsilon: CGFloat = 0.001
private let niriWheelScrollTickAmount: CGFloat = 120.0
private let queuedMouseMoveCurrentPointerTolerance: CGFloat = 2.0
private let mouseRelevantModifierFlags: CGEventFlags = [
    .maskAlternate,
    .maskShift,
    .maskControl,
    .maskCommand
]

@MainActor
final class MouseEventHandler {
    enum MouseButton: Hashable {
        case left
        case right

        var pressedMask: Int {
            switch self {
            case .left: 1
            case .right: 2
            }
        }
    }

    private enum MouseWheelColumnAxis {
        case horizontal
        case vertical
    }

    private struct MouseWheelColumnDelta {
        var axis: MouseWheelColumnAxis
        var value: CGFloat
    }

    private enum FocusFollowsMouseTarget {
        case niri(workspaceId: WorkspaceDescriptor.ID, window: NiriWindow)
    }

    /// Outcome of resolving a focus-follows-mouse target. The non-target cases
    /// carry a machine-readable `skipReason` so a runtime trace can distinguish
    /// *why* FFM did not fire — e.g. blocked by an unmanaged overlay (`occlusion`)
    /// versus no focusable tile under the pointer (`noHitTest`). Used to diagnose
    /// click-through overlay cases such as #64, where the resolved window number
    /// alone reveals whether the overlay or the tile beneath was reported.
    private enum FocusFollowsMouseResolution {
        case target(FocusFollowsMouseTarget)
        case noWorkspace
        case occlusion
        case noHitTest

        var targetValue: FocusFollowsMouseTarget? {
            if case let .target(value) = self { return value } else { return nil }
        }

        var skipReason: String {
            switch self {
            case .target: return "resolved"
            case .noWorkspace: return "noWorkspace"
            case .occlusion: return "occlusion"
            case .noHitTest: return "noHitTest"
            }
        }
    }

    struct GestureTouchSample: Equatable, Sendable {
        let phase: NSTouch.Phase
        let normalizedPosition: CGPoint?
    }

    struct GestureEventSnapshot: Sendable {
        let location: CGPoint
        let phaseRawValue: NSEvent.Phase.RawValue
        let timestamp: TimeInterval
        let modifiers: CGEventFlags
        let windowUnderPointer: Int?
        let touches: [GestureTouchSample]
        /// Raw contact count observed on the previous multitouch frame, for the
        /// raw MultitouchSupport source only. `nil` for NSEvent-derived snapshots.
        /// Lets idle-admission diagnostics report whether an idle `.changed` arm
        /// came from a contact-count increase or a mid-gesture continuation.
        let previousRawActiveCount: Int?

        init(
            location: CGPoint,
            phaseRawValue: NSEvent.Phase.RawValue,
            timestamp: TimeInterval = CACurrentMediaTime(),
            modifiers: CGEventFlags = [],
            windowUnderPointer: Int? = nil,
            previousRawActiveCount: Int? = nil,
            touches: [GestureTouchSample]
        ) {
            self.location = location
            self.phaseRawValue = phaseRawValue
            self.timestamp = timestamp
            self.modifiers = modifiers
            self.windowUnderPointer = windowUnderPointer
            self.previousRawActiveCount = previousRawActiveCount
            self.touches = touches
        }
    }

    struct State {
        struct LockedGestureContext {
            let workspaceId: WorkspaceDescriptor.ID
            let monitorId: Monitor.ID
            let bypassSnap: Bool
        }

        enum GesturePhase {
            case idle
            case armed
            case committed
        }

        enum PendingTapKind {
            case mouseMoved
            case mouseDragged(MouseButton)
            case scrollWheel
        }

        struct PointerPayload {
            var location: CGPoint
            var windowUnderPointer: Int?
        }

        struct ScrollPayload {
            var location: CGPoint
            var deltaX: CGFloat
            var deltaY: CGFloat
            var momentumPhase: UInt32
            var phase: UInt32
            var modifiers: CGEventFlags

            func matches(
                modifiers: CGEventFlags,
                momentumPhase: UInt32,
                phase: UInt32
            ) -> Bool {
                self.modifiers == modifiers &&
                    self.momentumPhase == momentumPhase &&
                    self.phase == phase
            }

            func canCoalesce(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
                Self.axisSignature(deltaX: self.deltaX, deltaY: self.deltaY) ==
                    Self.axisSignature(deltaX: deltaX, deltaY: deltaY)
            }

            mutating func accumulate(deltaX: CGFloat, deltaY: CGFloat, location: CGPoint) {
                self.deltaX += deltaX
                self.deltaY += deltaY
                self.location = location
            }

            private static func axisSignature(deltaX: CGFloat, deltaY: CGFloat) -> (Int, Int) {
                (
                    signedAxis(deltaX),
                    signedAxis(deltaY)
                )
            }

            private static func signedAxis(_ delta: CGFloat) -> Int {
                guard abs(delta) > mouseWheelAxisEpsilon else { return 0 }
                return delta > 0 ? 1 : -1
            }
        }

        struct PendingTapEvents {
            var orderedKinds: [PendingTapKind] = []
            var mouseMovedPayload: PointerPayload?
            var leftMouseDraggedPayload: PointerPayload?
            var rightMouseDraggedPayload: PointerPayload?
            var scrollPayload: ScrollPayload?
            var drainScheduled = false

            var hasPendingEvents: Bool {
                !orderedKinds.isEmpty
            }

            mutating func setMouseDraggedPayload(_ payload: PointerPayload, for button: MouseButton) -> Bool {
                switch button {
                case .left:
                    let didCoalesce = leftMouseDraggedPayload != nil
                    leftMouseDraggedPayload = payload
                    return didCoalesce
                case .right:
                    let didCoalesce = rightMouseDraggedPayload != nil
                    rightMouseDraggedPayload = payload
                    return didCoalesce
                }
            }

            mutating func clear() {
                orderedKinds.removeAll(keepingCapacity: true)
                mouseMovedPayload = nil
                leftMouseDraggedPayload = nil
                rightMouseDraggedPayload = nil
                scrollPayload = nil
                drainScheduled = false
            }
        }

        struct DebugCounters: Equatable {
            var queuedTransientEvents = 0
            var coalescedTransientEvents = 0
            var drainedTransientEvents = 0
            var drainRuns = 0
            var flushedBeforeImmediateDispatch = 0
        }

        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var currentHoveredEdges: ResizeEdge = []
        var isResizing: Bool = false
        var isMoving: Bool = false
        var activeInteractionButton: MouseButton?
        var activeInteractionWorkspaceId: WorkspaceDescriptor.ID?

        var lastFocusFollowsMouseTime: Date = .distantPast
        var lastFocusFollowsMouseToken: WindowToken?
        var suppressFocusFollowsMouseUntil: Date = .distantPast
        let focusFollowsMouseDebounce: TimeInterval = 0.1
        var dragGhostController: DragGhostController?
        var moveIsInsertMode: Bool = false

        var gesturePhase: GesturePhase = .idle
        var gestureStartX: CGFloat = 0.0
        var gestureStartY: CGFloat = 0.0
        var gestureLastAverageX: CGFloat = 0.0
        var gestureLastAverageY: CGFloat = 0.0
        var lockedGestureContext: LockedGestureContext?
        // Commit metrics retained from the armed→committed transition until the first
        // committed update, so `touch_scroll_gesture_first_update` can report whether
        // the first applied delta honored the recognition dead zone.
        var pendingFirstUpdateAfterCommit = false
        var commitCumulativeX: CGFloat = 0.0
        var commitCumulativeY: CGFloat = 0.0
        var commitRawDeltaX: CGFloat = 0.0
        var commitInputPhaseName = ""
        var commitTimestamp: TimeInterval = 0.0
        var suppressGestureUntilTouchesEnd = false
        var pendingTapEvents = PendingTapEvents()
        var debugCounters = DebugCounters()
        var horizontalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
        var verticalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
    }

    nonisolated(unsafe) weak static var _instance: MouseEventHandler?

    weak var controller: WMController?
    var state = State()
    private var multitouchSource: MultitouchGestureSource?
    var pressedMouseButtonsProvider: @MainActor () -> Int = { Int(NSEvent.pressedMouseButtons) }
    var mouseLocationProvider: @MainActor () -> CGPoint = { NSEvent.mouseLocation }

    init(controller: WMController) {
        self.controller = controller
    }

    func setup() {
        MouseEventHandler._instance = self

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MouseEventHandler._instance?.state.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let suppressEvent = MouseEventHandler.processTapCallback(type: type, event: event)

            return suppressEvent ? nil : Unmanaged.passUnretained(event)
        }

        state.eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        if let tap = state.eventTap {
            state.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = state.runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        let source = MultitouchGestureSource()
        source.onSnapshot = { [weak self] snapshot in
            self?.receiveTapGestureEvent(snapshot)
        }
        source.start()
        multitouchSource = source
    }

    func cleanup() {
        if let source = state.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            state.runLoopSource = nil
        }
        if let tap = state.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            state.eventTap = nil
        }
        multitouchSource?.stop()
        multitouchSource = nil
        MouseEventHandler._instance = nil
        state.currentHoveredEdges = []
        state.isResizing = false
        state.activeInteractionButton = nil
        state.activeInteractionWorkspaceId = nil
        state.pendingTapEvents.clear()
        resetGestureState()
    }

    func restartMultitouch() {
        abortActiveGestureIfNeeded()
        multitouchSource?.restart()
    }

    func stopMultitouch() {
        multitouchSource?.stop()
    }

    func dispatchMouseMoved(at location: CGPoint, windowUnderPointer: Int? = nil) {
        guard !isInputSuppressed else {
            resetHoveredEdgesIfNeeded()
            return
        }
        handleMouseMovedFromTap(at: location, windowUnderPointer: windowUnderPointer)
    }

    func refreshFocusFollowsMouseAtCurrentPointer() {
        guard !isInputSuppressed else { return }
        handleMouseMovedFromTap(at: mouseLocationProvider())
    }

    func resetFocusFollowsMouseTimeForTesting() {
        state.lastFocusFollowsMouseTime = .distantPast
    }

    @discardableResult
    func dispatchMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left,
        windowUnderPointer: Int? = nil
    ) -> Bool {
        guard !isInputSuppressed else { return false }
        guard controller != nil else { return false }
        if shouldBlockOwnWindowInput(at: location) {
            return false
        }
        return handleMouseDownFromTap(
            at: location,
            modifiers: modifiers,
            button: button,
            windowUnderPointer: windowUnderPointer
        )
    }

    func dispatchMouseDragged(at location: CGPoint, button: MouseButton = .left, windowUnderPointer: Int? = nil) {
        guard !isInputSuppressed else { return }
        if shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button, windowUnderPointer: windowUnderPointer)
    }

    func dispatchMouseUp(at location: CGPoint, button: MouseButton = .left, windowUnderPointer: Int? = nil) {
        guard !isInputSuppressed else { return }
        if shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseUpFromTap(at: location, button: button, windowUnderPointer: windowUnderPointer)
    }

    func dispatchScrollWheel(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        guard !isInputSuppressed else { return }
        handleScrollWheelFromTap(
            at: location,
            deltaX: deltaX,
            deltaY: deltaY,
            momentumPhase: momentumPhase,
            phase: phase,
            modifiers: modifiers
        )
    }

    func dispatchGestureEvent(from cgEvent: CGEvent) {
        guard !isInputSuppressed else { return }
        guard let snapshot = Self.makeGestureEventSnapshot(from: cgEvent) else { return }
        handleGestureEvent(snapshot)
    }

    func dispatchGestureEvent(_ event: NSEvent, at location: CGPoint) {
        guard !isInputSuppressed else { return }
        handleGestureEvent(
            GestureEventSnapshot(
                location: location,
                phaseRawValue: event.phase.rawValue,
                timestamp: event.timestamp,
                modifiers: Self.cgEventFlags(from: event.modifierFlags),
                windowUnderPointer: event.windowNumber > 0 ? event.windowNumber : nil,
                touches: event.allTouches().map { touch in
                    GestureTouchSample(
                        phase: touch.phase,
                        normalizedPosition: Self.sanitizedGestureTouchPosition(touch.normalizedPosition)
                    )
                }
            )
        )
    }

    var isInteractiveGestureActive: Bool {
        state.isMoving || state.isResizing || isViewportGestureActive
    }

    var isViewportGestureActive: Bool {
        state.gesturePhase != .idle
    }

    func flushPendingTapEventsForTests() {
        flushPendingTapEvents()
    }

    func mouseTapDebugSnapshot() -> State.DebugCounters {
        state.debugCounters
    }

    func resetDebugStateForTests() {
        state.debugCounters = .init()
        state.pendingTapEvents.clear()
    }

    func handleInputSuppressionBegan() {
        dropPendingTapEvents()
        resetMouseWheelTrackers()
        abortActiveGestureIfNeeded()
    }

    func handleTapCallbackForTests(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool
    ) -> Bool {
        let previousInstance = Self._instance
        Self._instance = self
        defer { Self._instance = previousInstance }
        return Self.processTapCallback(type: type, event: event, isMainThread: isMainThread)
    }

    func handleGestureTapCallbackForTests(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool
    ) -> Bool {
        Self.processGestureTapCallback(type: type, event: event, isMainThread: isMainThread)
    }

    func receiveTapMouseMoved(at location: CGPoint, windowUnderPointer: Int? = nil) {
        flushPendingScrollBeforeNonScroll()
        enqueuePendingMouseMoved(at: location, windowUnderPointer: windowUnderPointer)
    }

    @discardableResult
    func receiveTapMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left,
        windowUnderPointer: Int? = nil
    ) -> Bool {
        if shouldBlockOwnWindowInput(at: location) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        return dispatchMouseDown(
            at: location,
            modifiers: modifiers,
            button: button,
            windowUnderPointer: windowUnderPointer
        )
    }

    func receiveTapMouseDragged(at location: CGPoint, button: MouseButton = .left, windowUnderPointer: Int? = nil) {
        flushPendingScrollBeforeNonScroll()
        enqueuePendingMouseDragged(at: location, button: button, windowUnderPointer: windowUnderPointer)
    }

    func receiveTapMouseUp(at location: CGPoint, button: MouseButton = .left, windowUnderPointer: Int? = nil) {
        if shouldBlockOwnWindowInput(at: location) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        dispatchMouseUp(at: location, button: button, windowUnderPointer: windowUnderPointer)
    }

    func receiveTapScrollWheel(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        enqueuePendingScrollWheel(
            at: location,
            deltaX: deltaX,
            deltaY: deltaY,
            momentumPhase: momentumPhase,
            phase: phase,
            modifiers: modifiers
        )
    }

    func receiveTapGestureEvent(from cgEvent: CGEvent) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        let location = ScreenCoordinateSpace.toAppKit(point: cgEvent.location)
        if shouldBlockOwnWindowInput(at: location) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        guard let snapshot = Self.makeGestureEventSnapshot(from: cgEvent) else { return }
        handleGestureEvent(snapshot)
    }

    func receiveTapGestureEvent(_ snapshot: GestureEventSnapshot) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        guard shouldProcessGestureFrame(snapshot) else { return }
        if shouldBlockOwnWindowInput(at: snapshot.location) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        handleGestureEvent(snapshot)
    }

    private func shouldProcessGestureFrame(_ snapshot: GestureEventSnapshot) -> Bool {
        guard state.gesturePhase == .idle else { return true }
        let activeTouchCount = snapshot.touches.filter { $0.phase != .ended && $0.phase != .cancelled }.count
        guard activeTouchCount > 0 else { return true }
        guard let requiredFingers = controller?.settings.gestureFingerCount.rawValue else { return false }
        guard activeTouchCount == requiredFingers else {
            let reason = activeTouchCount > requiredFingers ? "overCount" : "underCount"
            traceGestureSkip(
                reason: reason,
                location: snapshot.location,
                requiredFingers: requiredFingers,
                activeTouches: activeTouchCount,
                phase: NSEvent.Phase(rawValue: snapshot.phaseRawValue)
            )
            return false
        }
        return true
    }

    private var isInputSuppressed: Bool {
        guard let controller else { return true }
        return controller.isLockScreenActive || controller.isFrontmostAppLockScreen()
    }

    private func dropPendingTapEvents() {
        guard state.pendingTapEvents.hasPendingEvents else { return }
        state.pendingTapEvents.clear()
    }

    private func resetMouseWheelTrackers() {
        state.horizontalWheelTracker.reset()
        state.verticalWheelTracker.reset()
    }

    private func cancelActiveMouseInteraction() {
        guard let controller else { return }

        if state.isMoving {
            controller.focusCoordinator.interactiveMoveCancel()
            state.dragGhostController?.endDrag()
            state.isMoving = false
            state.moveIsInsertMode = false
            state.activeInteractionButton = nil
            state.activeInteractionWorkspaceId = nil
        }

        if state.isResizing {
            controller.focusCoordinator.clearInteractiveResize()
            state.isResizing = false
            state.activeInteractionButton = nil
            state.activeInteractionWorkspaceId = nil
        }

        resetHoveredEdgesIfNeeded()
    }

    private func workspaceIdForPointer(at location: CGPoint) -> WorkspaceDescriptor.ID? {
        guard let controller else { return nil }
        guard let monitor = location.monitorApproximation(in: controller.workspaceManager.monitors) else {
            return controller.interactionWorkspace()?.id
        }
        return controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
    }

    private func shouldBlockOwnWindowInput(at location: CGPoint) -> Bool {
        guard let controller else { return false }
        return controller.isPointInOwnWindow(location)
    }

    private func resetHoveredEdgesIfNeeded() {
        if !state.currentHoveredEdges.isEmpty {
            NSCursor.arrow.set()
            state.currentHoveredEdges = []
        }
    }

    private func schedulePendingTapDrainIfNeeded() {
        guard !state.pendingTapEvents.drainScheduled else { return }
        state.pendingTapEvents.drainScheduled = true

        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushPendingTapEvents()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    private func flushPendingScrollBeforeNonScroll() {
        guard state.pendingTapEvents.scrollPayload != nil else { return }
        flushPendingTapEvents()
    }

    private func enqueuePendingMouseMoved(at location: CGPoint, windowUnderPointer: Int?) {
        state.debugCounters.queuedTransientEvents += 1
        let didCoalesce = state.pendingTapEvents.mouseMovedPayload != nil
        state.pendingTapEvents.mouseMovedPayload = .init(location: location, windowUnderPointer: windowUnderPointer)
        if !didCoalesce {
            state.pendingTapEvents.orderedKinds.append(.mouseMoved)
        } else {
            state.debugCounters.coalescedTransientEvents += 1
        }
        schedulePendingTapDrainIfNeeded()
    }

    private func enqueuePendingMouseDragged(at location: CGPoint, button: MouseButton, windowUnderPointer: Int?) {
        state.debugCounters.queuedTransientEvents += 1
        let didCoalesce = state.pendingTapEvents.setMouseDraggedPayload(
            .init(location: location, windowUnderPointer: windowUnderPointer),
            for: button
        )
        if !didCoalesce {
            state.pendingTapEvents.orderedKinds.append(.mouseDragged(button))
        } else {
            state.debugCounters.coalescedTransientEvents += 1
        }
        schedulePendingTapDrainIfNeeded()
    }

    private func enqueuePendingScrollWheel(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        state.debugCounters.queuedTransientEvents += 1

        if let existing = state.pendingTapEvents.scrollPayload,
           (!existing.matches(modifiers: modifiers, momentumPhase: momentumPhase, phase: phase)
               || !existing.canCoalesce(deltaX: deltaX, deltaY: deltaY))
        {
            flushPendingTapEvents()
        }

        if var existing = state.pendingTapEvents.scrollPayload {
            existing.accumulate(deltaX: deltaX, deltaY: deltaY, location: location)
            state.pendingTapEvents.scrollPayload = existing
            state.debugCounters.coalescedTransientEvents += 1
        } else {
            state.pendingTapEvents.scrollPayload = .init(
                location: location,
                deltaX: deltaX,
                deltaY: deltaY,
                momentumPhase: momentumPhase,
                phase: phase,
                modifiers: modifiers
            )
            state.pendingTapEvents.orderedKinds.append(.scrollWheel)
        }

        schedulePendingTapDrainIfNeeded()
    }

    private func flushPendingTapEvents(beforeImmediateDispatch: Bool = false) {
        guard state.pendingTapEvents.hasPendingEvents else { return }

        if beforeImmediateDispatch {
            state.debugCounters.flushedBeforeImmediateDispatch += 1
        }

        let pendingKinds = state.pendingTapEvents.orderedKinds
        let pendingMouseMoved = state.pendingTapEvents.mouseMovedPayload
        let pendingLeftMouseDragged = state.pendingTapEvents.leftMouseDraggedPayload
        let pendingRightMouseDragged = state.pendingTapEvents.rightMouseDraggedPayload
        let pendingScroll = state.pendingTapEvents.scrollPayload

        state.pendingTapEvents.clear()
        state.debugCounters.drainRuns += 1

        for kind in pendingKinds {
            switch kind {
            case .mouseMoved:
                if let payload = pendingMouseMoved {
                    state.debugCounters.drainedTransientEvents += 1
                    replayQueuedMouseMoved(payload)
                }
            case let .mouseDragged(button):
                let payload = switch button {
                case .left: pendingLeftMouseDragged
                case .right: pendingRightMouseDragged
                }
                if let payload {
                    state.debugCounters.drainedTransientEvents += 1
                    replayQueuedMouseDragged(payload, button: button)
                }
            case .scrollWheel:
                if let payload = pendingScroll {
                    state.debugCounters.drainedTransientEvents += 1
                    dispatchScrollWheel(
                        at: payload.location,
                        deltaX: payload.deltaX,
                        deltaY: payload.deltaY,
                        momentumPhase: payload.momentumPhase,
                        phase: payload.phase,
                        modifiers: payload.modifiers
                    )
                }
            }
        }
    }

    private func replayQueuedMouseMoved(_ payload: State.PointerPayload) {
        guard !isInputSuppressed else {
            resetHoveredEdgesIfNeeded()
            return
        }
        let currentPayload = currentPointerPayload(forQueuedMouseMove: payload)
        if !pointsApproximatelyEqual(
            payload.location,
            currentPayload.location,
            tolerance: queuedMouseMoveCurrentPointerTolerance
        ) {
            traceMouseFocus(
                "mouseMove.replay staleQueued queued=\(formatPoint(payload.location)) current=\(formatPoint(currentPayload.location))"
            )
        }
        handleMouseMovedFromTap(
            at: currentPayload.location,
            windowUnderPointer: currentPayload.windowUnderPointer
        )
    }

    private func currentPointerPayload(forQueuedMouseMove payload: State.PointerPayload) -> State.PointerPayload {
        let currentLocation = mouseLocationProvider()
        guard currentLocation.x.isFinite, currentLocation.y.isFinite else { return payload }

        guard !pointsApproximatelyEqual(
            payload.location,
            currentLocation,
            tolerance: queuedMouseMoveCurrentPointerTolerance
        ) else {
            return payload
        }
        return .init(location: currentLocation, windowUnderPointer: payload.windowUnderPointer)
    }

    private func pointsApproximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat) -> Bool {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy <= tolerance * tolerance
    }

    private func traceMouseFocus(_ message: @autoclosure () -> String) {
        guard controller?.isRuntimeTraceCaptureActive == true else { return }
        controller?.recordRuntimeMouseTrace(message())
    }

    // Emits a `gesture.skip reason=...` mouse-trace record at every point where a trackpad
    // gesture is skipped or aborted before committing, so an "eaten" swipe (#53) can be
    // diagnosed. Purely additive: a no-op unless runtime trace capture is active.
    private func traceGestureSkip(
        reason: String,
        location: CGPoint,
        requiredFingers: Int? = nil,
        activeTouches: Int? = nil,
        phase: NSEvent.Phase? = nil
    ) {
        var fields = ["reason=\(reason)", "loc=\(formatPoint(location))"]
        if let requiredFingers { fields.append("requiredFingers=\(requiredFingers)") }
        if let activeTouches { fields.append("activeTouches=\(activeTouches)") }
        if let phase { fields.append("phase=\(phase.rawValue)") }
        traceMouseFocus("gesture.skip " + fields.joined(separator: " "))
    }

    private func formatPoint(_ point: CGPoint) -> String {
        String(format: "(%.1f,%.1f)", point.x, point.y)
    }

    // Human-readable name for a raw `NSEvent.Phase` so idle-admission diagnostics
    // can grep `inputPhaseName=changed` instead of decoding the OptionSet raw value.
    static func gesturePhaseName(_ phase: NSEvent.Phase) -> String {
        switch phase {
        case .began: return "began"
        case .stationary: return "stationary"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .mayBegin: return "mayBegin"
        default: return "other(\(phase.rawValue))"
        }
    }

    private func formatToken(_ token: WindowToken?) -> String {
        token.map(String.init(describing:)) ?? "nil"
    }

    private func replayQueuedMouseDragged(_ payload: State.PointerPayload, button: MouseButton) {
        guard !isInputSuppressed else { return }
        if shouldBlockOwnWindowInput(at: payload.location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(
            at: payload.location,
            button: button,
            requirePressedButtonCheck: false,
            windowUnderPointer: payload.windowUnderPointer
        )
    }

    private func handleMouseMovedFromTap(at location: CGPoint, windowUnderPointer: Int? = nil) {
        guard let controller else { return }
        guard controller.isEnabled else {
            resetHoveredEdgesIfNeeded()
            return
        }
        if controller.isOverviewOpen() { return }

        if shouldBlockOwnWindowInput(at: location) {
            resetHoveredEdgesIfNeeded()
            return
        }

        if controller.focusFollowsMouseEnabled, shouldHandleFocusFollowsMouse(at: location) {
            handleFocusFollowsMouse(at: location, windowUnderPointer: windowUnderPointer)
        }

        guard !state.isResizing else { return }
        resetHoveredEdgesIfNeeded()
    }

    private func shouldHandleFocusFollowsMouse(at location: CGPoint) -> Bool {
        guard !state.isResizing, !isViewportGestureActive else { return false }
        guard Date() >= state.suppressFocusFollowsMouseUntil else { return false }
        guard let controller else { return false }
        guard let monitor = location.monitorApproximation(in: controller.workspaceManager.monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return true
        }
        return !controller.niriLayoutHandler.hasScrollAnimation(for: workspace.id)
    }

    private func handleMouseDownFromTap(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        windowUnderPointer: Int? = nil
    ) -> Bool {
        guard let controller else { return false }
        traceMouseFocus(
            "mouseDown loc=\(formatPoint(location)) button=\(button) pressedButtons=\(pressedMouseButtonsProvider()) modifiers=\(modifiers.rawValue) moving=\(state.isMoving) resizing=\(state.isResizing)"
        )
        guard controller.isEnabled else { return false }
        if controller.isOverviewOpen() { return false }

        if shouldBlockOwnWindowInput(at: location) {
            return false
        }

        markRecentFloatingPointerInteractionIfNeeded(at: location, windowUnderPointer: windowUnderPointer)
        suppressMouseMoveToFocusedWindowForPointerTarget(at: location, windowUnderPointer: windowUnderPointer)

        guard let engine = controller.niriEngine,
              let wsId = workspaceIdForPointer(at: location) ?? controller.interactionWorkspace()?.id
        else {
            return false
        }

        if button == .left, let tiledWindow = engine.hitTestTiled(point: location, in: wsId) {
            controller.suppressMouseMoveToFocusedWindow(for: tiledWindow.token)
        }

        if button == .left, modifiers.contains(.maskAlternate) {
            if let tiledWindow = engine.hitTestTiled(point: location, in: wsId),
               let monitor = controller.workspaceManager.monitor(for: wsId)
            {
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                let gaps = controller.gapSize(for: monitor)

                let isInsertMode = modifiers.contains(.maskShift)
                var moveStarted = false
                controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                    if engine.interactiveMoveBegin(
                        windowId: tiledWindow.id,
                        windowHandle: tiledWindow.handle,
                        startLocation: location,
                        isInsertMode: isInsertMode,
                        in: wsId,
                        motion: controller.motionPolicy.snapshot(),
                        state: &vstate,
                        workingFrame: workingFrame,
                        gaps: gaps
                    ) {
                        moveStarted = true
                    }
                }
                if moveStarted {
                    state.moveIsInsertMode = isInsertMode
                    state.isMoving = true
                    state.activeInteractionButton = button
                    state.activeInteractionWorkspaceId = wsId
                    NSCursor.closedHand.set()

                    if let entry = controller.workspaceManager.entry(for: tiledWindow.handle),
                       let frame = AXWindowService.framePreferFast(entry.axRef)
                    {
                        if state.dragGhostController == nil {
                            state.dragGhostController = DragGhostController()
                        }
                        state.dragGhostController?.beginDrag(
                            windowId: entry.windowId,
                            originalFrame: frame,
                            cursorLocation: location
                        )
                    }
                    return false
                }
            }
            return false
        }

        guard button == .right,
              Self.modifierFlagsMatch(modifiers, required: controller.settings.mouseResizeModifierKey.cgEventFlag)
        else { return false }
        guard let tiledWindow = engine.hitTestTiled(point: location, in: wsId),
              let frame = tiledWindow.renderedFrame ?? tiledWindow.frame
        else { return false }

        let edges = resizeEdges(for: location, in: frame)
        let currentViewOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffsetPixels.current()
        if engine.interactiveResizeBegin(
            windowId: tiledWindow.id,
            edges: edges,
            startLocation: location,
            in: wsId,
            viewOffset: currentViewOffset
        ) {
            state.isResizing = true
            state.activeInteractionButton = button
            state.activeInteractionWorkspaceId = wsId
            state.currentHoveredEdges = edges
            controller.niriLayoutHandler.cancelActiveAnimations(for: wsId)
            edges.cursor.set()
            return true
        }
        return false
    }

    private func resizeEdges(for location: CGPoint, in frame: CGRect) -> ResizeEdge {
        var edges: ResizeEdge = location.x < frame.midX ? [.left] : [.right]
        edges.insert(location.y < frame.midY ? .bottom : .top)
        return edges
    }

    private func shouldAcceptInteractionButton(_ button: MouseButton) -> Bool {
        state.activeInteractionButton == nil || state.activeInteractionButton == button
    }

    private func shouldSuppressRightMouseEvent(type: CGEventType) -> Bool {
        guard state.activeInteractionButton == .right else { return false }
        switch type {
        case .rightMouseDown,
             .rightMouseDragged,
             .rightMouseUp:
            return state.isResizing
        default:
            return false
        }
    }

    private func handleMouseDraggedFromTap(
        at location: CGPoint,
        button: MouseButton,
        requirePressedButtonCheck: Bool = true,
        windowUnderPointer: Int? = nil
    ) {
        guard let controller else { return }
        guard controller.isEnabled else { return }
        if controller.isOverviewOpen() { return }
        if button == .left {
            markRecentFloatingPointerInteractionIfNeeded(
                at: location,
                windowUnderPointer: windowUnderPointer,
                allowWindowServerSnapshotFallback: false
            )
        }
        let pressedButtons = pressedMouseButtonsProvider()
        traceMouseFocus(
            "mouseDrag loc=\(formatPoint(location)) button=\(button) pressedButtons=\(pressedButtons) requirePressedCheck=\(requirePressedButtonCheck) moving=\(state.isMoving) resizing=\(state.isResizing) activeButton=\(String(describing: state.activeInteractionButton))"
        )
        if requirePressedButtonCheck {
            guard pressedButtons & button.pressedMask != 0 else {
                traceMouseFocus(
                    "mouseDrag.skip reason=buttonNotPressed loc=\(formatPoint(location)) button=\(button) pressedButtons=\(pressedButtons)"
                )
                return
            }
        }

        if state.isMoving {
            guard shouldAcceptInteractionButton(button) else { return }
            guard let engine = controller.niriEngine,
                  let wsId = state.activeInteractionWorkspaceId ?? controller.interactionWorkspace()?.id
            else {
                return
            }

            traceMouseFocus("mouseDrag.interactiveMoveUpdate loc=\(formatPoint(location)) workspace=\(wsId.uuidString)")
            let hoverTarget = engine.interactiveMoveUpdate(currentLocation: location, in: wsId)
            state.dragGhostController?.updatePosition(cursorLocation: location)

            if let hoverTarget {
                switch hoverTarget {
                case let .window(nodeId, handle, insertPosition):
                    if insertPosition == .swap {
                        if let entry = controller.workspaceManager.entry(for: handle),
                           let frame = AXWindowService.framePreferFast(entry.axRef)
                        {
                            state.dragGhostController?.showSwapTarget(frame: frame)
                        }
                    } else if let dropFrame = engine.insertionDropzoneFrame(
                        targetWindowId: nodeId,
                        position: insertPosition,
                        in: wsId,
                        gaps: controller.workspaceManager.monitor(for: wsId).map { controller.gapSize(for: $0) }
                            ?? CGFloat(controller.workspaceManager.gaps)
                    ) {
                        state.dragGhostController?.showSwapTarget(frame: dropFrame)
                    }
                default:
                    state.dragGhostController?.hideSwapTarget()
                }
            } else {
                state.dragGhostController?.hideSwapTarget()
            }
            return
        }

        guard state.isResizing else { return }
        guard shouldAcceptInteractionButton(button) else { return }

        guard let engine = controller.niriEngine,
              let wsId = state.activeInteractionWorkspaceId ?? controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: wsId)
        else {
            return
        }

        let gaps = LayoutGaps(
            horizontal: controller.gapSize(for: monitor),
            vertical: controller.gapSize(for: monitor),
            outer: controller.outerGaps(for: monitor)
        )
        let insetFrame = controller.insetWorkingFrame(for: monitor)

        if engine.interactiveResizeUpdate(
            currentLocation: location,
            monitorFrame: insetFrame,
            gaps: gaps,
            viewportState: { mutate in
                controller.workspaceManager.withNiriViewportState(for: wsId, mutate)
            }
        ) {
            controller.layoutRefreshController.requestRefresh(reason: .interactiveGesture)
        }
    }

    private func handleMouseUpFromTap(at location: CGPoint, button: MouseButton, windowUnderPointer: Int? = nil) {
        guard let controller else { return }
        if controller.isOverviewOpen() { return }
        if button == .left {
            markRecentFloatingPointerInteractionIfNeeded(at: location, windowUnderPointer: windowUnderPointer)
        }
        traceMouseFocus(
            "mouseUp loc=\(formatPoint(location)) button=\(button) pressedButtons=\(pressedMouseButtonsProvider()) moving=\(state.isMoving) resizing=\(state.isResizing) activeButton=\(String(describing: state.activeInteractionButton))"
        )

        if state.isMoving {
            guard shouldAcceptInteractionButton(button) else { return }
            if let engine = controller.niriEngine,
               let wsId = state.activeInteractionWorkspaceId ?? controller.interactionWorkspace()?.id,
               let monitor = controller.workspaceManager.monitor(for: wsId)
            {
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                let gaps = controller.gapSize(for: monitor)
                var didEnd = false
                controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                    didEnd = engine.interactiveMoveEnd(
                        at: location,
                        in: wsId,
                        motion: controller.motionPolicy.snapshot(),
                        state: &vstate,
                        workingFrame: workingFrame,
                        gaps: gaps
                    )
                }
                if didEnd {
                    controller.layoutRefreshController.requestRefresh(reason: .interactiveGesture)
                }
            }

            state.dragGhostController?.endDrag()
            state.isMoving = false
            state.moveIsInsertMode = false
            state.activeInteractionButton = nil
            state.activeInteractionWorkspaceId = nil
            NSCursor.arrow.set()
            return
        }

        guard state.isResizing else { return }
        guard shouldAcceptInteractionButton(button) else { return }

        if let engine = controller.niriEngine,
           let wsId = state.activeInteractionWorkspaceId ?? controller.interactionWorkspace()?.id,
           let monitor = controller.workspaceManager.monitor(for: wsId)
        {
            let workingFrame = controller.insetWorkingFrame(for: monitor)
            let gaps = controller.gapSize(for: monitor)
            let hadInteractiveResize = engine.interactiveResize != nil

            controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                engine.interactiveResizeEnd(
                    motion: controller.motionPolicy.snapshot(),
                    state: &vstate,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            }
            if hadInteractiveResize {
                controller.layoutRefreshController.requestRefresh(reason: .interactiveGesture)
            }
        }

        state.isResizing = false
        state.activeInteractionButton = nil
        state.activeInteractionWorkspaceId = nil
        NSCursor.arrow.set()
        state.currentHoveredEdges = []
    }

    private func handleScrollWheelFromTap(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        guard let controller else { return }
        guard controller.isEnabled, controller.settings.scrollGestureEnabled else { return }
        if controller.isOverviewOpen() { return }
        if shouldBlockOwnWindowInput(at: location) { return }
        guard !state.isResizing, !state.isMoving else { return }

        let isTrackpad = momentumPhase != 0 || phase != 0
        if isTrackpad {
            return
        }

        let requiredModifiers = controller.settings.scrollModifierKey.cgEventFlag
        guard Self.mouseWheelModifiersMatch(modifiers, required: requiredModifiers) else {
            resetMouseWheelTrackers()
            return
        }

        guard let columnDelta = Self.resolvedMouseWheelColumnDelta(
            deltaX: deltaX,
            deltaY: deltaY,
            allowVerticalFallback: modifiers.contains(.maskShift)
        ) else { return }
        guard let context = resolveScrollContext(at: location) else { return }

        let ticks: Int
        switch columnDelta.axis {
        case .horizontal:
            ticks = state.horizontalWheelTracker.accumulate(columnDelta.value)
        case .vertical:
            ticks = state.verticalWheelTracker.accumulate(columnDelta.value)
        }
        guard ticks != 0 else { return }

        applyMouseWheelColumnTicks(
            ticks,
            engine: context.engine,
            wsId: context.wsId,
            monitor: context.monitor
        )
    }

    private func handleFocusFollowsMouse(at location: CGPoint, windowUnderPointer: Int? = nil) {
        guard let controller else { return }
        let policyDecision = controller.focusPolicyEngine.evaluate(.focusFollowsMouse)
        guard policyDecision.allowsFocusChange else {
            traceMouseFocus(
                "ffm.skip reason=policy policyReason=\(policyDecision.reason ?? "nil") loc=\(formatPoint(location))"
            )
            return
        }
        guard !controller.workspaceManager.isNonManagedFocusActive else {
            traceMouseFocus("ffm.skip reason=nonManaged loc=\(formatPoint(location))")
            return
        }
        guard !controller.workspaceManager.hasPendingNativeFullscreenTransition else {
            traceMouseFocus("ffm.skip reason=nativeFullscreenTransition loc=\(formatPoint(location))")
            return
        }
        guard !controller.workspaceManager.isAppFullscreenActive else {
            traceMouseFocus("ffm.skip reason=appFullscreen loc=\(formatPoint(location))")
            return
        }

        let now = Date()
        let confirmedToken = controller.workspaceManager.confirmedManagedFocusToken
        let pendingToken = controller.workspaceManager.activeFocusRequestToken

        let resolution = resolveFocusFollowsMouse(
            at: location,
            windowUnderPointer: windowUnderPointer
        )
        guard case let .target(target) = resolution else {
            traceMouseFocus(
                "ffm.skip reason=noTarget sub=\(resolution.skipReason) loc=\(formatPoint(location)) windowUnderPointer=\(windowUnderPointer.map(String.init) ?? "nil") confirmed=\(formatToken(confirmedToken)) pending=\(formatToken(pendingToken))"
            )
            return
        }
        let token = focusFollowsMouseToken(for: target)

        if token == confirmedToken {
            if let pendingToken, pendingToken != token {
                traceMouseFocus(
                    "ffm.activate reason=reassertConfirmed loc=\(formatPoint(location)) target=\(token) confirmed=\(formatToken(confirmedToken)) pending=\(pendingToken)"
                )
                state.lastFocusFollowsMouseTime = now
                state.lastFocusFollowsMouseToken = token
                activateFocusFollowsMouseTarget(target)
            }
            return
        }

        if token == pendingToken {
            traceMouseFocus(
                "ffm.skip reason=duplicatePending loc=\(formatPoint(location)) target=\(token) confirmed=\(formatToken(confirmedToken)) pending=\(formatToken(pendingToken))"
            )
            return
        }

        if token == state.lastFocusFollowsMouseToken,
           now.timeIntervalSince(state.lastFocusFollowsMouseTime) < state.focusFollowsMouseDebounce
        {
            traceMouseFocus(
                "ffm.skip reason=debounceSameTarget loc=\(formatPoint(location)) target=\(token) confirmed=\(formatToken(confirmedToken)) pending=\(formatToken(pendingToken)) lastToken=\(formatToken(state.lastFocusFollowsMouseToken))"
            )
            return
        }

        traceMouseFocus(
            "ffm.activate reason=hoverTarget loc=\(formatPoint(location)) target=\(token) confirmed=\(formatToken(confirmedToken)) pending=\(formatToken(pendingToken)) lastToken=\(formatToken(state.lastFocusFollowsMouseToken))"
        )
        state.lastFocusFollowsMouseTime = now
        state.lastFocusFollowsMouseToken = token
        activateFocusFollowsMouseTarget(target)
    }

    private func resolveFocusFollowsMouse(
        at location: CGPoint,
        windowUnderPointer: Int? = nil,
        allowWindowServerSnapshotFallback: Bool = true
    ) -> FocusFollowsMouseResolution {
        guard let controller else { return .noHitTest }
        guard let wsId = workspaceIdForPointer(at: location) ?? controller.interactionWorkspace()?.id else {
            return .noWorkspace
        }

        if isFloatingWindowCoveringPointer(at: location, in: wsId)
            || hasVisibleFloatingWindowOverNiriLayout(in: wsId)
            || controller.unmanagedInteractiveWindowServerWindowCovers(
                point: location,
                windowUnderPointer: windowUnderPointer,
                allowWindowServerSnapshotFallback: allowWindowServerSnapshotFallback
            )
        {
            return .occlusion
        }

        guard let engine = controller.niriEngine,
              let window = engine.hitTestFocusableWindow(point: location, in: wsId)
        else {
            return .noHitTest
        }
        return .target(.niri(workspaceId: wsId, window: window))
    }

    private func isFloatingWindowCoveringPointer(
        at location: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        floatingEntryCoveringPointer(at: location, in: workspaceId) != nil
    }

    private func hasVisibleFloatingWindowOverNiriLayout(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }

        if let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
           let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
           focusedEntry.workspaceId == workspaceId,
           focusedEntry.mode == .tiling
        {
            return false
        }

        let layoutFrame = controller.workspaceManager.monitor(for: workspaceId)?.visibleFrame
        return controller.workspaceManager.floatingEntries(in: workspaceId).contains { entry in
            guard entry.observedState.isVisible, entry.visibility == .visible else { return false }
            let frame = floatingFrame(for: entry)
            guard let frame else { return true }
            return layoutFrame.map { frame.intersects($0) } ?? true
        }
    }

    private func floatingEntryCoveringPointer(
        at location: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowModel.Entry? {
        guard let controller else { return nil }
        return controller.workspaceManager.floatingEntries(in: workspaceId).first { entry in
            guard entry.observedState.isVisible, entry.visibility == .visible else { return false }
            return floatingFrame(for: entry)?.contains(location) ?? false
        }
    }

    private func floatingFrame(for entry: WindowModel.Entry) -> CGRect? {
        entry.observedState.frame
            ?? entry.desiredState.floatingFrame
            ?? entry.floatingState?.lastFrame
            ?? AXWindowService.framePreferFast(entry.axRef)
    }

    private func markRecentFloatingPointerInteractionIfNeeded(
        at location: CGPoint,
        windowUnderPointer: Int? = nil,
        allowWindowServerSnapshotFallback: Bool = true
    ) {
        guard let controller else { return }
        let workspaceId = workspaceIdForPointer(at: location) ?? controller.interactionWorkspace()?.id
        let floatingEntry = workspaceId.flatMap {
            floatingEntryCoveringPointer(at: location, in: $0)
        }
        if let floatingEntry {
            controller.suppressMouseMoveToFocusedWindow(for: floatingEntry.token)
        }
        let isOverUnmanaged = controller.unmanagedWindowServerWindowCovers(
            point: location,
            windowUnderPointer: windowUnderPointer,
            allowWindowServerSnapshotFallback: allowWindowServerSnapshotFallback
        )
        guard floatingEntry != nil || isOverUnmanaged else { return }
        state.suppressFocusFollowsMouseUntil = Date().addingTimeInterval(2.0)
    }

    private func focusFollowsMouseToken(for target: FocusFollowsMouseTarget) -> WindowToken {
        switch target {
        case let .niri(_, window):
            window.token
        }
    }

    private func suppressMouseMoveToFocusedWindowForPointerTarget(
        at location: CGPoint,
        windowUnderPointer: Int? = nil
    ) {
        guard let target = resolveFocusFollowsMouse(
            at: location,
            windowUnderPointer: windowUnderPointer
        ).targetValue else { return }
        controller?.suppressMouseMoveToFocusedWindow(for: focusFollowsMouseToken(for: target))
    }

    private func activateFocusFollowsMouseTarget(_ target: FocusFollowsMouseTarget) {
        guard let controller else { return }

        switch target {
        case let .niri(workspaceId, window):
            controller.suppressMouseMoveToFocusedWindow(for: window.token)
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { vstate in
                vstate.pendingFFMFocusToken = window.token
                vstate.pendingFFMFocusTimestamp = Date()
                controller.niriLayoutHandler.activateNode(
                    window,
                    in: workspaceId,
                    state: &vstate,
                    options: .init(
                        ensureVisible: false,
                        preserveViewportAnchor: true,
                        layoutRefresh: false,
                        startAnimation: false
                    )
                )
            }
        }
    }

    private func handleGestureEvent(_ snapshot: GestureEventSnapshot) {
        guard let controller else { return }
        let location = snapshot.location
        let phase = NSEvent.Phase(rawValue: snapshot.phaseRawValue)
        let activeTouchCount = snapshot.touches.filter { $0.phase != .ended && $0.phase != .cancelled }.count

        if state.suppressGestureUntilTouchesEnd {
            if phase == .ended || phase == .cancelled || activeTouchCount == 0 {
                state.suppressGestureUntilTouchesEnd = false
            } else {
                traceGestureSkip(
                    reason: "suppressed",
                    location: location,
                    activeTouches: activeTouchCount,
                    phase: phase
                )
                return
            }
        }

        guard controller.isEnabled else {
            traceGestureSkip(reason: "disabled", location: location, activeTouches: activeTouchCount, phase: phase)
            abortActiveGestureIfNeeded()
            return
        }
        guard controller.settings.scrollGestureEnabled else {
            traceGestureSkip(reason: "disabled", location: location, activeTouches: activeTouchCount, phase: phase)
            abortActiveGestureIfNeeded()
            return
        }
        if controller.isOverviewOpen() {
            traceGestureSkip(reason: "overview", location: location, activeTouches: activeTouchCount, phase: phase)
            abortActiveGestureIfNeeded()
            return
        }
        if shouldBlockOwnWindowInput(at: location) {
            traceGestureSkip(reason: "ownWindow", location: location, activeTouches: activeTouchCount, phase: phase)
            abortActiveGestureIfNeeded()
            return
        }
        // Gestures only trust the event-provided window id for unmanaged-overlay
        // suppression. Screen-share/capture surfaces can appear in the broad
        // WindowServer snapshot fallback while gesture events report no
        // window-under-pointer, so probing the snapshot-only path here can
        // suppress an otherwise valid touch sequence. Focus-follows-mouse keeps
        // its stricter snapshot policy separately.
        let isOverUnmanagedOverlay = controller.unmanagedWindowServerWindowCovers(
            point: location,
            windowUnderPointer: snapshot.windowUnderPointer,
            allowWindowServerSnapshotFallback: false
        )
        if isOverUnmanagedOverlay,
           phase != .ended,
           phase != .cancelled,
           activeTouchCount > 0
        {
            traceMouseFocus(
                "gesture.skip reason=unmanagedOverlay loc=\(formatPoint(location)) windowUnderPointer=\(snapshot.windowUnderPointer.map(String.init) ?? "nil") snapshotProbe=false"
            )
            abortActiveGestureIfNeeded()
            state.suppressGestureUntilTouchesEnd = true
            return
        }
        guard !state.isResizing, !state.isMoving else {
            traceGestureSkip(reason: "busy", location: location, activeTouches: activeTouchCount, phase: phase)
            abortActiveGestureIfNeeded()
            return
        }
        guard let engine = controller.niriEngine else {
            traceGestureSkip(reason: "noEngine", location: location, activeTouches: activeTouchCount, phase: phase)
            abortActiveGestureIfNeeded()
            return
        }

        let requiredFingers = controller.settings.gestureFingerCount.rawValue
        let invertDirection = controller.settings.gestureInvertDirection

        if phase == .ended || phase == .cancelled {
            if state.gesturePhase == .committed {
                guard let lockedContext = state.lockedGestureContext else {
                    assertionFailure("Committed gesture missing locked context")
                    resetGestureState()
                    return
                }
                finalizeOrCancelCommittedGesture(
                    using: lockedContext,
                    engine: engine,
                    timestamp: snapshot.timestamp
                )
            }
            resetGestureState()
            return
        }

        if phase == .began, state.gesturePhase != .idle {
            traceGestureSkip(
                reason: "conflict",
                location: location,
                requiredFingers: requiredFingers,
                activeTouches: activeTouchCount,
                phase: phase
            )
            abortActiveGestureIfNeeded()
        }

        guard resolveScrollContext(at: location) != nil else {
            traceGestureSkip(
                reason: "noScrollContext",
                location: location,
                requiredFingers: requiredFingers,
                activeTouches: activeTouchCount,
                phase: phase
            )
            abortActiveGestureIfNeeded()
            return
        }
        guard !snapshot.touches.isEmpty else {
            traceGestureSkip(
                reason: "emptyTouches",
                location: location,
                requiredFingers: requiredFingers,
                activeTouches: activeTouchCount,
                phase: phase
            )
            abortActiveGestureIfNeeded()
            return
        }
        guard let averageTouchPosition = Self.averageGestureTouchPosition(
            requiredFingers: requiredFingers,
            touches: snapshot.touches
        ) else {
            if state.gesturePhase == .committed, activeTouchCount < requiredFingers {
                finalizeCommittedGestureAfterTouchRelease(
                    engine: engine,
                    timestamp: snapshot.timestamp
                )
                return
            }
            // averageGestureTouchPosition returns nil for over/under-count or unusable touch
            // positions; re-derive the concrete reason from the active touch count for diagnosis.
            let matcherReason = activeTouchCount > requiredFingers
                ? "overCount"
                : (activeTouchCount < requiredFingers ? "underCount" : "malformedTouch")
            traceGestureSkip(
                reason: matcherReason,
                location: location,
                requiredFingers: requiredFingers,
                activeTouches: activeTouchCount,
                phase: phase
            )
            abortActiveGestureIfNeeded()
            return
        }

        let avgX = averageTouchPosition.x
        let avgY = averageTouchPosition.y

        switch state.gesturePhase {
        case .idle:
            // Only admit a new gesture from an explicit `.began` frame. A valid-count
            // `.changed` while idle is a stale same-count frame or a continuation after
            // a prior reset, not a genuine start — the raw source now emits `.began` on
            // real contact-count ramps (1→2→3), so legitimate ramps still arrive here as
            // `.began`. This guard only affects idle admission; committed gestures are
            // handled in the `.armed`/`.committed` case and are untouched.
            guard phase == .began else {
                traceGestureSkip(
                    reason: "changedWithoutBegin",
                    location: location,
                    requiredFingers: requiredFingers,
                    activeTouches: activeTouchCount,
                    phase: phase
                )
                return
            }
            guard let currentContext = resolveScrollContext(at: location) else {
                traceGestureSkip(
                    reason: "noScrollContext",
                    location: location,
                    requiredFingers: requiredFingers,
                    activeTouches: activeTouchCount,
                    phase: phase
                )
                abortActiveGestureIfNeeded()
                return
            }
            state.lockedGestureContext = .init(
                workspaceId: currentContext.wsId,
                monitorId: currentContext.monitor.id,
                bypassSnap: Self.modifierFlagsMatch(
                    snapshot.modifiers,
                    required: controller.settings.mouseResizeModifierKey.cgEventFlag
                )
            )
            state.gestureStartX = avgX
            state.gestureStartY = avgY
            state.gestureLastAverageX = avgX
            state.gestureLastAverageY = avgY
            // The `.idle` case guarded `phase == .began` above, so this arm is always an
            // explicit begin admission — kept as an `idleAdmissionKind=began` field so a
            // validation capture can confirm the fix (no more `idleAdmissionKind=changed`).
            state.gesturePhase = .armed
            let inputPhaseName = Self.gesturePhaseName(phase)
            var armedTraceDetails = [
                "input=trackpadTouches",
                "requiredFingers=\(requiredFingers)",
                "activeTouches=\(activeTouchCount)",
                "phase=\(phase.rawValue)",
                "inputPhaseRaw=\(phase.rawValue)",
                "inputPhaseName=\(inputPhaseName)",
                "previousGesturePhase=idle",
                "idleAdmission=true",
                "idleAdmissionKind=began",
                "rawActiveCount=\(activeTouchCount)",
                String(format: "startTouch=%.3f,%.3f", avgX, avgY)
            ]
            if let previousRawActiveCount = snapshot.previousRawActiveCount {
                armedTraceDetails.append("previousRawActiveCount=\(previousRawActiveCount)")
                armedTraceDetails.append("activeCountDelta=\(activeTouchCount - previousRawActiveCount)")
            }
            let viewportState = controller.workspaceManager.niriViewportState(for: currentContext.wsId)
            if !viewportState.viewOffsetPixels.isGesture, viewportState.viewOffsetPixels.isAnimating {
                controller.recordRuntimeViewportTrace(
                    workspaceId: currentContext.wsId,
                    reason: "touch_scroll_gesture_armed_with_preexisting_animation",
                    details: armedTraceDetails
                )
            }
            controller.recordRuntimeViewportTrace(
                workspaceId: currentContext.wsId,
                reason: "touch_scroll_gesture_armed",
                details: armedTraceDetails
            )

        case .armed,
             .committed:
            guard var lockedContext = state.lockedGestureContext else {
                assertionFailure("Active gesture missing locked context")
                traceGestureSkip(
                    reason: "noContext",
                    location: location,
                    requiredFingers: requiredFingers,
                    activeTouches: activeTouchCount,
                    phase: phase
                )
                abortActiveGestureIfNeeded()
                return
            }
            if !lockedContext.bypassSnap,
               Self.modifierFlagsMatch(
                   snapshot.modifiers,
                   required: controller.settings.mouseResizeModifierKey.cgEventFlag
               )
            {
                lockedContext = .init(
                    workspaceId: lockedContext.workspaceId,
                    monitorId: lockedContext.monitorId,
                    bypassSnap: true
                )
                state.lockedGestureContext = lockedContext
            }
            let wsId = lockedContext.workspaceId
            guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
                traceGestureSkip(
                    reason: "noMonitor",
                    location: location,
                    requiredFingers: requiredFingers,
                    activeTouches: activeTouchCount,
                    phase: phase
                )
                abortActiveGestureIfNeeded()
                return
            }

            let cumulativeX = (avgX - state.gestureStartX) * macNormalizedTouchPositionToNiriGestureUnits
            let cumulativeY = (avgY - state.gestureStartY) * macNormalizedTouchPositionToNiriGestureUnits
            let previousPhase = state.gesturePhase
            let rawDeltaX: CGFloat

            if previousPhase == .armed {
                let distanceSquared = cumulativeX * cumulativeX + cumulativeY * cumulativeY
                let thresholdSquared = niriTouchpadGestureRecognitionThreshold * niriTouchpadGestureRecognitionThreshold
                guard distanceSquared >= thresholdSquared else {
                    state.gestureLastAverageX = avgX
                    state.gestureLastAverageY = avgY
                    return
                }

                guard abs(cumulativeX) > abs(cumulativeY) else {
                    traceGestureSkip(
                        reason: "nonHorizontal",
                        location: location,
                        requiredFingers: requiredFingers,
                        activeTouches: activeTouchCount,
                        phase: phase
                    )
                    abortActiveGestureIfNeeded()
                    return
                }

                let overshootMagnitude = max(0.0, abs(cumulativeX) - niriTouchpadGestureRecognitionThreshold)
                rawDeltaX = (cumulativeX < 0 ? -1.0 : 1.0) * overshootMagnitude
                state.gesturePhase = .committed
                // Retain the commit metrics so the first committed update can report
                // how much pre-recognition movement was discarded by the dead zone.
                state.pendingFirstUpdateAfterCommit = true
                state.commitCumulativeX = cumulativeX
                state.commitCumulativeY = cumulativeY
                state.commitRawDeltaX = cumulativeX
                state.commitInputPhaseName = Self.gesturePhaseName(phase)
                state.commitTimestamp = snapshot.timestamp
                controller.recordRuntimeViewportTrace(
                    workspaceId: wsId,
                    reason: "touch_scroll_gesture_committed",
                    details: [
                        "input=trackpadTouches",
                        "requiredFingers=\(requiredFingers)",
                        "activeTouches=\(activeTouchCount)",
                        String(format: "cumulativeX=%.3f", cumulativeX),
                        String(format: "cumulativeY=%.3f", cumulativeY),
                        String(format: "threshold=%.3f", niriTouchpadGestureRecognitionThreshold)
                    ]
                )
            } else {
                rawDeltaX = (avgX - state.gestureLastAverageX) * macNormalizedTouchPositionToNiriGestureUnits
            }

            state.gestureLastAverageX = avgX
            state.gestureLastAverageY = avgY

            var deltaUnits = rawDeltaX * CGFloat(controller.settings.scrollSensitivity)
            if invertDirection {
                deltaUnits = -deltaUnits
            }

            applyTrackpadViewportScrollDelta(
                deltaUnits,
                engine: engine,
                wsId: wsId,
                monitor: monitor,
                timestamp: snapshot.timestamp
            )
        }
    }

    func applyTrackpadViewportScrollDelta(
        _ delta: CGFloat,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        timestamp: TimeInterval = CACurrentMediaTime()
    ) {
        guard let controller else { return }
        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let viewportWidth = insetFrame.width
        let gap = controller.gapSize(for: monitor)
        let scale = backingScale(for: monitor)

        var didApply = false
        var didInterruptAnimation = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            if vstate.viewOffsetPixels.isAnimating {
                vstate.settleAtCurrentOffset()
                didInterruptAnimation = true
            }

            engine.prepareAndSeedSingleWindowViewport(
                in: wsId,
                workingFrame: insetFrame,
                containingFrame: monitor.frame,
                scale: scale,
                gaps: gap,
                state: &vstate
            )
            let columns = engine.columns(in: wsId)

            if !vstate.viewOffsetPixels.isGesture {
                guard vstate.beginGesture(isTrackpad: true, columns: columns) else { return }
            }

            _ = vstate.updateGesture(
                deltaPixels: delta,
                timestamp: timestamp,
                isTrackpad: true,
                columns: columns,
                gap: gap,
                viewportWidth: viewportWidth
            )
            didApply = true
        }
        if didInterruptAnimation {
            controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
        }
        if didApply {
            let isFirstUpdateAfterCommit = state.pendingFirstUpdateAfterCommit
            if controller.settings.viewportTraceVerbosity.includesGestureFrameUpdates {
                var updateDetails = [
                    "input=trackpadTouches",
                    String(format: "delta=%.3f", delta),
                    "phase=committed"
                ]
                if isFirstUpdateAfterCommit {
                    updateDetails.append("firstUpdate=true")
                }
                controller.recordRuntimeViewportTrace(
                    workspaceId: wsId,
                    reason: "touch_scroll_gesture_update",
                    details: updateDetails
                )
            }
            if isFirstUpdateAfterCommit {
                emitFirstUpdateDiagnostic(appliedDelta: delta, wsId: wsId)
                state.pendingFirstUpdateAfterCommit = false
            }
            controller.layoutRefreshController.requestRefresh(reason: .interactiveGesture)
        }
    }

    // Emits `touch_scroll_gesture_first_update` linking the just-applied first
    // committed delta back to the commit's cumulative recognition movement, so a
    // capture can tell — without manual pairing — whether the first update was
    // reduced to only the movement beyond the recognition dead zone.
    private func emitFirstUpdateDiagnostic(appliedDelta: CGFloat, wsId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        let threshold = niriTouchpadGestureRecognitionThreshold
        let rawDeltaX = state.commitRawDeltaX
        // The first committed update should apply only the movement beyond the
        // recognition threshold along the committed axis.
        let overshootMagnitude = max(0.0, abs(rawDeltaX) - threshold)
        let signedOvershoot = (rawDeltaX < 0 ? -1.0 : 1.0) * overshootMagnitude
        let sensitivity = CGFloat(controller.settings.scrollSensitivity)
        let invert = controller.settings.gestureInvertDirection
        var wouldDeadZoneDelta = signedOvershoot * sensitivity
        if invert { wouldDeadZoneDelta = -wouldDeadZoneDelta }
        let includesRecognitionDebt = abs(appliedDelta - wouldDeadZoneDelta) > 0.001
        controller.recordRuntimeViewportTrace(
            workspaceId: wsId,
            reason: "touch_scroll_gesture_first_update",
            details: [
                "input=trackpadTouches",
                String(format: "commitCumulativeX=%.3f", state.commitCumulativeX),
                String(format: "commitCumulativeY=%.3f", state.commitCumulativeY),
                String(format: "threshold=%.3f", threshold),
                String(format: "rawDelta=%.3f", rawDeltaX),
                String(format: "appliedDelta=%.3f", appliedDelta),
                String(format: "wouldDeadZoneDelta=%.3f", wouldDeadZoneDelta),
                "includesRecognitionDebt=\(includesRecognitionDebt)",
                "commitInputPhase=\(state.commitInputPhaseName)",
                "phase=committed"
            ]
        )
    }

    private func backingScale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?
            .backingScaleFactor ?? 2.0
    }

    private func applyMouseWheelColumnTicks(
        _ ticks: Int,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) {
        guard let controller else { return }
        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let gap = controller.gapSize(for: monitor)
        let step = ticks > 0 ? 1 : -1
        let motion = controller.motionPolicy.snapshot()

        var didApply = false
        var shouldStartAnimation = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            if vstate.viewOffsetPixels.gestureRef?.isTrackpad == true {
                return
            }

            for _ in 0 ..< abs(ticks) {
                let columns = engine.columns(in: wsId)
                let targetColumnIndex = vstate.activeColumnIndex + step
                guard columns.indices.contains(targetColumnIndex),
                      let currentNode = currentSelectionNode(engine: engine, wsId: wsId, state: vstate),
                      let newNode = engine.focusColumn(
                          targetColumnIndex,
                          currentSelection: currentNode,
                          in: wsId,
                          motion: motion,
                          state: &vstate,
                          workingFrame: insetFrame,
                          gaps: gap
                      )
                else {
                    break
                }

                controller.niriLayoutHandler.activateNode(
                    newNode,
                    in: wsId,
                    state: &vstate,
                    options: .init(
                        activateWindow: true,
                        ensureVisible: false,
                        updateTimestamp: true,
                        layoutRefresh: false,
                        axFocus: false,
                        startAnimation: false
                    )
                )
                didApply = true
            }
            shouldStartAnimation = vstate.viewOffsetPixels.isAnimating
        }

        if didApply {
            controller.recordRuntimeViewportTrace(workspaceId: wsId, reason: "wheel_tick")
            controller.layoutRefreshController.requestRefresh(reason: .interactiveGesture)
            if shouldStartAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
        }
    }

    func finalizeOrCancelCommittedGesture(
        using lockedContext: State.LockedGestureContext,
        engine: NiriLayoutEngine,
        timestamp: TimeInterval? = nil
    ) {
        guard let controller else { return }
        let wsId = lockedContext.workspaceId
        guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            cancelCommittedGestureViewportState(for: wsId)
            return
        }

        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let gap = controller.gapSize(for: monitor)
        let scale = backingScale(for: monitor)
        engine.prepareSingleWindowViewport(
            in: wsId,
            workingFrame: insetFrame,
            containingFrame: monitor.frame,
            scale: scale,
            gaps: gap
        )
        let columns = engine.columns(in: wsId)

        var selectedWindow: NiriWindow?
        var previousActiveColumnIndex: Int?
        var endedActiveColumnIndex: Int?
        var endedGestureIsAnimating = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { endState in
            previousActiveColumnIndex = endState.activeColumnIndex
            let snapToColumn = !lockedContext.bypassSnap
            if let gesture = endState.viewOffsetPixels.gestureRef {
                let normFactor = gesture.isTrackpad
                    ? Double(insetFrame.width) / VIEW_GESTURE_WORKING_AREA_MOVEMENT
                    : 1.0
                let activeColumnX = Double(endState.columnX(
                    at: endState.activeColumnIndex,
                    columns: columns,
                    gap: gap
                ))
                let currentOffset = gesture.current()
                let velocity = gesture.tracker.velocity() * normFactor
                let rawProjectedOffset = gesture.tracker.projectedEndPosition() * normFactor
                    + gesture.deltaFromTracker
                let currentViewStart = activeColumnX + currentOffset
                let rawProjectedViewStart = activeColumnX + rawProjectedOffset
                let projectedViewStart = gesture.isTrackpad
                    ? clampedTrackpadGestureProjectedViewStart(
                        rawProjectedViewStart: rawProjectedViewStart,
                        currentViewStart: currentViewStart,
                        viewportWidth: insetFrame.width
                    )
                    : rawProjectedViewStart
                let projectedOffset = projectedViewStart - activeColumnX
                let snapContext = endState.snapContext(
                    columns: columns,
                    gap: gap,
                    viewportWidth: insetFrame.width
                )
                let rawClosestSnap = snapToColumn
                    ? snapContext.closest(to: CGFloat(rawProjectedViewStart))
                    : nil
                let closestSnap = snapToColumn
                    ? snapContext.closest(to: CGFloat(projectedViewStart))
                    : nil
                let targetOffset = closestSnap.map { snapContext.targetOffset(for: $0, in: endState) }
                var details = [
                    "input=trackpadTouches",
                    "snap=\(snapToColumn)",
                    "activeColumnIndex=\(endState.activeColumnIndex)",
                    String(format: "currentOffset=%.3f", currentOffset),
                    String(format: "currentViewStart=%.3f", currentViewStart),
                    String(format: "projectedOffset=%.3f", projectedOffset),
                    String(format: "projectedViewStart=%.3f", projectedViewStart),
                    String(format: "velocity=%.3f", velocity),
                    String(format: "timestamp=%.6f", timestamp ?? CACurrentMediaTime()),
                    String(format: "clockNow=%.6f", CACurrentMediaTime()),
                    "snapPointCount=\(snapContext.snapPoints.count)"
                ]
                if let closestSnap {
                    details.append(String(format: "closestSnap=%.3f", closestSnap.offset))
                    details.append("closestSnapColumn=\(closestSnap.columnIndex)")
                    details.append("closestSnapKind=\(closestSnap.kind)")
                    details.append(String(
                        format: "closestSnapDistance=%.3f",
                        abs(Double(closestSnap.offset) - projectedViewStart)
                    ))
                } else {
                    details.append("closestSnap=nil")
                }
                if let rawClosestSnap {
                    details.append(String(format: "rawClosestSnap=%.3f", rawClosestSnap.offset))
                    details.append("rawClosestSnapColumn=\(rawClosestSnap.columnIndex)")
                    details.append("rawClosestSnapKind=\(rawClosestSnap.kind)")
                    details.append(String(
                        format: "rawClosestSnapDistance=%.3f",
                        abs(Double(rawClosestSnap.offset) - rawProjectedViewStart)
                    ))
                } else {
                    details.append("rawClosestSnap=nil")
                }
                if let targetOffset {
                    details.append(String(format: "targetOffset=%.3f", targetOffset))
                }
                // Derived release-projection distances so a capture can classify a
                // multi-column release by grep alone. `wouldClamp` reports whether the
                // configured projection clamp changed the raw projected release point.
                let viewportWidth = Double(insetFrame.width)
                let rawProjectionDeltaFromCurrent = rawProjectedViewStart - currentViewStart
                let rawProjectionScreens = viewportWidth > 0 ? rawProjectionDeltaFromCurrent / viewportWidth : 0
                let projectionDeltaFromCurrent = projectedViewStart - currentViewStart
                let projectionScreens = viewportWidth > 0 ? projectionDeltaFromCurrent / viewportWidth : 0
                details.append(String(format: "rawProjectedOffset=%.3f", rawProjectedOffset))
                details.append(String(format: "rawProjectedViewStart=%.3f", rawProjectedViewStart))
                details.append(String(format: "rawProjectionDeltaFromCurrent=%.3f", rawProjectionDeltaFromCurrent))
                details.append(String(format: "rawProjectionScreens=%.3f", rawProjectionScreens))
                details.append(String(format: "projectionDeltaFromCurrent=%.3f", projectionDeltaFromCurrent))
                details.append(String(format: "projectionScreens=%.3f", projectionScreens))
                details.append("projectedColumnDelta=\(Int(projectionScreens.rounded()))")
                if let closestSnap {
                    details.append("targetColumnDelta=\(closestSnap.columnIndex - endState.activeColumnIndex)")
                } else {
                    details.append("targetColumnDelta=nil")
                }
                if let rawClosestSnap {
                    details.append("rawTargetColumnDelta=\(rawClosestSnap.columnIndex - endState.activeColumnIndex)")
                } else {
                    details.append("rawTargetColumnDelta=nil")
                }
                details.append("wouldClamp=\(abs(rawProjectedViewStart - projectedViewStart) > 0.001)")
                details.append(String(format: "clampScreens=%.3f", maxTrackpadGestureProjectionScreens))
                details.append(String(format: "diagnosticClampScreens=%.3f", maxTrackpadGestureProjectionScreens))
                details.append(String(format: "clampedProjectedViewStart=%.3f", projectedViewStart))
                details.append("clampedTargetColumn=\(closestSnap.map { String($0.columnIndex) } ?? "nil")")
                controller.recordRuntimeViewportTrace(
                    workspaceId: wsId,
                    reason: "touch_scroll_gesture_end_candidate",
                    details: details
                )
            }
            endState.endGesture(
                columns: columns,
                gap: gap,
                viewportWidth: insetFrame.width,
                motion: controller.motionPolicy.snapshot(),
                isTrackpad: true,
                snapToColumn: snapToColumn,
                workingArea: insetFrame,
                viewFrame: monitor.frame,
                scale: scale,
                timestamp: timestamp
            )
            endedGestureIsAnimating = endState.viewOffsetPixels.isAnimating
            endedActiveColumnIndex = endState.activeColumnIndex
            if !lockedContext.bypassSnap {
                selectedWindow = syncViewportSelectionToActiveColumn(columns: columns, state: &endState)
            }
        }
        var didRequestFocus = false
        if let selectedWindow {
            rememberViewportFocusAnchor(selectedWindow, engine: engine, wsId: wsId)
            if !controller.focusFollowsMouseEnabled,
               !controller.workspaceManager.isNonManagedFocusActive,
               let target = controller.managedKeyboardFocusTarget(for: selectedWindow.token)
            {
                _ = controller.renderKeyboardFocusBorder(
                    for: target,
                    preferredFrame: selectedWindow.renderedFrame ?? selectedWindow.frame,
                    forceOrdering: false
                )
                controller.suppressMouseMoveToFocusedWindow(for: selectedWindow.token)
                controller.focusWindow(selectedWindow.token)
                didRequestFocus = true
            }
        }
        let focusSelectionDisposition: String
        if selectedWindow == nil {
            focusSelectionDisposition = "none"
        } else if controller.focusFollowsMouseEnabled {
            focusSelectionDisposition = "suppressed"
        } else if controller.workspaceManager.isNonManagedFocusActive {
            focusSelectionDisposition = "suppressedNonManagedFocus"
        } else if didRequestFocus {
            focusSelectionDisposition = "requested"
        } else {
            focusSelectionDisposition = "skippedNoManagedTarget"
        }
        controller.recordRuntimeViewportTrace(
            workspaceId: wsId,
            reason: "touch_scroll_gesture_end",
            details: [
                "input=trackpadTouches",
                "snap=\(!lockedContext.bypassSnap)",
                "focusSelection=\(focusSelectionDisposition)",
                "focusFollowsMouse=\(controller.focusFollowsMouseEnabled)",
                "endedGestureIsAnimating=\(endedGestureIsAnimating)",
                "previousActiveColumnIndex=\(previousActiveColumnIndex.map(String.init) ?? "nil")",
                "endedActiveColumnIndex=\(endedActiveColumnIndex.map(String.init) ?? "nil")"
            ]
        )
        if endedGestureIsAnimating {
            // Only suppress for the previously confirmed token when snapping didn't already
            // set suppression for the newly selected window — overwriting that entry would cause a
            // token mismatch and let the cursor warp through.
            if !didRequestFocus, let token = controller.workspaceManager.confirmedManagedFocusToken {
                controller.suppressMouseMoveToFocusedWindow(for: token)
            }
            controller.layoutRefreshController.startScrollAnimation(for: wsId)
        } else {
            controller.layoutRefreshController.requestRefresh(reason: .interactiveGesture)
            if controller.focusFollowsMouseEnabled {
                refreshFocusFollowsMouseAtCurrentPointer()
            }
        }
    }

    private func finalizeCommittedGestureAfterTouchRelease(
        engine: NiriLayoutEngine,
        timestamp: TimeInterval
    ) {
        guard let lockedContext = state.lockedGestureContext else {
            assertionFailure("Committed gesture missing locked context")
            resetGestureState()
            return
        }
        finalizeOrCancelCommittedGesture(
            using: lockedContext,
            engine: engine,
            timestamp: timestamp
        )
        resetGestureState()
        state.suppressGestureUntilTouchesEnd = true
    }

    private func cancelCommittedGestureViewportState(for wsId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        var didCancel = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            guard vstate.viewOffsetPixels.isGesture || vstate.viewOffsetPixels.isAnimating else { return }
            vstate.settleAtCurrentOffset()
            vstate.selectionProgress = 0.0
            vstate.viewOffsetToRestore = nil
            vstate.activatePrevColumnOnRemoval = nil
            didCancel = true
        }
        if didCancel {
            controller.recordRuntimeViewportTrace(workspaceId: wsId, reason: "gesture_cancel")
            controller.layoutRefreshController.requestRefresh(reason: .interactiveGesture)
        }
    }

    private func abortActiveGestureIfNeeded() {
        let previousGesturePhase = state.gesturePhase
        if previousGesturePhase == .armed {
            // An armed (not-yet-committed) gesture is dying. Surface it in the viewport
            // trace stream alongside the armed/committed/end records so an "eaten" swipe
            // (#53) is visible. Purely additive: a no-op unless trace capture is active.
            if let wsId = state.lockedGestureContext?.workspaceId, let controller {
                controller.recordRuntimeViewportTrace(
                    workspaceId: wsId,
                    reason: "touch_scroll_gesture_abort",
                    details: [
                        "input=trackpadTouches",
                        "phase=armed"
                    ]
                )
            }
        }
        if previousGesturePhase == .committed {
            guard let lockedContext = state.lockedGestureContext else {
                assertionFailure("Committed gesture missing locked context")
                resetGestureState()
                return
            }
            if let engine = controller?.niriEngine {
                finalizeOrCancelCommittedGesture(using: lockedContext, engine: engine)
            } else {
                cancelCommittedGestureViewportState(for: lockedContext.workspaceId)
            }
        }
        resetGestureState()
    }

    private func resolveScrollContext(at location: CGPoint) -> (
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor
    )? {
        guard let controller,
              let engine = controller.niriEngine
        else {
            return nil
        }

        let monitors = controller.workspaceManager.monitors
        guard let monitor = location.monitorApproximation(in: monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return nil
        }

        return (engine, workspace.id, monitor)
    }

    private func resetGestureState() {
        state.gesturePhase = .idle
        state.gestureStartX = 0.0
        state.gestureStartY = 0.0
        state.gestureLastAverageX = 0.0
        state.gestureLastAverageY = 0.0
        state.lockedGestureContext = nil
        state.pendingFirstUpdateAfterCommit = false
        state.commitCumulativeX = 0.0
        state.commitCumulativeY = 0.0
        state.commitRawDeltaX = 0.0
        state.commitInputPhaseName = ""
        state.commitTimestamp = 0.0
    }

    private func currentSelectionNode(
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState
    ) -> NiriNode? {
        if let selectedNodeId = state.selectedNodeId,
           let selectedNode = engine.findNode(by: selectedNodeId)
        {
            return selectedNode
        }

        let columns = engine.columns(in: wsId)
        guard columns.indices.contains(state.activeColumnIndex) else { return nil }
        let activeColumn = columns[state.activeColumnIndex]
        let windows = activeColumn.windowNodes
        guard !windows.isEmpty else { return activeColumn.firstChild() }
        let activeTileIndex = activeColumn.activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        return windows[activeTileIndex]
    }

    private func syncViewportSelectionToActiveColumn(
        columns: [NiriContainer],
        state: inout ViewportState
    ) -> NiriWindow? {
        guard columns.indices.contains(state.activeColumnIndex) else { return nil }
        let activeColumn = columns[state.activeColumnIndex]
        let windows = activeColumn.windowNodes
        guard !windows.isEmpty else { return nil }
        let activeTileIndex = activeColumn.activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        let selectedWindow = windows[activeTileIndex]
        state.selectedNodeId = selectedWindow.id
        return selectedWindow
    }

    private func rememberViewportFocusAnchor(
        _ window: NiriWindow,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: nil,
                rememberedFocusToken: window.token
            )
        )
        engine.updateFocusTimestamp(for: window.id)
    }

    private nonisolated static func processTapCallback(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard isMainThread else { return false }

        let location = event.location
        let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)
        let modifiers = event.flags
        let directWindowRaw = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        let eventHandlingWindowRaw = Int(
            event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        )
        let windowUnderPointer = windowUnderPointer(direct: directWindowRaw, canHandle: eventHandlingWindowRaw)
        let scrollPayload: (deltaX: CGFloat, deltaY: CGFloat, momentumPhase: UInt32, phase: UInt32)?
        if type == .scrollWheel {
            scrollPayload = (
                resolvedWheelAxisDelta(
                    pointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
                    fixedPointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
                ),
                resolvedWheelAxisDelta(
                    pointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)),
                    fixedPointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
                ),
                UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase)),
                UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))
            )
        } else {
            scrollPayload = nil
        }
        var suppressEvent = false

        MainActor.assumeIsolated {
            guard let handler = MouseEventHandler._instance else { return }
            switch type {
            case .mouseMoved:
                handler.traceTapMouseMovedRawFields(
                    direct: directWindowRaw,
                    canHandle: eventHandlingWindowRaw,
                    resolved: windowUnderPointer,
                    location: screenLocation
                )
                handler.receiveTapMouseMoved(at: screenLocation, windowUnderPointer: windowUnderPointer)
            case .leftMouseDown:
                _ = handler.receiveTapMouseDown(
                    at: screenLocation,
                    modifiers: modifiers,
                    windowUnderPointer: windowUnderPointer
                )
            case .leftMouseDragged:
                handler.receiveTapMouseDragged(at: screenLocation, windowUnderPointer: windowUnderPointer)
            case .leftMouseUp:
                handler.receiveTapMouseUp(at: screenLocation, windowUnderPointer: windowUnderPointer)
            case .rightMouseDown:
                suppressEvent = handler.receiveTapMouseDown(
                    at: screenLocation,
                    modifiers: modifiers,
                    button: .right,
                    windowUnderPointer: windowUnderPointer
                )
            case .rightMouseDragged:
                suppressEvent = handler.shouldSuppressRightMouseEvent(type: type)
                handler.receiveTapMouseDragged(
                    at: screenLocation,
                    button: .right,
                    windowUnderPointer: windowUnderPointer
                )
            case .rightMouseUp:
                suppressEvent = handler.shouldSuppressRightMouseEvent(type: type)
                handler.receiveTapMouseUp(
                    at: screenLocation,
                    button: .right,
                    windowUnderPointer: windowUnderPointer
                )
            case .scrollWheel:
                guard let scrollPayload else { return }
                handler.receiveTapScrollWheel(
                    at: screenLocation,
                    deltaX: scrollPayload.deltaX,
                    deltaY: scrollPayload.deltaY,
                    momentumPhase: scrollPayload.momentumPhase,
                    phase: scrollPayload.phase,
                    modifiers: modifiers
                )
            default:
                break
            }
        }

        return suppressEvent
    }

    private nonisolated static func windowUnderPointer(from event: CGEvent) -> Int? {
        let directWindow = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        let eventHandlingWindow = Int(
            event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        )
        return windowUnderPointer(direct: directWindow, canHandle: eventHandlingWindow)
    }

    /// Diagnostic-only: records the raw `CGEvent` window-under-pointer fields for a
    /// mouse-moved event so a runtime trace can show whether the WindowServer
    /// populated them (and with what value) for events that originate over an
    /// overlay. This is the ground truth behind `windowUnderPointer(from:)` and is
    /// needed to distinguish "fields genuinely empty" from "value lost in the
    /// queue" for cases like the JankyBorders overlay (#64). No-op unless runtime
    /// trace capture is active.
    @MainActor
    private func traceTapMouseMovedRawFields(
        direct: Int,
        canHandle: Int,
        resolved: Int?,
        location: CGPoint
    ) {
        guard controller?.isRuntimeTraceCaptureActive == true else { return }
        traceMouseFocus(
            "tap.mouseMoved direct=\(direct) canHandle=\(canHandle) resolved=\(resolved.map(String.init) ?? "nil") loc=\(formatPoint(location))"
        )
    }

    /// Reconciles the geometrically-topmost window under the pointer (`direct`)
    /// with the window that can actually handle the event (`canHandle`).
    ///
    /// When the two diverge (`direct != canHandle`, both positive) the topmost
    /// window is click-through — e.g. a decorative overlay from the standalone
    /// "Borders" app that does not receive mouse events. Prefer the
    /// event-handling window so a click-through overlay does not suppress
    /// focus-follows-mouse (#64). When both agree (an interactive overlay such
    /// as the Ghostty Quick terminal) the overlay is still reported and correctly
    /// suppresses FFM, so the completed overlay fix is preserved.
    ///
    /// `canHandle` is preferred whenever it is positive; `direct` is only used as
    /// a fallback for owners/event types that populate only the geometric field.
    nonisolated static func windowUnderPointer(direct: Int, canHandle: Int) -> Int? {
        if direct > 0, canHandle > 0, direct != canHandle {
            return canHandle
        }
        return canHandle > 0 ? canHandle : (direct > 0 ? direct : nil)
    }

    nonisolated static func resolvedWheelAxisDelta(pointDelta: CGFloat, fixedPointDelta: CGFloat) -> CGFloat {
        if abs(pointDelta) > mouseWheelAxisEpsilon {
            return pointDelta
        }
        return fixedPointDelta
    }

    nonisolated static func mouseWheelModifiersMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifierFlagsMatch(modifiers, required: required)
    }

    nonisolated static func modifierFlagsMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifiers.intersection(mouseRelevantModifierFlags) == required
    }

    nonisolated static func cgEventFlags(from modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    nonisolated static func resolvedMouseWheelColumnDeltaValue(
        deltaX: CGFloat,
        deltaY: CGFloat,
        allowVerticalFallback: Bool
    ) -> CGFloat? {
        resolvedMouseWheelColumnDelta(
            deltaX: deltaX,
            deltaY: deltaY,
            allowVerticalFallback: allowVerticalFallback
        )?.value
    }

    private nonisolated static func resolvedMouseWheelColumnDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        allowVerticalFallback: Bool
    ) -> MouseWheelColumnDelta? {
        if abs(deltaX) > mouseWheelAxisEpsilon {
            return MouseWheelColumnDelta(axis: .horizontal, value: deltaX)
        }
        guard allowVerticalFallback else {
            return nil
        }
        guard abs(deltaY) > mouseWheelAxisEpsilon else {
            return nil
        }
        return MouseWheelColumnDelta(axis: .vertical, value: deltaY)
    }

    private nonisolated static func processGestureTapCallback(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard type.rawValue == NSEvent.EventType.gesture.rawValue else { return false }
        guard isMainThread else { return false }
        guard let snapshot = makeGestureEventSnapshot(from: event) else { return true }

        MainActor.assumeIsolated {
            MouseEventHandler._instance?.receiveTapGestureEvent(snapshot)
        }

        return true
    }

    static func averageGestureTouchPosition(
        requiredFingers: Int,
        touches: [GestureTouchSample]
    ) -> CGPoint? {
        guard requiredFingers > 0 else { return nil }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var touchCount = 0
        var activeCount = 0

        for touch in touches {
            if touch.phase == .ended || touch.phase == .cancelled {
                continue
            }

            touchCount += 1
            if touchCount > requiredFingers {
                return nil
            }

            guard let normalizedPosition = touch.normalizedPosition else {
                return nil
            }

            sumX += normalizedPosition.x
            sumY += normalizedPosition.y
            activeCount += 1
        }

        guard touchCount == requiredFingers, activeCount > 0 else { return nil }

        return CGPoint(
            x: sumX / CGFloat(activeCount),
            y: sumY / CGFloat(activeCount)
        )
    }

    private nonisolated static func sanitizedGestureTouchPosition(_ position: CGPoint) -> CGPoint? {
        guard position.x.isFinite, position.y.isFinite else { return nil }
        return position
    }

    private nonisolated static func makeGestureEventSnapshot(from cgEvent: CGEvent) -> GestureEventSnapshot? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
        return GestureEventSnapshot(
            location: ScreenCoordinateSpace.toAppKit(point: cgEvent.location),
            phaseRawValue: nsEvent.phase.rawValue,
            timestamp: nsEvent.timestamp,
            modifiers: cgEvent.flags,
            windowUnderPointer: windowUnderPointer(from: cgEvent)
                ?? (nsEvent.windowNumber > 0 ? nsEvent.windowNumber : nil),
            touches: nsEvent.allTouches().map { touch in
                GestureTouchSample(
                    phase: touch.phase,
                    normalizedPosition: sanitizedGestureTouchPosition(touch.normalizedPosition)
                )
            }
        )
    }
}
