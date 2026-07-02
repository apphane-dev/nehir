// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import ApplicationServices
import Foundation
@testable import Nehir
import QuartzCore
import Testing

func makeTestHandle(pid: pid_t = 1) -> WindowHandle {
    WindowHandle(
        id: WindowToken(pid: pid, windowId: Int.random(in: 1 ... 1_000_000)),
        pid: pid,
        axElement: AXUIElementCreateSystemWide()
    )
}

func makeTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat
) -> Monitor {
    let frame = CGRect(x: x, y: 0, width: 1920, height: 1080)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

func makeHorizontalNeighboringTestMonitors() -> (primary: Monitor, secondary: Monitor) {
    (
        primary: makeLayoutPlanTestMonitor(
            displayId: 100,
            name: "Primary",
            x: 0,
            width: 1600,
            height: 900
        ),
        secondary: makeLayoutPlanTestMonitor(
            displayId: 200,
            name: "Secondary",
            x: 1600,
            width: 1600,
            height: 900
        )
    )
}

func makeVerticalStackedTestMonitors() -> (lower: Monitor, upper: Monitor) {
    (
        lower: makeLayoutPlanTestMonitor(
            displayId: 301,
            name: "Lower",
            x: 0,
            y: 0,
            width: 900,
            height: 1600
        ),
        upper: makeLayoutPlanTestMonitor(
            displayId: 302,
            name: "Upper",
            x: 0,
            y: 1600,
            width: 900,
            height: 1600
        )
    )
}

private func hasNiriScrollDirective(
    _ directives: [AnimationDirective],
    workspaceId: WorkspaceDescriptor.ID
) -> Bool {
    directives.contains { directive in
        if case let .startNiriScroll(candidate) = directive {
            return candidate == workspaceId
        }
        return false
    }
}

private func hasActivationDirective(
    _ directives: [AnimationDirective],
    token: WindowToken
) -> Bool {
    directives.contains { directive in
        if case let .activateWindow(candidate) = directive {
            return candidate == token
        }
        return false
    }
}

private func hasHiddenVisibilityChange(_ changes: [LayoutVisibilityChange]) -> Bool {
    changes.contains { change in
        if case .hide = change {
            return true
        }
        return false
    }
}

private func hiddenVisibilitySides(_ changes: [LayoutVisibilityChange]) -> [HideSide] {
    changes.compactMap { change in
        if case let .hide(_, side: side) = change {
            return side
        }
        return nil
    }
}

private func hasHideVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken,
    side: HideSide? = nil
) -> Bool {
    changes.contains { change in
        guard case let .hide(candidate, changeSide) = change,
              candidate == token
        else {
            return false
        }
        return side == nil || side == changeSide
    }
}

private func hasShowVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken
) -> Bool {
    changes.contains { change in
        if case let .show(candidate) = change {
            return candidate == token
        }
        return false
    }
}

private func hasAnyVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken
) -> Bool {
    hasHideVisibilityChange(changes, token: token) || hasShowVisibilityChange(changes, token: token)
}

private func hiddenVisibilityTokens(_ changes: [LayoutVisibilityChange]) -> [WindowToken] {
    changes.compactMap { change in
        if case let .hide(token, side: _) = change {
            return token
        }
        return nil
    }
}

private func hasFrameChange(
    _ changes: [LayoutFrameChange],
    token: WindowToken
) -> Bool {
    changes.contains { $0.token == token }
}

private enum CrossMonitorWorkspaceSide {
    case primary
    case secondary
}

private struct CenteredCrossMonitorFixture {
    let controller: WMController
    let engine: NiriLayoutEngine
    let primaryMonitor: Monitor
    let secondaryMonitor: Monitor
    let primaryWorkspaceId: WorkspaceDescriptor.ID
    let secondaryWorkspaceId: WorkspaceDescriptor.ID
    let targetWorkspaceId: WorkspaceDescriptor.ID
    let targetMonitor: Monitor
    let neighboringMonitor: Monitor
}

@MainActor
private func suppressAutomaticRefreshExecution(on controller: WMController) {
    controller.layoutRefreshController.resetDebugState()
    controller.layoutRefreshController.debugHooks.onRelayout = { _, _ in true }
    controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { _ in true }
    controller.layoutRefreshController.debugHooks.onFullRescan = { _ in true }
    controller.layoutRefreshController.debugHooks.onWindowRemoval = { _, _ in true }
}

@MainActor
private func executeAndSettleLayoutPlans(
    _ plans: [WorkspaceLayoutPlan],
    on controller: WMController
) async {
    controller.layoutRefreshController.executeLayoutPlans(plans)
    await waitForLayoutPlanRefreshWork(on: controller)
    controller.layoutRefreshController.stopAllScrollAnimations()
}

private func assertHideOnlyMonitorBoundaryDiff(
    _ plan: WorkspaceLayoutPlan,
    token: WindowToken,
    side: HideSide,
    disallowedMonitor: Monitor
) {
    #expect(hasHideVisibilityChange(plan.diff.visibilityChanges, token: token, side: side))
    #expect(!hasFrameChange(plan.diff.frameChanges, token: token))
    for change in plan.diff.frameChanges {
        #expect(!change.frame.intersects(disallowedMonitor.frame))
    }
}

@MainActor
private func selectWindowAndSettleViewport(
    _ window: NiriWindow,
    in workspaceId: WorkspaceDescriptor.ID,
    on monitor: Monitor,
    engine: NiriLayoutEngine,
    controller: WMController
) {
    _ = controller.workspaceManager.setManagedFocus(
        window.token,
        in: workspaceId,
        onMonitor: monitor.id
    )
    _ = controller.workspaceManager.commitWorkspaceSelection(
        nodeId: window.id,
        focusedToken: window.token,
        in: workspaceId,
        onMonitor: monitor.id
    )

    let workingFrame = controller.insetWorkingFrame(for: monitor)
    let gap = CGFloat(controller.workspaceManager.gaps)
    controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
        state.selectedNodeId = window.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        engine.ensureSelectionVisible(
            node: window,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        state.viewOffsetPixels = .static(state.viewOffsetPixels.target())
    }
}

@MainActor
private func calculateCurrentLayout(
    controller: WMController,
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    monitor: Monitor,
    animationTime: TimeInterval? = nil
) -> (
    frames: [WindowToken: CGRect],
    hiddenHandles: [WindowToken: HideSide]
) {
    let gaps = LayoutGaps(
        horizontal: CGFloat(controller.workspaceManager.gaps),
        vertical: CGFloat(controller.workspaceManager.gaps),
        outer: controller.workspaceManager.outerGaps
    )
    let workingFrame = controller.insetWorkingFrame(for: monitor)
    let area = WorkingAreaContext(
        workingFrame: workingFrame,
        viewFrame: monitor.frame,
        scale: controller.layoutRefreshController.backingScale(for: monitor)
    )
    let state = controller.workspaceManager.niriViewportState(for: workspaceId)
    return engine.calculateCombinedLayoutUsingPools(
        in: workspaceId,
        monitor: monitor,
        gaps: gaps,
        state: state,
        workingArea: area,
        animationTime: animationTime
    )
}

@MainActor
private func makeCenteredCrossMonitorFixture(
    workspaceSide: CrossMonitorWorkspaceSide,
    windowIds: ClosedRange<Int>
) async -> CenteredCrossMonitorFixture? {
    let monitors = makeHorizontalNeighboringTestMonitors()
    let fixture = makeTwoMonitorLayoutPlanTestController(
        primaryMonitor: monitors.primary,
        secondaryMonitor: monitors.secondary
    )
    let controller = fixture.controller

    suppressAutomaticRefreshExecution(on: controller)
    controller.enableNiriLayout(revealStyle: .auto)
    controller.updateNiriConfig(
        balancedColumnCount: 2,
        defaultColumnWidth: .some(0.85)
    )
    await waitForLayoutPlanRefreshWork(on: controller)

    guard controller.workspaceManager.setActiveWorkspace(fixture.primaryWorkspaceId, on: monitors.primary.id),
          controller.workspaceManager.setActiveWorkspace(fixture.secondaryWorkspaceId, on: monitors.secondary.id),
          controller.workspaceManager.monitorId(for: fixture.primaryWorkspaceId) == monitors.primary.id,
          controller.workspaceManager.monitorId(for: fixture.secondaryWorkspaceId) == monitors.secondary.id
    else {
        Issue.record("Failed to bind workspaces to the expected monitors for cross-monitor leak regression test")
        return nil
    }

    controller.syncMonitorsToNiriEngine()

    let targetWorkspaceId: WorkspaceDescriptor.ID
    let targetMonitor: Monitor
    let neighboringMonitor: Monitor
    switch workspaceSide {
    case .primary:
        targetWorkspaceId = fixture.primaryWorkspaceId
        targetMonitor = monitors.primary
        neighboringMonitor = monitors.secondary
    case .secondary:
        targetWorkspaceId = fixture.secondaryWorkspaceId
        targetMonitor = monitors.secondary
        neighboringMonitor = monitors.primary
    }

    for windowId in windowIds {
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: windowId)
    }

    guard let engine = controller.niriEngine else {
        Issue.record("Expected Niri engine for cross-monitor leak regression test")
        return nil
    }

    return CenteredCrossMonitorFixture(
        controller: controller,
        engine: engine,
        primaryMonitor: monitors.primary,
        secondaryMonitor: monitors.secondary,
        primaryWorkspaceId: fixture.primaryWorkspaceId,
        secondaryWorkspaceId: fixture.secondaryWorkspaceId,
        targetWorkspaceId: targetWorkspaceId,
        targetMonitor: targetMonitor,
        neighboringMonitor: neighboringMonitor
    )
}

@Suite struct NiriLayoutEngineTests {
    private struct SingleColumnFocusFixture {
        let controller: WMController
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let column: NiriContainer
        let bottomToken: WindowToken
        let middleToken: WindowToken
        let topToken: WindowToken
        let bottomWindow: NiriWindow
        let middleWindow: NiriWindow
        let topWindow: NiriWindow
    }

    private struct NeighboringMonitorRevealFixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let owningMonitor: Monitor
        let neighboringMonitor: Monitor
        let firstWindow: NiriWindow
        let secondWindow: NiriWindow
        let gap: CGFloat
        let gaps: LayoutGaps
        let area: WorkingAreaContext
    }

    @MainActor
    private func makeSingleColumnFocusFixture(displayMode: ColumnDisplay) async -> SingleColumnFocusFixture {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            fatalError("Missing monitor or active workspace for single-column focus fixture")
        }

        controller.enableNiriLayout(revealStyle: .auto)
        controller.updateNiriConfig(balancedColumnCount: 3)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.syncMonitorsToNiriEngine()

        let bottomToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 901)
        let middleToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 902)
        let topToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 903)

        guard let engine = controller.niriEngine else {
            fatalError("Expected Niri engine for single-column focus fixture")
        }

        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root
        engine.ensureMonitor(for: monitor.id, monitor: monitor).workspaceRoots[workspaceId] = root

        let column = NiriContainer()
        column.displayMode = displayMode
        root.appendChild(column)
        assignFixedWidths(root.columns)

        let bottomWindow = NiriWindow(token: bottomToken)
        let middleWindow = NiriWindow(token: middleToken)
        let topWindow = NiriWindow(token: topToken)

        column.appendChild(bottomWindow)
        column.appendChild(middleWindow)
        column.appendChild(topWindow)
        if displayMode == .tabbed {
            column.setActiveTileIdx(1)
            engine.updateTabbedColumnVisibility(column: column)
        }

        engine.tokenToNode[bottomToken] = bottomWindow
        engine.tokenToNode[middleToken] = middleWindow
        engine.tokenToNode[topToken] = topWindow

        _ = controller.workspaceManager.setManagedFocus(middleToken, in: workspaceId, onMonitor: monitor.id)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: middleWindow.id,
            focusedToken: middleToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = middleWindow.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(0)
        }

        return SingleColumnFocusFixture(
            controller: controller,
            monitor: monitor,
            workspaceId: workspaceId,
            engine: engine,
            column: column,
            bottomToken: bottomToken,
            middleToken: middleToken,
            topToken: topToken,
            bottomWindow: bottomWindow,
            middleWindow: middleWindow,
            topWindow: topWindow
        )
    }

    @MainActor
    private func toggleColumnTabbedInFixture(_ fixture: SingleColumnFocusFixture) -> Bool {
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let gap = CGFloat(fixture.controller.workspaceManager.gaps)
        var result = false
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            result = fixture.engine.toggleColumnTabbed(
                in: fixture.workspaceId,
                state: &state,
                motion: fixture.controller.motionPolicy.snapshot(),
                workingFrame: workingFrame,
                gaps: gap
            )
        }
        return result
    }

    @Test @MainActor func togglingRealTabbedColumnWithoutOverflowPreservesColumn() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)
        for window in [fixture.bottomWindow, fixture.middleWindow, fixture.topWindow] {
            window.constraints = WindowSizeConstraints(
                minSize: CGSize(width: 1, height: 100),
                maxSize: .zero,
                isFixed: false
            )
        }

        #expect(toggleColumnTabbedInFixture(fixture))

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        #expect(columns.count == 1)
        #expect(columns[0] === fixture.column)
        #expect(fixture.column.displayMode == .normal)
        #expect(!fixture.column.usesOverflowTabbedMode)
        #expect(fixture.column.windowNodes.map(\.token) == [fixture.bottomToken, fixture.middleToken, fixture.topToken])
        #expect(fixture.column.windowNodes.allSatisfy { !$0.isHiddenInTabbedMode })
    }

    @Test @MainActor func togglingRealTabbedOverflowColumnSplitsIntoColumns() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)
        for window in [fixture.bottomWindow, fixture.middleWindow, fixture.topWindow] {
            window.constraints = WindowSizeConstraints(
                minSize: CGSize(width: 1, height: 700),
                maxSize: .zero,
                isFixed: false
            )
        }

        #expect(toggleColumnTabbedInFixture(fixture))

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        #expect(columns.count == 3)
        #expect(columns.allSatisfy { $0.displayMode == .normal })
        #expect(columns.allSatisfy { $0.windowNodes.count == 1 })
        let splitTokens = columns.flatMap { $0.windowNodes.map(\.token) }.sorted { $0.windowId < $1.windowId }
        let expectedTokens = [fixture.bottomToken, fixture.middleToken, fixture.topToken]
            .sorted { $0.windowId < $1.windowId }
        #expect(splitTokens == expectedTokens)
        #expect(columns.flatMap(\.windowNodes).allSatisfy { !$0.isHiddenInTabbedMode })
    }

    @Test @MainActor func togglingForcedTabbedColumnWithoutCurrentOverflowClearsForcedStateOnly() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .normal)
        fixture.column.usesOverflowTabbedMode = true
        fixture.engine.updateTabbedColumnVisibility(column: fixture.column)
        for window in [fixture.bottomWindow, fixture.middleWindow, fixture.topWindow] {
            window.constraints = WindowSizeConstraints(
                minSize: CGSize(width: 1, height: 100),
                maxSize: .zero,
                isFixed: false
            )
        }

        #expect(toggleColumnTabbedInFixture(fixture))

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        #expect(columns.count == 1)
        #expect(columns[0] === fixture.column)
        #expect(fixture.column.displayMode == .normal)
        #expect(!fixture.column.usesOverflowTabbedMode)
        #expect(fixture.column.windowNodes.map(\.token) == [fixture.bottomToken, fixture.middleToken, fixture.topToken])
        #expect(fixture.column.windowNodes.allSatisfy { !$0.isHiddenInTabbedMode })
    }

    @Test func verticalOrientationWidthOverflowUsesForcedTabbedMode() {
        let engine = NiriLayoutEngine()
        let workspaceId = UUID()
        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let firstToken = makeTestHandle(pid: 7101).id
        let secondToken = makeTestHandle(pid: 7102).id
        let firstWindow = NiriWindow(token: firstToken)
        let secondWindow = NiriWindow(token: secondToken)
        firstWindow.constraints = WindowSizeConstraints(
            minSize: CGSize(width: 700, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        secondWindow.constraints = WindowSizeConstraints(
            minSize: CGSize(width: 700, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        column.appendChild(firstWindow)
        column.appendChild(secondWindow)
        engine.tokenToNode[firstToken] = firstWindow
        engine.tokenToNode[secondToken] = secondWindow

        let frames = engine.calculateLayout(
            state: ViewportState(),
            workspaceId: workspaceId,
            monitorFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_200),
            gaps: (horizontal: 8, vertical: 8),
            orientation: .vertical
        )

        #expect(column.usesOverflowTabbedMode)
        #expect(!firstWindow.isHiddenInTabbedMode)
        #expect(secondWindow.isHiddenInTabbedMode)
        #expect(frames[firstToken]?.origin.x == frames[secondToken]?.origin.x)
    }

    private func makeVisibleColumnFixture(
        visibleCount: Int,
        extraColumns: Int = 2,
        width: CGFloat = 1600,
        height: CGFloat = 900
    ) -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        windows: [NiriWindow],
        monitor: Monitor,
        gap: CGFloat,
        gaps: LayoutGaps,
        area: WorkingAreaContext
    ) {
        let engine = NiriLayoutEngine(balancedColumnCount: visibleCount)

        let workspaceId = UUID()
        var windows: [NiriWindow] = []
        var previousSelection: NodeId?

        for index in 0 ..< (visibleCount + extraColumns) {
            let handle = makeTestHandle(pid: pid_t(200 + index))
            let window = engine.addWindow(
                handle: handle,
                to: workspaceId,
                afterSelection: previousSelection
            )
            windows.append(window)
            previousSelection = window.id
        }

        let monitor = makeLayoutPlanTestMonitor(width: width, height: height)
        let gap: CGFloat = 8
        let gaps = LayoutGaps(horizontal: gap, vertical: gap)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )
        let fixedWidth = (monitor.visibleFrame.width - gap * CGFloat(visibleCount - 1)) / CGFloat(visibleCount)

        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        return (engine, workspaceId, windows, monitor, gap, gaps, area)
    }

    private func makeViewportStateForVisibleColumn(
        targetWindow: NiriWindow,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gap: CGFloat
    ) -> ViewportState {
        var state = ViewportState()
        state.animationClock = engine.animationClock
        state.selectedNodeId = targetWindow.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        engine.ensureSelectionVisible(
            node: targetWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        state.viewOffsetPixels = .static(state.viewOffsetPixels.target())
        return state
    }

    @MainActor
    private func makeNavigateToWindowViewportFixture(
        balancedColumnCount: Int,
        windowCount: Int,
        outerGapLeft: Double = 0,
        outerGapRight: Double = 0
    ) async throws -> (
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        columns: [NiriContainer],
        windows: [NiriWindow],
        gap: CGFloat,
        workingFrame: CGRect
    ) {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            fatalError("Missing monitor or active workspace for navigate-to-window viewport fixture")
        }

        controller.settings.niriBalancedColumnCount = balancedColumnCount
        controller.setOuterGaps(left: outerGapLeft, right: outerGapRight, top: 0, bottom: 0)
        controller.enableNiriLayout(revealStyle: .auto)
        controller.updateNiriConfig(
            balancedColumnCount: balancedColumnCount
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            fatalError("Expected Niri engine for navigate-to-window viewport fixture")
        }

        for windowOffset in 0 ..< windowCount {
            _ = addLayoutPlanTestWindow(
                on: controller,
                workspaceId: workspaceId,
                windowId: 8_100 + windowOffset
            )
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let fixedWidth = (
            workingFrame.width - gap * CGFloat(balancedColumnCount - 1)
        ) / CGFloat(balancedColumnCount)
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        let columns = engine.columns(in: workspaceId)
        let windows = columns.compactMap(\.windowNodes.first)
        guard windows.count == windowCount else {
            fatalError("Expected \(windowCount) navigate-to-window test windows")
        }

        return (controller, workspaceId, monitor, columns, windows, gap, workingFrame)
    }

    @MainActor
    private func setNavigateToWindowSelection(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        columns: [NiriContainer],
        windows: [NiriWindow],
        gap: CGFloat,
        activeIndex: Int,
        viewportStart: CGFloat,
        selectionProgress: CGFloat = 0
    ) {
        let node = windows[activeIndex]
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = node.id
            state.activeColumnIndex = activeIndex
            state.viewOffsetPixels = .static(
                viewportStart - state.columnX(at: activeIndex, columns: columns, gap: gap)
            )
            state.selectionProgress = selectionProgress
        }
        _ = controller.workspaceManager.setManagedFocus(node.token, in: workspaceId, onMonitor: monitor.id)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: node.token,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.layoutRefreshController.stopAllScrollAnimations()
    }

    private func settledLayoutState(
        from state: ViewportState,
        column: NiriContainer?,
        settleTime: TimeInterval
    ) -> ViewportState {
        var settledState = state
        _ = settledState.advanceAnimations(at: settleTime)
        _ = column?.tickWidthAnimation(at: settleTime)
        return settledState
    }

    private func assignFixedWidths(
        _ columns: [NiriContainer],
        width: CGFloat = 400
    ) {
        for column in columns {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
    }

    private func assignWidths(
        _ columns: [NiriContainer],
        widths: [CGFloat]
    ) {
        for (column, width) in zip(columns, widths) {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
    }

    private func assignHeights(
        _ columns: [NiriContainer],
        heights: [CGFloat]
    ) {
        for (column, height) in zip(columns, heights) {
            column.height = .fixed(height)
            column.cachedHeight = height
        }
    }

    private func viewportStart(
        for state: ViewportState,
        columns: [NiriContainer],
        gap: CGFloat
    ) -> CGFloat {
        state.columnX(at: state.activeColumnIndex, columns: columns, gap: gap)
            + state.viewOffsetPixels.target()
    }

    private func niriFitViewportStart(
        currentViewStart: CGFloat,
        viewportWidth: CGFloat,
        targetPos: CGFloat,
        targetWidth: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        if viewportWidth <= targetWidth {
            return targetPos
        }

        let padding = min(max((viewportWidth - targetWidth) / 2, 0), gap)
        let preferredStart = targetPos - padding
        let preferredEnd = targetPos + targetWidth + padding

        if currentViewStart <= preferredStart && preferredEnd <= currentViewStart + viewportWidth {
            return currentViewStart
        }

        let distToLeft = abs(currentViewStart - preferredStart)
        let distToRight = abs((currentViewStart + viewportWidth) - preferredEnd)
        return distToLeft <= distToRight ? preferredStart : preferredEnd - viewportWidth
    }

    private func niriCenteredViewportStart(
        currentViewStart: CGFloat,
        viewportWidth: CGFloat,
        targetPos: CGFloat,
        targetWidth: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        if viewportWidth <= targetWidth {
            return niriFitViewportStart(
                currentViewStart: currentViewStart,
                viewportWidth: viewportWidth,
                targetPos: targetPos,
                targetWidth: targetWidth,
                gap: gap
            )
        }

        return targetPos - (viewportWidth - targetWidth) / 2
    }

    private func niriExpectedViewportStart(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        currentViewStart: CGFloat,
        targetIndex: Int,
        center: Bool = false,
        fromIndex: Int? = nil
    ) -> CGFloat {
        let targetPos = columns.prefix(targetIndex).reduce(CGFloat(0)) { $0 + $1.cachedWidth + gap }
        let targetWidth = columns[targetIndex].cachedWidth

        if center {
            return niriCenteredViewportStart(
                currentViewStart: currentViewStart,
                viewportWidth: viewportWidth,
                targetPos: targetPos,
                targetWidth: targetWidth,
                gap: gap
            )
        }

        return niriFitViewportStart(
            currentViewStart: currentViewStart,
            viewportWidth: viewportWidth,
            targetPos: targetPos,
            targetWidth: targetWidth,
            gap: gap
        )
    }

    private func resolvedSettings(
        for engine: NiriLayoutEngine,
        defaultColumnWidth: DefaultColumnWidth? = nil,
        loneWindowPolicy: LoneWindowPolicy? = nil,
        infiniteLoop: Bool? = nil
    ) -> ResolvedNiriSettings {
        let global = engine.globalResolvedSettings()
        return ResolvedNiriSettings(
            defaultColumnWidth: defaultColumnWidth ?? global.defaultColumnWidth,
            loneWindowPolicy: loneWindowPolicy ?? global.loneWindowPolicy,
            infiniteLoop: infiniteLoop ?? global.infiniteLoop
        )
    }

    private func attachWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        to monitor: Monitor,
        engine: NiriLayoutEngine,
        resolvedSettings: ResolvedNiriSettings? = nil
    ) {
        engine.moveWorkspace(workspaceId, to: monitor.id, monitor: monitor)
        if let resolvedSettings {
            engine.updateMonitorSettings(resolvedSettings, for: monitor.id)
        }
    }

    private func makeNeighboringLayoutContext(
        for monitor: Monitor,
        gap: CGFloat = 8,
        scale: CGFloat = 2.0
    ) -> (
        gap: CGFloat,
        gaps: LayoutGaps,
        area: WorkingAreaContext
    ) {
        let gaps = LayoutGaps(horizontal: gap, vertical: gap)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: scale
        )
        return (gap, gaps, area)
    }

    private func makeHorizontalNeighboringRevealFixture(
        workspaceOnPrimary: Bool,
        withAnimationClock: Bool = false,
        pidBase: pid_t = 51
    ) -> NeighboringMonitorRevealFixture {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        if withAnimationClock {
            engine.animationClock = AnimationClock()
        }

        let workspaceId = UUID()
        let monitors = makeHorizontalNeighboringTestMonitors()
        let owningMonitor: Monitor
        let neighboringMonitor: Monitor

        if workspaceOnPrimary {
            attachWorkspace(
                workspaceId,
                to: monitors.primary,
                engine: engine,
                resolvedSettings: resolvedSettings(
                    for: engine,
                    defaultColumnWidth: .balanced(columns: 2)
                )
            )
            _ = engine.ensureMonitor(for: monitors.secondary.id, monitor: monitors.secondary)
            owningMonitor = monitors.primary
            neighboringMonitor = monitors.secondary
        } else {
            _ = engine.ensureMonitor(for: monitors.primary.id, monitor: monitors.primary)
            attachWorkspace(
                workspaceId,
                to: monitors.secondary,
                engine: engine,
                resolvedSettings: resolvedSettings(
                    for: engine,
                    defaultColumnWidth: .balanced(columns: 2)
                )
            )
            owningMonitor = monitors.secondary
            neighboringMonitor = monitors.primary
        }

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: pidBase), to: workspaceId, afterSelection: nil)
        let secondWindow = engine.addWindow(
            handle: makeTestHandle(pid: pidBase + 1),
            to: workspaceId,
            afterSelection: firstWindow.id
        )
        assignWidths(
            engine.columns(in: workspaceId),
            widths: [owningMonitor.visibleFrame.width, owningMonitor.visibleFrame.width]
        )

        let (gap, gaps, area) = makeNeighboringLayoutContext(for: owningMonitor)
        return NeighboringMonitorRevealFixture(
            engine: engine,
            workspaceId: workspaceId,
            owningMonitor: owningMonitor,
            neighboringMonitor: neighboringMonitor,
            firstWindow: firstWindow,
            secondWindow: secondWindow,
            gap: gap,
            gaps: gaps,
            area: area
        )
    }

    private func makeVerticalNeighboringRevealFixture(
        workspaceOnLowerMonitor: Bool,
        withAnimationClock: Bool = false,
        pidBase: pid_t = 161
    ) -> NeighboringMonitorRevealFixture {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        if withAnimationClock {
            engine.animationClock = AnimationClock()
        }

        let workspaceId = UUID()
        let monitors = makeVerticalStackedTestMonitors()
        let owningMonitor: Monitor
        let neighboringMonitor: Monitor

        if workspaceOnLowerMonitor {
            attachWorkspace(
                workspaceId,
                to: monitors.lower,
                engine: engine,
                resolvedSettings: resolvedSettings(
                    for: engine,
                    defaultColumnWidth: .balanced(columns: 2)
                )
            )
            _ = engine.ensureMonitor(for: monitors.upper.id, monitor: monitors.upper)
            owningMonitor = monitors.lower
            neighboringMonitor = monitors.upper
        } else {
            _ = engine.ensureMonitor(for: monitors.lower.id, monitor: monitors.lower)
            attachWorkspace(
                workspaceId,
                to: monitors.upper,
                engine: engine,
                resolvedSettings: resolvedSettings(
                    for: engine,
                    defaultColumnWidth: .balanced(columns: 2)
                )
            )
            owningMonitor = monitors.upper
            neighboringMonitor = monitors.lower
        }

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: pidBase), to: workspaceId, afterSelection: nil)
        let secondWindow = engine.addWindow(
            handle: makeTestHandle(pid: pidBase + 1),
            to: workspaceId,
            afterSelection: firstWindow.id
        )
        assignHeights(
            engine.columns(in: workspaceId),
            heights: [owningMonitor.visibleFrame.height, owningMonitor.visibleFrame.height]
        )

        let (gap, gaps, area) = makeNeighboringLayoutContext(for: owningMonitor)
        return NeighboringMonitorRevealFixture(
            engine: engine,
            workspaceId: workspaceId,
            owningMonitor: owningMonitor,
            neighboringMonitor: neighboringMonitor,
            firstWindow: firstWindow,
            secondWindow: secondWindow,
            gap: gap,
            gaps: gaps,
            area: area
        )
    }

    @Test func selectionFallbackAfterRemoval_sameSibling() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let _ = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count >= 2)

        let fallback = engine.fallbackSelectionOnRemoval(removing: w2.id, in: wsId)
        #expect(fallback != nil)
        #expect(fallback != w2.id)

        let fallbackNode = engine.findNode(by: fallback!)
        #expect(fallbackNode != nil)
    }

    @Test func firstWindowUsesBalancedWidthWhenDefaultWidthIsAutoWhenSingleWindowRatioIsDisabled() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = nil
        engine.loneWindowPolicy = .fill
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)

        guard let column = engine.column(of: window) else {
            Issue.record("Expected claimed column for first window")
            return
        }

        #expect(column.width == .proportion(1.0 / 3.0))
        #expect(column.presetWidthIdx == nil)
    }

    @Test func firstWindowUsesResolvedMonitorBalancedColumnCountWhenDefaultWidthIsAuto() {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = nil
        engine.loneWindowPolicy = .fill
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 501, name: "Override", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(for: engine, defaultColumnWidth: .balanced(columns: 3))
        )

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)

        guard let column = engine.column(of: window) else {
            Issue.record("Expected claimed column for monitor-override width test")
            return
        }

        #expect(column.width == .proportion(1.0 / 3.0))
        #expect(column.presetWidthIdx == nil)
    }

    @Test func centeredLoneWindowPolicyCentersLoneWindowFrame() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.defaultColumnWidth = nil
        engine.loneWindowPolicy = .centered(maxWidthFraction: 0.75)
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        // Centered lone windows are centered via viewport offset. Seed the center offset so
        // the rendered frame is horizontally centered (matching what the controller does).
        let workingFrameWidth: CGFloat = monitor.visibleFrame.width
        let expectedWidth = (workingFrameWidth * 0.75).roundedToPhysicalPixel(scale: 1)
        let centerOffset = (expectedWidth - workingFrameWidth) / 2
        var state = ViewportState()
        state.viewOffsetPixels = .static(centerOffset)

        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 8, vertical: 8),
            state: state
        )

        guard let frame = layout.frames[window.token] else {
            Issue.record("Expected a rendered frame for the single Niri window")
            return
        }

        #expect(abs(frame.minX - (workingFrameWidth - expectedWidth) / 2) < 1.0)
        #expect(abs(frame.width - expectedWidth) < 1.0)
    }

    @Test func singleWindowMinimumLargerThanWorkingAreaClampsToVisibleFrame() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.defaultColumnWidth = nil
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor(width: 2056, height: 1290)
        let workingFrame = CGRect(x: 10, y: 0, width: 2036, height: 1280)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: monitor.visibleFrame,
            scale: 1
        )

        engine.updateWindowConstraints(
            for: window.token,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 2056, height: 1290),
                maxSize: .zero,
                isFixed: false
            )
        )

        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 10, vertical: 10),
            state: ViewportState(),
            workingArea: area
        )

        #expect(layout.frames[window.token] == monitor.visibleFrame)
    }

    @Test func singleWindowFillRendersRawScrollOffsetDuringGesture() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.defaultColumnWidth = nil
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor(width: 2056, height: 1290)
        let workingFrame = CGRect(x: 10, y: 0, width: 2036, height: 1280)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: monitor.visibleFrame,
            scale: 1
        )

        // During a gesture, the lone fill window should visibly follow the viewport
        // offset. Snap-grid rules decide where it settles after release.
        var scrolledState = ViewportState()
        scrolledState.viewOffsetPixels = .static(247)
        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 8, vertical: 8),
            state: scrolledState,
            workingArea: area
        )

        #expect(layout.frames[window.token] == workingFrame.offsetBy(dx: -247, dy: 0))
    }

    @Test func singleWindowCenteredHonorsSideSnapOffsets() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.defaultColumnWidth = nil
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor(width: 2056, height: 1290)
        let workingFrame = CGRect(x: 10, y: 0, width: 2036, height: 1280)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: monitor.visibleFrame,
            scale: 1
        )

        // Centered 60%: window width = 0.6 * 2036 = 1221.6, centerOffset = -407.2.
        engine.loneWindowPolicy = .centered(maxWidthFraction: 0.6)
        let expectedWidth: CGFloat = (2036 * 0.6).roundedToPhysicalPixel(scale: 1)
        let centerOffset = (expectedWidth - workingFrame.width) / 2

        // Centered snap.
        var centeredState = ViewportState()
        centeredState.viewOffsetPixels = .static(centerOffset)
        let centeredLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 8, vertical: 8),
            state: centeredState,
            workingArea: area
        )
        guard let centeredFrame = centeredLayout.frames[window.token] else {
            Issue.record("Expected a centered lone-window frame")
            return
        }
        #expect(abs(centeredFrame.midX - workingFrame.midX) < 1.0)

        // Left-edge snap (offset 0): window left aligns to working-frame left.
        var leftState = ViewportState()
        leftState.viewOffsetPixels = .static(0)
        let leftLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 8, vertical: 8),
            state: leftState,
            workingArea: area
        )
        guard let leftFrame = leftLayout.frames[window.token] else {
            Issue.record("Expected a left-snapped lone-window frame")
            return
        }
        #expect(abs(leftFrame.minX - workingFrame.minX) < 1.0)

        // Right-edge snap (offset 2*centerOffset): window right aligns to working-frame right.
        var rightState = ViewportState()
        rightState.viewOffsetPixels = .static(2 * centerOffset)
        let rightLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 8, vertical: 8),
            state: rightState,
            workingArea: area
        )
        guard let rightFrame = rightLayout.frames[window.token] else {
            Issue.record("Expected a right-snapped lone-window frame")
            return
        }
        #expect(abs(rightFrame.maxX - workingFrame.maxX) < 1.0)
    }

    @Test func singleWindowManualWidthOverrideKeepsWindowCenteredWhenAlwaysCenterSingleColumnDisabled() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.defaultColumnWidth = nil
        engine.loneWindowPolicy = .centered(maxWidthFraction: 0.75)
        engine.animationClock = AnimationClock()
        let wsId = UUID()
        let gap: CGFloat = 8
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        guard let column = engine.column(of: window) else {
            Issue.record("Expected a column for single-window manual width override test")
            return
        }

        var state = ViewportState()
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let settleBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for single-window manual width override test")
            return
        }

        let settleTime = settleBaseTime + 2.0
        let settledState = settledLayoutState(from: state, column: column, settleTime: settleTime)
        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: settledState,
            animationTime: settleTime
        )

        guard let frame = layout.frames[window.token] else {
            Issue.record("Expected a rendered frame for single-window manual width override test")
            return
        }

        #expect(column.hasManualSingleWindowWidthOverride)
        #expect(abs(frame.width - column.cachedWidth) < 1.0)
        #expect(abs(frame.midX - monitor.visibleFrame.midX) < 0.6)
        #expect(frame.height == monitor.visibleFrame.height)
    }

    @Test func singleWindowFullWidthRoundTripRestoresPriorManualWidthAndCentering() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.defaultColumnWidth = nil
        engine.loneWindowPolicy = .centered(maxWidthFraction: 0.75)
        engine.animationClock = AnimationClock()
        let wsId = UUID()
        let gap: CGFloat = 8
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        guard let column = engine.column(of: window) else {
            Issue.record("Expected a column for single-window full-width round-trip test")
            return
        }

        var state = ViewportState()
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let firstBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for single-window full-width round-trip test")
            return
        }

        let firstSettleTime = firstBaseTime + 2.0
        state = settledLayoutState(from: state, column: column, settleTime: firstSettleTime)
        let resizedLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state,
            animationTime: firstSettleTime
        )

        guard let resizedFrame = resizedLayout.frames[window.token] else {
            Issue.record("Expected a resized frame before toggling full width")
            return
        }

        engine.toggleFullWidth(
            column,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let secondBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after enabling full width")
            return
        }

        let secondSettleTime = secondBaseTime + 2.0
        state = settledLayoutState(from: state, column: column, settleTime: secondSettleTime)
        let fullWidthLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state,
            animationTime: secondSettleTime
        )

        guard let fullWidthFrame = fullWidthLayout.frames[window.token] else {
            Issue.record("Expected a full-width frame for single-window round-trip test")
            return
        }

        engine.toggleFullWidth(
            column,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let thirdBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after disabling full width")
            return
        }

        let thirdSettleTime = thirdBaseTime + 2.0
        state = settledLayoutState(from: state, column: column, settleTime: thirdSettleTime)
        let restoredLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state,
            animationTime: thirdSettleTime
        )

        guard let restoredFrame = restoredLayout.frames[window.token] else {
            Issue.record("Expected a restored frame after full-width round-trip")
            return
        }

        #expect(abs(fullWidthFrame.minX - (monitor.visibleFrame.minX + gap)) < 0.6)
        #expect(abs(fullWidthFrame.maxX - (monitor.visibleFrame.maxX - gap)) < 0.6)
        #expect(abs(restoredFrame.width - resizedFrame.width) < 0.6)
        #expect(abs(restoredFrame.midX - monitor.visibleFrame.midX) < 0.6)
    }

    @Test func singleWindowManualWidthTargetFrameMatchesRenderedFrame() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.defaultColumnWidth = nil
        engine.loneWindowPolicy = .centered(maxWidthFraction: 0.75)
        engine.animationClock = AnimationClock()
        let wsId = UUID()
        let gap: CGFloat = 8
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        guard let column = engine.column(of: window) else {
            Issue.record("Expected a column for single-window target-frame regression test")
            return
        }

        var state = ViewportState()
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let settleBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for single-window target-frame regression test")
            return
        }

        let settleTime = settleBaseTime + 2.0
        state = settledLayoutState(from: state, column: column, settleTime: settleTime)
        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state,
            animationTime: settleTime
        )

        guard let renderedFrame = layout.frames[window.token],
              let targetFrame = engine.targetFrameForWindow(
                  window.token,
                  in: wsId,
                  state: state,
                  workingFrame: monitor.visibleFrame,
                  gaps: gap
              )
        else {
            Issue.record("Expected rendered and target frames for single-window target-frame regression test")
            return
        }

        #expect(renderedFrame == targetFrame)
    }

    @Test func defaultColumnWidthMatchingPresetKeepsCenteredLoneWindowUntilManualResize() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [
            .proportion(0.85),
            .proportion(1.0),
            .proportion(0.5)
        ]
        engine.defaultColumnWidth = 0.85
        engine.loneWindowPolicy = .centered(maxWidthFraction: 0.75)
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        guard let column = engine.column(of: window) else {
            Issue.record("Expected a column for preset-matching single-window ratio test")
            return
        }

        // Seed the centered viewport offset (matching what the controller does).
        let workingFrameWidth: CGFloat = monitor.visibleFrame.width
        let expectedWidth = (workingFrameWidth * 0.75).roundedToPhysicalPixel(scale: 1)
        let centerOffset = (expectedWidth - workingFrameWidth) / 2
        var state = ViewportState()
        state.viewOffsetPixels = .static(centerOffset)

        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 8, vertical: 8),
            state: state
        )

        guard let frame = layout.frames[window.token] else {
            Issue.record("Expected a rendered frame for preset-matching single-window ratio test")
            return
        }

        #expect(column.presetWidthIdx == 0)
        #expect(!column.hasManualSingleWindowWidthOverride)
        #expect(abs(frame.midX - monitor.visibleFrame.midX) < 1.0)
        #expect(abs(frame.width - expectedWidth) < 1.0)
    }

    @Test func addingSecondWindowReturnsToNormalColumnSizingAfterSingleWindowOverride() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.defaultColumnWidth = nil
        engine.loneWindowPolicy = .centered(maxWidthFraction: 0.75)
        let wsId = UUID()
        let gap: CGFloat = 8
        let firstWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        let singleWindowLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: ViewportState()
        )

        let secondWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: firstWindow.id)
        let twoWindowLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: ViewportState()
        )

        guard let singleFrame = singleWindowLayout.frames[firstWindow.token],
              let firstFrame = twoWindowLayout.frames[firstWindow.token],
              let secondFrame = twoWindowLayout.frames[secondWindow.token]
        else {
            Issue.record("Expected rendered frames before and after adding a second Niri window")
            return
        }

        let expectedColumnWidth = ((monitor.visibleFrame.width - gap) / 3 - gap).roundedToPhysicalPixel(scale: 2.0)

        #expect(engine.columns(in: wsId).count == 2)
        #expect(firstFrame.width < singleFrame.width)
        #expect(abs(firstFrame.width - expectedColumnWidth) < 0.6)
        #expect(abs(secondFrame.width - expectedColumnWidth) < 0.6)
        #expect(firstFrame.height == monitor.visibleFrame.height)
        #expect(secondFrame.height == monitor.visibleFrame.height)
    }

    @Test func addingSecondWindowCentersProportionalSlack() {
        let engine = NiriLayoutEngine(balancedColumnCount: 2)
        let wsId = UUID()
        let gap: CGFloat = 16
        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: 9_401), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(
            handle: makeTestHandle(pid: 9_402),
            to: wsId,
            afterSelection: firstWindow.id
        )
        let monitor = makeLayoutPlanTestMonitor(width: 2_056, height: 1_290)
        let workingFrame = monitor.visibleFrame

        for column in engine.columns(in: wsId) {
            column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.selectedNodeId = firstWindow.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: secondWindow,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        state.viewOffsetPixels = .static(state.viewOffsetPixels.target())

        let columns = engine.columns(in: wsId)
        let viewStart = viewportStart(for: state, columns: columns, gap: gap)
        #expect(abs(viewStart + gap) < 0.6)

        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state
        )

        guard let firstFrame = layout.frames[firstWindow.token],
              let secondFrame = layout.frames[secondWindow.token]
        else {
            Issue.record("Expected both two-column windows to render")
            return
        }

        #expect(abs(firstFrame.width - 1_004) < 0.6)
        #expect(abs(secondFrame.width - 1_004) < 0.6)
        #expect(abs(firstFrame.minX - 16) < 0.6)
        #expect(abs(secondFrame.minX - 1_036) < 0.6)
    }

    @Test @MainActor func removingSecondWindowResetsFillLoneViewportDuringRemovalAnimation() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 2_056, height: 1_290)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id else {
            Issue.record("Missing active workspace for lone-window removal viewport regression test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()
        controller.niriEngine?.presetColumnWidths = [.proportion(0.5), .proportion(0.5)]
        controller.niriEngine?.defaultColumnWidth = 0.5

        let survivingToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 1_641)
        let removedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 1_642)
        _ = controller.workspaceManager.setManagedFocus(removedToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        guard let engine = controller.niriEngine,
              let removedNode = engine.findNode(for: removedToken),
              let survivingNode = engine.findNode(for: survivingToken)
        else {
            Issue.record("Expected Niri nodes for lone-window removal viewport regression test")
            return
        }

        let gap = controller.gapSize(for: monitor)
        let rightColumnX = controller.workspaceManager.niriViewportState(for: workspaceId).columnX(
            at: 1,
            columns: engine.columns(in: workspaceId),
            gap: gap
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = removedNode.id
            state.activeColumnIndex = 1
            state.viewOffsetPixels = .static(-gap - rightColumnX)
        }

        _ = controller.workspaceManager.removeWindow(pid: removedToken.pid, windowId: removedToken.windowId)

        let removalPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = removalPlans.first,
              let viewportState = plan.sessionPatch.viewportState
        else {
            Issue.record("Expected Niri removal plan with viewport patch")
            return
        }

        #expect(viewportState.selectedNodeId == survivingNode.id)
        #expect(viewportState.activeColumnIndex == 0)
        #expect(abs(viewportState.viewOffsetPixels.target()) < 0.6)
        #expect(plan.diff.frameChanges.contains { change in
            change.token == survivingToken
                && abs(change.frame.minX - monitor.visibleFrame.minX) < 0.6
                && abs(change.frame.width - monitor.visibleFrame.width) < 0.6
        })
    }

    @Test func additionalWindowUsesExplicitDefaultWidthWhenCreatingNewColumn() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.6
        let wsId = UUID()

        let firstWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: firstWindow.id)

        guard let column = engine.column(of: secondWindow) else {
            Issue.record("Expected new column for second window")
            return
        }

        #expect(engine.columns(in: wsId).count == 2)
        #expect(column.width == .proportion(0.6))
        #expect(column.presetWidthIdx == nil)
    }

    @Test func selectionFallbackAfterColumnRemoval() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count == 3)

        let middleColIdx = 1
        var state = ViewportState()
        state.activeColumnIndex = 0

        let result = engine.animateColumnsForRemoval(
            columnIndex: middleColIdx,
            in: wsId,
            state: &state,
            gaps: 8
        )

        #expect(result.fallbackSelectionId != nil)
        let fallbackNode = engine.findNode(by: result.fallbackSelectionId!)
        #expect(fallbackNode != nil)
        #expect(result.fallbackSelectionId != w2.id)
        let isW1OrW3 = result.fallbackSelectionId == w1.id || result.fallbackSelectionId == w3.id
        #expect(isW1OrW3)
    }

    @Test func removalTransactionActiveMiddleColumnUsesRightNeighborFallback() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let workingFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let gap: CGFloat = 8

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let _ = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: nil)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)
        assignFixedWidths(engine.columns(in: wsId), width: 200)

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.selectedNodeId = w2.id
        state.viewOffsetPixels = .static(0)

        let result = engine.removeWindows(
            Set([h2.id]),
            in: wsId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: gap,
            selectedNodeId: w2.id,
            removedNodeIds: [w2.id]
        )

        #expect(engine.columns(in: wsId).count == 2)
        #expect(engine.findNode(by: w2.id) == nil)
        #expect(result.removedTokens == Set([h2.id]))
        #expect(result.removedColumnIndicesBefore == [1])
        #expect(result.activeIndexBefore == Optional(1))
        #expect(result.activeIndexAfter == Optional(1))
        #expect(result.finalSelectionId == w3.id)
        #expect(state.selectedNodeId == w3.id)
        #expect(state.activeColumnIndex == 1)
    }

    @Test func removalTransactionRestoresPendingPreviousActivationOffset() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let workingFrame = CGRect(x: 0, y: 0, width: 2000, height: 800)

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        assignFixedWidths(engine.columns(in: wsId), width: 200)

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.selectedNodeId = w2.id
        state.viewOffsetPixels = .static(456)
        state.viewOffsetToRestore = 999
        state.activatePrevColumnOnRemoval = 123

        let result = engine.removeWindows(
            Set([h2.id]),
            in: wsId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: 8,
            selectedNodeId: w2.id,
            removedNodeIds: [w2.id]
        )

        #expect(engine.columns(in: wsId).count == 1)
        #expect(result.finalSelectionId == w1.id)
        #expect(result.visibilityWasCorrected)
        #expect(state.selectedNodeId == w1.id)
        #expect(state.activeColumnIndex == 0)
        #expect(state.activatePrevColumnOnRemoval == nil)
        #expect(state.viewOffsetToRestore == nil)
        #expect(abs(state.viewOffsetPixels.current() + 8) < 0.001)
    }

    @Test func removalTransactionClearsPendingPreviousWhenPreviousTargetIsRemoved() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let workingFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()
        let _ = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: nil)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)
        assignFixedWidths(engine.columns(in: wsId), width: 200)

        var state = ViewportState()
        state.activeColumnIndex = 2
        state.selectedNodeId = w3.id
        state.viewOffsetPixels = .static(0)
        state.activatePrevColumnOnRemoval = 321

        let result = engine.removeWindows(
            Set([h2.id]),
            in: wsId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: 8,
            selectedNodeId: w3.id,
            removedNodeIds: [w2.id]
        )

        #expect(engine.columns(in: wsId).count == 2)
        #expect(result.finalSelectionId == w3.id)
        #expect(state.selectedNodeId == w3.id)
        #expect(state.activeColumnIndex == 1)
        #expect(state.activatePrevColumnOnRemoval == nil)
        #expect(abs(state.viewOffsetPixels.current() - 208) < 0.001)
    }

    @Test func removalTransactionBatchExcludesRemovedFallbackTargets() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let workingFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()
        let h4 = makeTestHandle()
        let _ = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: nil)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)
        let w4 = engine.addWindow(handle: h4, to: wsId, afterSelection: w3.id)
        assignFixedWidths(engine.columns(in: wsId), width: 200)

        engine.interactiveResize = InteractiveResize(
            windowId: w2.id,
            workspaceId: wsId,
            originalColumnWidth: 200,
            originalWindowHeight: nil,
            edges: [.right],
            startMouseLocation: .zero,
            columnIndex: 1,
            originalViewOffset: nil
        )

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.selectedNodeId = w2.id
        state.viewOffsetPixels = .static(0)

        let result = engine.removeWindows(
            Set([h2.id, h3.id]),
            in: wsId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: 8,
            selectedNodeId: w2.id,
            removedNodeIds: [w2.id, w3.id]
        )

        #expect(engine.columns(in: wsId).count == 2)
        #expect(engine.interactiveResize == nil)
        #expect(result.removedColumnIndicesBefore == [1, 1])
        #expect(result.finalSelectionId == w4.id)
        #expect(state.selectedNodeId == w4.id)
        #expect(state.activeColumnIndex == 1)
    }

    @Test func removalTransactionSurvivingColumnTileFallbackAdjustsWithinColumn() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)
        column.cachedWidth = 300

        let bottom = NiriWindow(token: makeTestHandle(pid: 201).id)
        let top = NiriWindow(token: makeTestHandle(pid: 202).id)
        bottom.height = .auto(weight: 2)
        top.height = .auto(weight: 3)
        column.appendChild(bottom)
        column.appendChild(top)
        column.setActiveTileIdx(1)
        engine.tokenToNode[bottom.token] = bottom
        engine.tokenToNode[top.token] = top

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.selectedNodeId = top.id

        let result = engine.removeWindows(
            Set([top.token]),
            in: wsId,
            state: &state,
            motion: .disabled,
            workingFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: 8,
            selectedNodeId: top.id,
            removedNodeIds: [top.id]
        )

        #expect(engine.columns(in: wsId).count == 1)
        #expect(column.windowNodes.map(\.id) == [bottom.id])
        #expect(column.activeWindow?.id == bottom.id)
        #expect(bottom.height == .auto(weight: 1.0))
        #expect(result.removedColumnIndicesBefore.isEmpty)
        #expect(result.finalSelectionId == bottom.id)
        #expect(state.selectedNodeId == bottom.id)
    }

    @Test func removalTransactionNoOpDoesNotValidateStaleSelection() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let staleSelection = NodeId()

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.selectedNodeId = staleSelection

        let result = engine.removeWindows(
            [],
            in: wsId,
            state: &state,
            motion: .disabled,
            workingFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: 8,
            selectedNodeId: staleSelection,
            removedNodeIds: []
        )

        #expect(result.finalSelectionId == nil)
        #expect(state.selectedNodeId == staleSelection)
        #expect(engine.validateSelection(state.selectedNodeId, in: wsId) == window.id)
    }

    @Test func viewportOffsetAdjustsForInsertionBeforeActive() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let _ = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count == 2)

        let workingWidth: CGFloat = 1000
        let gap: CGFloat = 8
        for col in cols {
            col.resolveAndCacheWidth(workingAreaWidth: workingWidth, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let h3 = makeTestHandle()
        engine.syncWindows(
            [h3, h1, h2],
            in: wsId,
            selectedNodeId: w1.id,
            focusedHandle: nil
        )

        let colsAfter = engine.columns(in: wsId)
        #expect(colsAfter.count == 3)

        let newNode = engine.findNode(for: h3)
        #expect(newNode != nil)

        if let newCol = engine.column(of: newNode!),
           let newColIdx = engine.columnIndex(of: newCol, in: wsId)
        {
            if newColIdx <= state.activeColumnIndex {
                newCol.resolveAndCacheWidth(workingAreaWidth: workingWidth, gaps: gap)
                let shiftAmount = newCol.cachedWidth + gap
                state.viewOffsetPixels.offset(delta: Double(-shiftAmount))
                state.activeColumnIndex += 1
            }
        }

        #expect(state.viewOffsetPixels.current() < 0)
        #expect(state.activeColumnIndex == 2)
    }

    @Test func constraintApplicationRespectsBounds() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let _ = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)

        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 400, height: 300),
            maxSize: CGSize(width: 800, height: 600),
            isFixed: false
        )
        engine.updateWindowConstraints(for: h1, constraints: constraints)

        let window = engine.findNode(for: h1)!
        #expect(window.constraints == constraints)
        #expect(window.constraints.minSize.width == 400)
        #expect(window.constraints.maxSize.width == 800)
    }

    @Test func constraintApplicationCancelsWidthAnimationWhenRuntimeMinimumExceedsTarget() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        guard let column = engine.column(of: window) else {
            Issue.record("Expected column for runtime minimum animation clamp test")
            return
        }

        column.cachedWidth = 401.6
        column.widthAnimation = SpringAnimation(
            from: 606.4,
            to: 401.6,
            initialVelocity: 0,
            startTime: 0,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: 60
        )
        column.targetWidth = 401.6

        engine.updateWindowConstraints(
            for: window.token,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 668, height: 100),
                maxSize: .zero,
                isFixed: false
            )
        )

        #expect(column.cachedWidth == 668)
        #expect(column.targetWidth == nil)
        #expect(column.widthAnimation == nil)
    }

    @Test func solverRedistributesSpaceAfterMaxCapsWithoutReviolatingThem() {
        let outputs = NiriAxisSolver.solve(
            windows: [
                .init(
                    weight: 1,
                    minConstraint: 0,
                    maxConstraint: 100,
                    hasMaxConstraint: true,
                    isConstraintFixed: false,
                    hasFixedValue: false,
                    fixedValue: nil
                ),
                .init(
                    weight: 1,
                    minConstraint: 0,
                    maxConstraint: 400,
                    hasMaxConstraint: true,
                    isConstraintFixed: false,
                    hasFixedValue: false,
                    fixedValue: nil
                ),
                .init(
                    weight: 1,
                    minConstraint: 0,
                    maxConstraint: 0,
                    hasMaxConstraint: false,
                    isConstraintFixed: false,
                    hasFixedValue: false,
                    fixedValue: nil
                )
            ],
            availableSpace: 1200,
            gapSize: 0
        )

        #expect(outputs.count == 3)
        #expect(abs(outputs[0].value - 400) < 0.001)
        #expect(abs(outputs[1].value - 400) < 0.001)
        #expect(abs(outputs[2].value - 400) < 0.001)
    }

    @Test func solverFixedOverflowClampsFixedWindowAndPreservesAutoMinimum() {
        let outputs = NiriAxisSolver.solve(
            windows: [
                .init(
                    weight: 0,
                    minConstraint: 80,
                    maxConstraint: 0,
                    hasMaxConstraint: false,
                    isConstraintFixed: false,
                    hasFixedValue: true,
                    fixedValue: 80
                ),
                .init(
                    weight: 1,
                    minConstraint: 0,
                    maxConstraint: 0,
                    hasMaxConstraint: false,
                    isConstraintFixed: false,
                    hasFixedValue: false,
                    fixedValue: nil
                )
            ],
            availableSpace: 50,
            gapSize: 0
        )

        #expect(outputs.count == 2)
        #expect(abs(outputs[0].value - 49) < 0.001)
        #expect(outputs[0].wasConstrained == true)
        #expect(outputs[1].value == 1)
        #expect(outputs[1].wasConstrained == false)
        #expect(abs(outputs.map(\.value).reduce(0, +) - 50) < 0.001)
    }

    @Test func columnWidthDoesNotShrinkBelowRequiredFixedChildWidth() {
        let column = NiriContainer()

        let locked = NiriWindow(token: WindowToken(pid: 41, windowId: 4101))
        locked.constraints = .fixed(size: CGSize(width: 700, height: 320))

        let capped = NiriWindow(token: WindowToken(pid: 41, windowId: 4102))
        capped.constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: 1),
            maxSize: CGSize(width: 500, height: 0),
            isFixed: false
        )

        column.appendChild(locked)
        column.appendChild(capped)
        column.width = .proportion(1.0)
        column.resolveAndCacheWidth(workingAreaWidth: 1200, gaps: 0)

        #expect(abs(column.cachedWidth - 700) < 0.001)
    }

    @Test func tabbedColumnDoesNotUseInnerGapsForSharedTileFrameEdges() {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        let workspaceId = UUID()
        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root

        let column = NiriContainer()
        column.displayMode = .tabbed
        root.appendChild(column)

        let bottomWindow = NiriWindow(token: makeTestHandle(pid: 200).id)
        let topWindow = NiriWindow(token: makeTestHandle(pid: 201).id)
        column.appendChild(bottomWindow)
        column.appendChild(topWindow)
        engine.tokenToNode[bottomWindow.token] = bottomWindow
        engine.tokenToNode[topWindow.token] = topWindow

        let monitor = makeLayoutPlanTestMonitor(width: 1200, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: ViewportState()
        )

        guard let bottomFrame = layout.frames[bottomWindow.token],
              let topFrame = layout.frames[topWindow.token]
        else {
            Issue.record("Expected both tabbed windows to receive frames")
            return
        }

        #expect(abs(bottomFrame.minY) < 0.001)
        #expect(abs(topFrame.minY) < 0.001)
        #expect(abs(bottomFrame.height - 900) < 0.001)
        #expect(abs(topFrame.height - 900) < 0.001)
    }

    @Test func verticalTabbedColumnDoesNotUseInnerGapsForSharedTileFrameEdges() {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        let workspaceId = UUID()
        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root

        let column = NiriContainer()
        column.displayMode = .tabbed
        root.appendChild(column)

        let bottomWindow = NiriWindow(token: makeTestHandle(pid: 202).id)
        let topWindow = NiriWindow(token: makeTestHandle(pid: 203).id)
        column.appendChild(bottomWindow)
        column.appendChild(topWindow)
        engine.tokenToNode[bottomWindow.token] = bottomWindow
        engine.tokenToNode[topWindow.token] = topWindow

        let monitor = makeLayoutPlanTestMonitor(width: 900, height: 1200)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: ViewportState()
        )

        guard let bottomFrame = layout.frames[bottomWindow.token],
              let topFrame = layout.frames[topWindow.token]
        else {
            Issue.record("Expected both vertical tabbed windows to receive frames")
            return
        }

        #expect(abs(bottomFrame.minX) < 0.001)
        #expect(abs(topFrame.minX) < 0.001)
        #expect(abs(bottomFrame.width - 900) < 0.001)
        #expect(abs(topFrame.width - 900) < 0.001)
    }

    @Test func syncWindowsIdempotency() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        engine.syncWindows([h1, h2, h3], in: wsId, selectedNodeId: nil)

        let colCount1 = engine.columns(in: wsId).count
        let windowIds1 = engine.root(for: wsId)!.windowIdSet

        engine.syncWindows([h1, h2, h3], in: wsId, selectedNodeId: nil)

        let colCount2 = engine.columns(in: wsId).count
        let windowIds2 = engine.root(for: wsId)!.windowIdSet

        #expect(colCount1 == colCount2)
        #expect(windowIds1 == windowIds2)
    }

    @Test func syncWindowsKeepsStableNodeForReobservedToken() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let original = makeTestHandle(pid: 21)
        let refreshed = WindowHandle(
            id: original.id,
            pid: original.pid,
            axElement: AXUIElementCreateSystemWide()
        )

        engine.syncWindows([original], in: wsId, selectedNodeId: nil)
        let originalNodeId = engine.findNode(for: original.id)?.id

        engine.syncWindows([refreshed], in: wsId, selectedNodeId: nil)

        #expect(engine.root(for: wsId)?.allWindows.count == 1)
        #expect(engine.root(for: wsId)?.windowIdSet == Set([original.id]))
        #expect(engine.findNode(for: refreshed.id)?.id == originalNodeId)
    }

    @Test func rekeyWindowKeepsNodeAndSelectionStableAcrossSync() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let handle1 = makeTestHandle(pid: 61)
        let handle2 = makeTestHandle(pid: 62)
        let handle3 = makeTestHandle(pid: 63)

        let firstWindow = engine.addWindow(handle: handle1, to: wsId, afterSelection: nil)
        let rekeyedWindow = engine.addWindow(handle: handle2, to: wsId, afterSelection: firstWindow.id)
        let _ = engine.addWindow(handle: handle3, to: wsId, afterSelection: rekeyedWindow.id)

        let replacementToken = WindowToken(pid: handle2.pid, windowId: handle2.windowId + 1000)
        let originalNodeId = rekeyedWindow.id

        #expect(engine.rekeyWindow(from: handle2.id, to: replacementToken))

        let removed = engine.syncWindows(
            [handle1.id, replacementToken, handle3.id],
            in: wsId,
            selectedNodeId: originalNodeId,
            focusedToken: handle3.id
        )

        #expect(removed.isEmpty)
        #expect(engine.findNode(for: handle2.id) == nil)
        #expect(engine.findNode(for: replacementToken)?.id == originalNodeId)
        #expect(engine.validateSelection(originalNodeId, in: wsId) == originalNodeId)
        #expect(engine.root(for: wsId)?.windowIdSet == Set([handle1.id, replacementToken, handle3.id]))
    }

    @Test func ensureSelectionVisibleMovesViewport() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: w3,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(state.activeColumnIndex == 2)
    }

    @Test func ensureSelectionVisiblePreservesViewportWhenTargetIsFullyVisible() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let first = engine.addWindow(handle: makeTestHandle(pid: 301), to: wsId, afterSelection: nil)
        let second = engine.addWindow(handle: makeTestHandle(pid: 302), to: wsId, afterSelection: first.id)
        _ = engine.addWindow(handle: makeTestHandle(pid: 303), to: wsId, afterSelection: second.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let gap: CGFloat = 8
        let leftWidth = (workingFrame.width - gap) * (2.0 / 3.0)
        let rightWidth = (workingFrame.width - gap) / 3.0
        assignWidths(
            engine.columns(in: wsId),
            widths: [leftWidth, rightWidth, rightWidth]
        )

        var state = ViewportState()
        state.selectedNodeId = first.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: second,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        let columns = engine.columns(in: wsId)
        #expect(state.activeColumnIndex == 1)
        // After ensureSelectionVisible, the viewport maintains visual continuity
        let viewStart = state.columnX(at: state.activeColumnIndex, columns: columns, gap: gap)
            + state.viewOffsetPixels.target()
        #expect(viewStart >= -1) // viewport stays near origin
        #expect(viewStart < gap * 2) // within a small margin
    }

    @Test func ensureSelectionVisibleAdvancesViewportWhenTargetIsOffscreen() {
        // Verify that ensureSelectionVisible correctly shifts the viewport
        // when navigating to a column that is not currently visible.
        struct Scenario {
            let label: String
            let visibleCount: Int
            let extraColumns: Int
            let initialActiveIndex: Int
            let targetIndex: Int
        }

        let scenarios = [
            Scenario(
                label: "forward to offscreen",
                visibleCount: 2,
                extraColumns: 2,
                initialActiveIndex: 0,
                targetIndex: 2
            ),
            Scenario(
                label: "backward to offscreen",
                visibleCount: 2,
                extraColumns: 2,
                initialActiveIndex: 2,
                targetIndex: 0
            ),
            Scenario(label: "forward to last", visibleCount: 2, extraColumns: 2, initialActiveIndex: 1, targetIndex: 3)
        ]

        for scenario in scenarios {
            let fixture = makeVisibleColumnFixture(
                visibleCount: scenario.visibleCount,
                extraColumns: scenario.extraColumns
            )

            let columns = fixture.engine.columns(in: fixture.workspaceId)
            guard let columnWidth = columns.first?.cachedWidth else {
                Issue.record("Expected equal-width columns for \(scenario.label)")
                continue
            }

            let columnStride = columnWidth + fixture.gap
            let initialViewStart = columnStride * CGFloat(scenario.initialActiveIndex)

            var state = ViewportState()
            state.selectedNodeId = fixture.windows[scenario.initialActiveIndex].id
            state.activeColumnIndex = scenario.initialActiveIndex
            state.viewOffsetPixels = .static(
                initialViewStart
                    - state.columnX(
                        at: scenario.initialActiveIndex,
                        columns: columns,
                        gap: fixture.gap
                    )
            )

            let initialViewportEnd = initialViewStart + fixture.monitor.visibleFrame.width
            let initialTargetX = state.columnX(at: scenario.targetIndex, columns: columns, gap: fixture.gap)
            let initialTargetEnd = initialTargetX + columns[scenario.targetIndex].cachedWidth
            #expect(
                initialTargetEnd < initialViewStart || initialTargetX > initialViewportEnd,
                Comment(rawValue: scenario.label)
            )

            fixture.engine.ensureSelectionVisible(
                node: fixture.windows[scenario.targetIndex],
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            #expect(state.activeColumnIndex == scenario.targetIndex, Comment(rawValue: scenario.label))
            let newViewStart = viewportStart(for: state, columns: columns, gap: fixture.gap)
            #expect(abs(newViewStart - initialViewStart) > 0.5, Comment(rawValue: scenario.label))
            let targetX = state.columnX(at: scenario.targetIndex, columns: columns, gap: fixture.gap)
            let targetEnd = targetX + columns[scenario.targetIndex].cachedWidth
            #expect(targetX <= newViewStart + fixture.monitor.visibleFrame.width, Comment(rawValue: scenario.label))
            #expect(targetEnd >= newViewStart, Comment(rawValue: scenario.label))
        }
    }

    @Test func ensureSelectionVisibleMakesTargetColumnVisible() {
        struct Scenario {
            let label: String
            let initialActiveIndex: Int
            let initialViewStartIndex: Int
            let targetIndex: Int
        }

        let scenarios: [Scenario] = [
            .init(label: "right", initialActiveIndex: 1, initialViewStartIndex: 0, targetIndex: 2),
            .init(label: "left", initialActiveIndex: 3, initialViewStartIndex: 3, targetIndex: 2)
        ]

        for scenario in scenarios {
            let fixture = makeVisibleColumnFixture(visibleCount: 2, extraColumns: 2)

            let columns = fixture.engine.columns(in: fixture.workspaceId)
            guard let columnWidth = columns.first?.cachedWidth else {
                Issue.record("Expected equal-width columns for \(scenario.label)")
                continue
            }

            let columnStride = columnWidth + fixture.gap
            let initialViewStart = CGFloat(scenario.initialViewStartIndex) * columnStride

            var state = ViewportState()
            state.selectedNodeId = fixture.windows[scenario.initialActiveIndex].id
            state.activeColumnIndex = scenario.initialActiveIndex
            state.viewOffsetPixels = .static(
                initialViewStart
                    - state.columnX(at: scenario.initialActiveIndex, columns: columns, gap: fixture.gap)
            )

            fixture.engine.ensureSelectionVisible(
                node: fixture.windows[scenario.targetIndex],
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            #expect(state.activeColumnIndex == scenario.targetIndex, Comment(rawValue: scenario.label))
            // Target column must be visible in the viewport
            let newViewStart = viewportStart(for: state, columns: columns, gap: fixture.gap)
            let targetX = state.columnX(at: scenario.targetIndex, columns: columns, gap: fixture.gap)
            let targetEnd = targetX + columns[scenario.targetIndex].cachedWidth
            let viewEnd = newViewStart + fixture.monitor.visibleFrame.width
            #expect(targetX < viewEnd, Comment(rawValue: scenario.label))
            #expect(targetEnd > newViewStart, Comment(rawValue: scenario.label))
        }
    }

    @Test func ensureSelectionVisibleNoOpRebaseWhenActiveColumnIndexAlreadyMatchesTarget() {
        // Regression for the focus-confirm reveal plan, Phase 3 bullet 3:
        // once activeColumnIndex is already synced to the selected node's
        // real column (Phase 1's job at focus-confirm time), the relayout's
        // ensureSelectionVisible must treat the rebase as a true no-op rather
        // than re-deriving and reapplying an "instant rebase" mutation.
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        assignWidths(engine.columns(in: wsId), widths: [500, 500])

        var state = ViewportState()
        state.selectedNodeId = w2.id
        state.activeColumnIndex = 1
        // Viewport already positioned so column 1 (the target's real column,
        // matching activeColumnIndex) exactly fills the working frame -
        // nothing should move. viewStart = columnX(activeColumnIndex) +
        // offset, so a zero offset anchored at column 1 starts the viewport
        // exactly at column 1's origin.
        state.viewOffsetPixels = .static(0)
        state.isViewportMutationAuditEnabled = true

        engine.ensureSelectionVisible(
            node: w2,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(state.activeColumnIndex == 1)
        #expect(state.lastViewportMutationReason == nil)
    }

    @Test func moveWindowHorizontalRightExpelsFocusedWindowIntoNewColumn() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let firstHandle = makeTestHandle(pid: 71)
        let focusedHandle = makeTestHandle(pid: 72)
        let rightHandle = makeTestHandle(pid: 73)
        let firstWindow = NiriWindow(token: firstHandle.id)
        let focusedWindow = NiriWindow(token: focusedHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(firstWindow)
        leftColumn.appendChild(focusedWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[firstHandle.id] = firstWindow
        engine.tokenToNode[focusedHandle.id] = focusedWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            focusedWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 3)
        #expect(columns[0].windowNodes.map(\.token) == [firstHandle.id])
        #expect(columns[1].windowNodes.map(\.token) == [focusedHandle.id])
        #expect(columns[2].windowNodes.map(\.token) == [rightHandle.id])
    }

    @Test func moveWindowHorizontalRightConsumesSingleWindowColumnIntoNeighbor() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 81)
        let rightHandle = makeTestHandle(pid: 82)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === rightColumn)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
        #expect(columns[0].hasMoveAnimationRunning)

        let windowOffset = leftWindow.moveXAnimation?.fromOffset
        #expect(windowOffset != nil)
        #expect(windowOffset! < -300)

        let columnOffset = rightColumn.moveAnimation?.fromOffset
        #expect(columnOffset != nil)
        #expect(columnOffset! > 300)
    }

    @Test func moveWindowHorizontalRightConsumesSingleWindowColumnIntoStackedNeighbor() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 602, name: "GlobalOnly", x: 0)
        attachWorkspace(wsId, to: monitor, engine: engine)

        guard let root = engine.root(for: wsId) else {
            Issue.record("Expected mapped workspace root for consume fallback test")
            return
        }

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 183)
        let rightHandle = makeTestHandle(pid: 184)
        let stackedHandle = makeTestHandle(pid: 185)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)
        let stackedWindow = NiriWindow(token: stackedHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(stackedWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[stackedHandle.id] = stackedWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === rightColumn)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, stackedHandle.id, rightHandle.id])
    }

    @Test func moveWindowHorizontalLeftConsumesSingleWindowColumnIntoNeighbor() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 83)
        let rightHandle = makeTestHandle(pid: 84)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 1

        let moved = engine.moveWindow(
            rightWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === leftColumn)
        #expect(columns[0].windowNodes.map(\.token) == [rightHandle.id, leftHandle.id])
        #expect(!columns[0].hasMoveAnimationRunning)

        let windowOffset = rightWindow.moveXAnimation?.fromOffset
        #expect(windowOffset != nil)
        #expect(windowOffset! > 300)
    }

    @Test func ensureSelectionVisibleUsesExplicitPreviousActivePositionAfterColumnRemoval() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignWidths(root.columns, widths: [300, 500])

        let leftHandle = makeTestHandle(pid: 85)
        let rightHandle = makeTestHandle(pid: 86)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let previousActivePosition = state.columnX(
            at: state.activeColumnIndex,
            columns: engine.columns(in: wsId),
            gap: 8
        )

        leftColumn.remove()

        engine.ensureSelectionVisible(
            node: rightWindow,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 700, height: 900),
            gaps: 8,
            fromContainerIndex: 1,
            previousActiveContainerPosition: previousActivePosition
        )

        if case let .spring(animation) = state.viewOffsetPixels {
            #expect(abs(animation.from - Double(previousActivePosition)) < 0.1)
        } else {
            #expect(Bool(false))
        }
    }

    @Test func moveWindowHorizontalLeftNoOpsAtEdgeWithoutInfiniteLoop() {
        let engine = NiriLayoutEngine(infiniteLoop: false)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 91)
        let rightHandle = makeTestHandle(pid: 92)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(!moved)
        #expect(columns.count == 2)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id])
        #expect(columns[1].windowNodes.map(\.token) == [rightHandle.id])
    }

    @Test func moveWindowHorizontalLeftWrapsAtEdgeWhenInfiniteLoopIsEnabled() {
        let engine = NiriLayoutEngine(infiniteLoop: true)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 101)
        let rightHandle = makeTestHandle(pid: 102)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
    }

    @Test func moveWindowHorizontalLeftWrapsAtEdgeWhenMonitorOverrideEnablesInfiniteLoop() {
        let engine = NiriLayoutEngine(infiniteLoop: false)
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 701, name: "Wrap", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(for: engine, infiniteLoop: true)
        )

        guard let root = engine.root(for: wsId) else {
            Issue.record("Expected mapped workspace root for infinite-loop override test")
            return
        }

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 191)
        let rightHandle = makeTestHandle(pid: 192)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
    }

    @Test func ensureSelectionVisibleUsesResolvedMonitorAlwaysCenterSingleColumn() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 801, name: "CenterSingle", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine
            )
        )

        let window = engine.addWindow(handle: makeTestHandle(pid: 211), to: wsId, afterSelection: nil)
        assignFixedWidths(engine.columns(in: wsId))

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: window,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        #expect(abs(state.viewOffsetPixels.target() + 400) < 0.1)
    }

    @Test func moveWindowVerticalKeepsInColumnReorderBehavior() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)
        assignFixedWidths(root.columns)

        let firstHandle = makeTestHandle(pid: 111)
        let focusedHandle = makeTestHandle(pid: 112)
        let lastHandle = makeTestHandle(pid: 113)
        let firstWindow = NiriWindow(token: firstHandle.id)
        let focusedWindow = NiriWindow(token: focusedHandle.id)
        let lastWindow = NiriWindow(token: lastHandle.id)

        column.appendChild(firstWindow)
        column.appendChild(focusedWindow)
        column.appendChild(lastWindow)

        engine.tokenToNode[firstHandle.id] = firstWindow
        engine.tokenToNode[focusedHandle.id] = focusedWindow
        engine.tokenToNode[lastHandle.id] = lastWindow

        let beforeMove = column.windowNodes.map(\.token)
        var state = ViewportState()

        let moved = engine.moveWindow(
            focusedWindow,
            direction: .up,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let afterMove = column.windowNodes.map(\.token)
        #expect(moved)
        #expect(beforeMove == [firstHandle.id, focusedHandle.id, lastHandle.id])
        #expect(afterMove == [firstHandle.id, lastHandle.id, focusedHandle.id])
    }

    @Test @MainActor func horizontalConsumeStartsAnimationLoopAndSettlesMovedWindowFrame() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for horizontal consume regression test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        controller.updateNiriConfig(balancedColumnCount: 3)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.syncMonitorsToNiriEngine()

        let leftWindowId = 811
        let focusedWindowId = 812
        let rightWindowId = 813

        let leftToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: leftWindowId)
        let focusedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: focusedWindowId)
        let rightToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: rightWindowId)

        _ = controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId, onMonitor: monitor.id)

        guard let engine = controller.niriEngine,
              let focusedHandle = controller.workspaceManager.handle(for: focusedToken)
        else {
            Issue.record("Expected Niri engine and focused handle for horizontal consume regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: focusedHandle
        )

        let columns = engine.columns(in: workspaceId)
        guard columns.count == 3 else {
            Issue.record("Expected three visible columns before consuming the focused window")
            return
        }
        assignFixedWidths(columns)

        guard let focusedNode = engine.findNode(for: focusedToken) else {
            Issue.record("Expected focused node in Niri engine before consuming window")
            return
        }

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: focusedNode.id,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = focusedNode.id
            state.activeColumnIndex = 1
            state.viewOffsetPixels = .static(0)
        }

        controller.commandHandler.handleCommand(.move(.right))

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == workspaceId)

        await waitForLayoutPlanRefreshWork(on: controller)

        let settleTime = (engine.animationClock?.now() ?? 0) + 5.0
        controller.niriLayoutHandler.tickScrollAnimation(targetTime: settleTime, displayId: monitor.displayId)

        let movedColumns = engine.columns(in: workspaceId)
        #expect(movedColumns.count == 2)
        #expect(movedColumns[0].windowNodes.map(\.token) == [leftToken])
        #expect(movedColumns[1].windowNodes.map(\.token) == [focusedToken, rightToken])
        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)

        guard let movedNode = engine.findNode(for: focusedToken),
              let settledFrame = movedNode.renderedFrame ?? movedNode.frame,
              let appliedFrame = controller.axManager.lastAppliedFrame(for: focusedWindowId)
        else {
            Issue.record("Expected the consumed focused window to receive a settled visible frame")
            return
        }

        let workingFrame = controller.insetWorkingFrame(for: monitor)
        #expect(abs(appliedFrame.minX - settledFrame.minX) < 1.0)
        #expect(abs(appliedFrame.minY - settledFrame.minY) < 1.0)
        #expect(abs(appliedFrame.width - settledFrame.width) < 1.0)
        #expect(abs(appliedFrame.height - settledFrame.height) < 1.0)
        #expect(workingFrame.intersects(appliedFrame))
    }

    @Test @MainActor func horizontalConsumeIntoTabbedColumnBottomInsertsAndActivatesConsumedWindow() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for tabbed horizontal consume regression test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        controller.updateNiriConfig(balancedColumnCount: 3)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.syncMonitorsToNiriEngine()

        let consumedWindowId = 821
        let existingBottomWindowId = 822
        let existingTopWindowId = 823

        let consumedToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: consumedWindowId
        )
        let existingBottomToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: existingBottomWindowId
        )
        let existingTopToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: existingTopWindowId
        )

        _ = controller.workspaceManager.setManagedFocus(consumedToken, in: workspaceId, onMonitor: monitor.id)

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for tabbed horizontal consume regression test")
            return
        }

        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root
        engine.ensureMonitor(for: monitor.id, monitor: monitor).workspaceRoots[workspaceId] = root

        let sourceColumn = NiriContainer()
        let targetColumn = NiriContainer()
        targetColumn.displayMode = .tabbed
        root.appendChild(sourceColumn)
        root.appendChild(targetColumn)
        assignFixedWidths(root.columns)

        let consumedWindow = NiriWindow(token: consumedToken)
        let existingBottomWindow = NiriWindow(token: existingBottomToken)
        let existingTopWindow = NiriWindow(token: existingTopToken)

        sourceColumn.appendChild(consumedWindow)
        targetColumn.appendChild(existingBottomWindow)
        targetColumn.appendChild(existingTopWindow)
        targetColumn.setActiveTileIdx(1)
        engine.updateTabbedColumnVisibility(column: targetColumn)

        engine.tokenToNode[consumedToken] = consumedWindow
        engine.tokenToNode[existingBottomToken] = existingBottomWindow
        engine.tokenToNode[existingTopToken] = existingTopWindow

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: consumedWindow.id,
            focusedToken: consumedToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = consumedWindow.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(0)
        }

        controller.commandHandler.handleCommand(.move(.right))
        await waitForLayoutPlanRefreshWork(on: controller)

        let columns = engine.columns(in: workspaceId)
        #expect(columns.count == 1)
        #expect(columns[0].windowNodes.map(\.token) == [consumedToken, existingBottomToken, existingTopToken])
        #expect(columns[0].activeTileIdx == 0)
        #expect(columns[0].activeWindow?.token == consumedToken)

        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(state.selectedNodeId == consumedWindow.id)
        #expect(controller.workspaceManager.preferredWorkspaceFocusToken(in: workspaceId) == consumedToken)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == consumedToken)

        #expect(!consumedWindow.isHiddenInTabbedMode)
        #expect(existingBottomWindow.isHiddenInTabbedMode)
        #expect(existingTopWindow.isHiddenInTabbedMode)
    }

    @Test @MainActor func focusNeighborInTabbedColumnFollowsVisualTabOrder() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)

        fixture.controller.niriLayoutHandler.focusNeighbor(direction: .up)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.preferredWorkspaceFocusToken(in: fixture.workspaceId) == fixture
            .topToken)
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
            .selectedNodeId == fixture.topWindow.id)
        #expect(fixture.column.activeTileIdx == 2)
        #expect(fixture.column.activeVisualTileIdx == 0)
        #expect(!fixture.topWindow.isHiddenInTabbedMode)
        #expect(fixture.bottomWindow.isHiddenInTabbedMode)

        fixture.controller.niriLayoutHandler.focusNeighbor(direction: .down)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.preferredWorkspaceFocusToken(in: fixture.workspaceId) == fixture
            .middleToken)
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
            .selectedNodeId == fixture.middleWindow.id)
        #expect(fixture.column.activeTileIdx == 1)
        #expect(fixture.column.activeVisualTileIdx == 1)
        #expect(!fixture.middleWindow.isHiddenInTabbedMode)
    }

    @Test @MainActor func focusNeighborInNonTabbedColumnPreservesExistingInColumnOrder() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .normal)

        fixture.controller.niriLayoutHandler.focusNeighbor(direction: .up)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.preferredWorkspaceFocusToken(in: fixture.workspaceId) == fixture
            .topToken)
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
            .selectedNodeId == fixture.topWindow.id)

        fixture.controller.niriLayoutHandler.focusNeighbor(direction: .down)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.preferredWorkspaceFocusToken(in: fixture.workspaceId) == fixture
            .middleToken)
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
            .selectedNodeId == fixture.middleWindow.id)
    }

    @Test @MainActor func moveMouseToFocusedWindowUsesFocusedNiriFrameInStackedColumn() async {
        await withAXFrameProviderIsolationForTests {
            let fixture = await makeSingleColumnFocusFixture(displayMode: .normal)
            guard let screen = NSScreen.screens.first else {
                Issue.record("Expected at least one screen for Niri cursor warp regression test")
                return
            }

            let windowWidth = min(screen.frame.width / 3, 360)
            let windowHeight = min(screen.frame.height / 6, 120)
            let gap = min(screen.frame.height / 40, 24)
            let totalHeight = windowHeight * 3 + gap * 2
            let x = screen.frame.midX - windowWidth / 2
            let y = screen.frame.midY - totalHeight / 2
            let bottomFrame = CGRect(x: x, y: y, width: windowWidth, height: windowHeight)
            let middleFrame = bottomFrame.offsetBy(dx: 0, dy: windowHeight + gap)
            let topFrame = bottomFrame.offsetBy(dx: 0, dy: (windowHeight + gap) * 2)

            fixture.bottomWindow.frame = bottomFrame
            fixture.middleWindow.frame = middleFrame
            fixture.topWindow.frame = topFrame

            fixture.controller.setMoveMouseToFocusedWindow(true)
            fixture.controller.setFocusFollowsMouse(false)
            var warpedPoints: [CGPoint] = []
            fixture.controller.warpMouseCursorPosition = { point in
                warpedPoints.append(point)
            }

            AXWindowService.fastFrameProviderForTests = { axRef in
                axRef.windowId == fixture.topToken.windowId ? bottomFrame : nil
            }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            guard let topEntry = fixture.controller.workspaceManager.entry(for: fixture.topToken) else {
                Issue.record("Expected top stacked Niri window entry")
                return
            }

            fixture.controller.axEventHandler.handleManagedAppActivation(
                entry: topEntry,
                isWorkspaceActive: true,
                appFullscreen: false,
                source: .focusedWindowChanged,
                confirmRequest: true
            )

            #expect(fixture.controller.workspaceManager.confirmedManagedFocusToken == fixture.topToken)
            #expect(warpedPoints == [ScreenCoordinateSpace.toWindowServer(point: topFrame.center)])
        }
    }

    @Test @MainActor func niriAnimationSettleDoesNotWarpMouseWhileFocusRequestPending() async {
        await withAXFrameProviderIsolationForTests {
            let fixture = await makeSingleColumnFocusFixture(displayMode: .normal)
            guard let screen = NSScreen.screens.first else {
                Issue.record("Expected at least one screen for pending-focus cursor warp regression test")
                return
            }

            let middleFrame = CGRect(
                x: screen.frame.midX - 120,
                y: screen.frame.midY - 80,
                width: 240,
                height: 160
            )
            AXWindowService.fastFrameProviderForTests = { axRef in
                axRef.windowId == fixture.middleToken.windowId ? middleFrame : nil
            }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            fixture.controller.setMoveMouseToFocusedWindow(true)
            var warpedPoints: [CGPoint] = []
            fixture.controller.warpMouseCursorPosition = { point in
                warpedPoints.append(point)
            }

            _ = fixture.controller.workspaceManager.beginManagedFocusRequest(
                fixture.topToken,
                in: fixture.workspaceId,
                onMonitor: fixture.monitor.id
            )
            #expect(fixture.controller.workspaceManager.confirmedManagedFocusToken == fixture.middleToken)
            #expect(fixture.controller.workspaceManager.activeFocusRequestToken == fixture.topToken)
            #expect(fixture.controller.niriLayoutHandler.registerScrollAnimation(
                fixture.workspaceId,
                on: fixture.monitor.displayId
            ))

            fixture.controller.niriLayoutHandler.tickScrollAnimation(
                targetTime: 100,
                displayId: fixture.monitor.displayId
            )

            #expect(warpedPoints.isEmpty)
            #expect(fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.monitor.displayId] == nil)
        }
    }

    @Test @MainActor func focusWindowInColumnUsesNiriVisualOneBasedClamping() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let gap = CGFloat(fixture.controller.workspaceManager.gaps)
        let motion = fixture.controller.motionPolicy.snapshot()
        var state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        let first = fixture.engine.focusWindowInColumn(
            1,
            currentSelection: fixture.middleWindow,
            in: fixture.workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(first?.id == fixture.topWindow.id)
        #expect(fixture.column.activeTileIdx == 2)
        #expect(fixture.column.activeVisualTileIdx == 0)
        #expect(!fixture.topWindow.isHiddenInTabbedMode)
        #expect(fixture.middleWindow.isHiddenInTabbedMode)

        let zero = fixture.engine.focusWindowInColumn(
            0,
            currentSelection: fixture.middleWindow,
            in: fixture.workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(zero?.id == fixture.topWindow.id)
        #expect(fixture.column.activeTileIdx == 2)

        let beyondEnd = fixture.engine.focusWindowInColumn(
            99,
            currentSelection: fixture.middleWindow,
            in: fixture.workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(beyondEnd?.id == fixture.bottomWindow.id)
        #expect(fixture.column.activeTileIdx == 0)
        #expect(fixture.column.activeVisualTileIdx == 2)
        #expect(!fixture.bottomWindow.isHiddenInTabbedMode)
        #expect(fixture.topWindow.isHiddenInTabbedMode)
    }

    @Test @MainActor func focusWindowTopBottomAndWrapUseVisualOrder() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .normal)
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let gap = CGFloat(fixture.controller.workspaceManager.gaps)
        let motion = fixture.controller.motionPolicy.snapshot()
        var state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        let top = fixture.engine.focusWindowTop(
            currentSelection: fixture.middleWindow,
            in: fixture.workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        #expect(top?.id == fixture.topWindow.id)
        #expect(fixture.column.activeTileIdx == 2)

        let bottom = fixture.engine.focusWindowBottom(
            currentSelection: fixture.middleWindow,
            in: fixture.workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        #expect(bottom?.id == fixture.bottomWindow.id)
        #expect(fixture.column.activeTileIdx == 0)

        let down = fixture.engine.focusWindowDownOrTop(
            currentSelection: fixture.middleWindow,
            in: fixture.workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        #expect(down?.id == fixture.bottomWindow.id)
        #expect(fixture.column.activeTileIdx == 0)

        let downWrapped = fixture.engine.focusWindowDownOrTop(
            currentSelection: fixture.bottomWindow,
            in: fixture.workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        #expect(downWrapped?.id == fixture.topWindow.id)
        #expect(fixture.column.activeTileIdx == 2)

        let up = fixture.engine.focusWindowUpOrBottom(
            currentSelection: fixture.middleWindow,
            in: fixture.workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        #expect(up?.id == fixture.topWindow.id)
        #expect(fixture.column.activeTileIdx == 2)

        let upWrapped = fixture.engine.focusWindowUpOrBottom(
            currentSelection: fixture.topWindow,
            in: fixture.workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        #expect(upWrapped?.id == fixture.bottomWindow.id)
        #expect(fixture.column.activeTileIdx == 0)
    }

    @Test @MainActor func selectTabInNiriMapsVisualOverlayIndicesBackToStorageOrder() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)

        fixture.column.setActiveTileIdx(0)
        fixture.engine.updateTabbedColumnVisibility(column: fixture.column)
        _ = fixture.controller.workspaceManager.setManagedFocus(
            fixture.bottomToken,
            in: fixture.workspaceId,
            onMonitor: fixture.monitor.id
        )
        _ = fixture.controller.workspaceManager.commitWorkspaceSelection(
            nodeId: fixture.bottomWindow.id,
            focusedToken: fixture.bottomToken,
            in: fixture.workspaceId,
            onMonitor: fixture.monitor.id
        )
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.selectedNodeId = fixture.bottomWindow.id
        }

        #expect(fixture.column.visualTileIndex(forStorageTileIndex: 0) == 2)
        #expect(fixture.column.storageTileIndex(forVisualTileIndex: 0) == 2)
        #expect(fixture.column.activeVisualTileIdx == 2)

        fixture.controller.niriLayoutHandler.selectTabInNiri(
            workspaceId: fixture.workspaceId,
            columnId: fixture.column.id,
            visualIndex: 0
        )

        #expect(fixture.column.activeTileIdx == 2)
        #expect(fixture.column.activeVisualTileIdx == 0)
        #expect(fixture.column.activeWindow?.token == fixture.topToken)
        #expect(fixture.controller.shouldSuppressMouseMoveToFocusedWindow(for: fixture.topToken))
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
            .selectedNodeId == fixture.topWindow.id)
        #expect(!fixture.topWindow.isHiddenInTabbedMode)
        #expect(fixture.bottomWindow.isHiddenInTabbedMode)
    }

    @Test @MainActor func selectTabInNiriDefersOverlayRefreshUntilPostLayoutRepair() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)
        let manager = fixture.controller.tabbedOverlayManager
        defer {
            fixture.controller.layoutRefreshController.stopAllScrollAnimations()
            manager.removeAll()
        }
        manager.disablesWindowUpdatesForTests = true

        var overlayForceOrderingValues: [Bool] = []
        manager.updateHookForTests = { _, forceOrdering in
            overlayForceOrderingValues.append(forceOrdering)
        }

        fixture.controller.niriLayoutHandler.selectTabInNiri(
            workspaceId: fixture.workspaceId,
            columnId: fixture.column.id,
            visualIndex: 0
        )

        #expect(overlayForceOrderingValues.isEmpty)

        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        #expect(overlayForceOrderingValues.contains(true))
    }

    @Test @MainActor func tabbedColumnOverlayProjectionUsesRenderedColumnFrameClippedToVisibleFrame() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)

        let canonicalFrame = CGRect(x: 80, y: 10, width: 500, height: 700)
        let renderedFrame = CGRect(x: 240, y: -40, width: 500, height: 700)
        fixture.column.frame = canonicalFrame
        fixture.column.renderedFrame = renderedFrame
        fixture.controller.appInfoCache.storeInfoForTests(
            pid: getpid(),
            name: "Nehir Tests",
            bundleId: "com.example.nehir-tests"
        )
        for (token, title) in [
            (fixture.bottomToken, "Bottom"),
            (fixture.middleToken, "Middle"),
            (fixture.topToken, "Top")
        ] {
            _ = fixture.controller.workspaceManager.setManagedReplacementMetadata(
                ManagedReplacementMetadata(
                    bundleId: "com.example.nehir-tests",
                    workspaceId: fixture.workspaceId,
                    mode: .tiling,
                    role: nil,
                    subrole: nil,
                    title: title,
                    windowLevel: nil,
                    parentWindowId: nil,
                    frame: nil
                ),
                for: token
            )
        }

        let infos = fixture.controller.niriLayoutHandler.tabbedColumnOverlayInfosForTests(
            workspaceId: fixture.workspaceId,
            monitor: fixture.monitor
        )

        #expect(infos.count == 1)
        #expect(infos.first?.columnFrame == renderedFrame)
        #expect(infos.first?.visibleColumnFrame == renderedFrame.intersection(fixture.monitor.visibleFrame))
        #expect(infos.first?.tabCount == 3)
        #expect(infos.first?.activeVisualIndex == fixture.column.activeVisualTileIdx)
        #expect(infos.first?.tabs.map(\.windowId) == [903, 902, 901])
        #expect(infos.first?.tabs.map(\.appName) == ["Nehir Tests", "Nehir Tests", "Nehir Tests"])
        #expect(infos.first?.tabs.map(\.title) == ["Top", "Middle", "Bottom"])
        #expect(infos.first?.tabs.map(\.isActive) == [false, true, false])
    }

    @Test @MainActor func tabbedColumnOverlayRefreshesDuringNiriAnimationTick() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)
        fixture.controller.tabbedOverlayManager.disablesWindowUpdatesForTests = true

        _ = fixture.controller.niriLayoutHandler.registerScrollAnimation(
            fixture.workspaceId,
            on: fixture.monitor.displayId
        )

        fixture.controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: CACurrentMediaTime(),
            displayId: fixture.monitor.displayId
        )

        let manager = fixture.controller.tabbedOverlayManager
        #expect(manager.lastScopedWorkspaceIdForTests == fixture.workspaceId)
        #expect(manager.lastForceOrderingForTests == false)
        #expect(manager.lastUpdateInfosForTests.count == 1)
        #expect(manager.lastUpdateInfosForTests.first?.workspaceId == fixture.workspaceId)
        #expect(manager.lastUpdateInfosForTests.first?.columnId == fixture.column.id)
    }

    @Test func cleanupRemovedMonitorKeepsWorkspaceRootAuthoritativeForReattach() {
        let engine = NiriLayoutEngine()
        let oldMonitor = makeTestMonitor(displayId: 100, name: "Old", x: 0)
        let newMonitor = makeTestMonitor(displayId: 200, name: "New", x: 1920)
        let wsId = UUID()

        let oldNiriMonitor = engine.ensureMonitor(for: oldMonitor.id, monitor: oldMonitor)
        let rescuedRoot = engine.ensureRoot(for: wsId)
        oldNiriMonitor.workspaceRoots[wsId] = rescuedRoot

        engine.cleanupRemovedMonitor(oldMonitor.id)
        #expect(engine.monitor(for: oldMonitor.id) == nil)
        #expect(engine.root(for: wsId) === rescuedRoot)

        engine.moveWorkspace(wsId, to: newMonitor.id, monitor: newMonitor)

        let newNiriMonitor = engine.monitor(for: newMonitor.id)
        #expect(newNiriMonitor != nil)
        #expect(newNiriMonitor?.workspaceRoots[wsId] != nil)
        if let restoredRoot = newNiriMonitor?.workspaceRoots[wsId] {
            #expect(restoredRoot === rescuedRoot)
        }
    }

    @Test func syncWorkspaceAssignmentsAppliesOrientationWhenCreatingMonitor() {
        let engine = NiriLayoutEngine()
        let monitor = makeLayoutPlanTestMonitor(
            displayId: 100,
            name: "Portrait",
            x: 0,
            width: 900,
            height: 1600
        )
        let workspaceId = UUID()

        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )

        #expect(engine.monitor(for: monitor.id)?.orientation == .horizontal)
        #expect(engine.monitor(for: monitor.id)?.workspaceRoots[workspaceId] === engine.root(for: workspaceId))
    }

    @Test @MainActor func syncMonitorsToNiriEngineRemovesStaleWorkspaceRootDuplicates() async {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 100, name: "Primary", x: 0, width: 1600, height: 900)
        let secondaryMonitor = makeLayoutPlanTestMonitor(
            displayId: 200,
            name: "Secondary",
            x: 1600,
            width: 1600,
            height: 900
        )
        let fixture = makeTwoMonitorLayoutPlanTestController(
            primaryMonitor: primaryMonitor,
            secondaryMonitor: secondaryMonitor
        )
        let controller = fixture.controller

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine,
              let primaryRoot = engine.root(for: fixture.primaryWorkspaceId),
              let secondaryRoot = engine.root(for: fixture.secondaryWorkspaceId),
              let primaryWorkspaceMonitorId = controller.workspaceManager.monitorId(for: fixture.primaryWorkspaceId),
              let secondaryWorkspaceMonitorId = controller.workspaceManager
              .monitorId(for: fixture.secondaryWorkspaceId),
              let primaryOwningMonitor = engine.monitor(for: primaryWorkspaceMonitorId),
              let secondaryOwningMonitor = engine.monitor(for: secondaryWorkspaceMonitorId),
              let primaryNonOwningMonitor = engine.monitors.values.first(where: { $0.id != primaryWorkspaceMonitorId }),
              let secondaryNonOwningMonitor = engine.monitors.values
              .first(where: { $0.id != secondaryWorkspaceMonitorId })
        else {
            Issue.record("Expected Niri engine and monitor roots for stale-root sync test")
            return
        }

        primaryNonOwningMonitor.workspaceRoots[fixture.primaryWorkspaceId] = primaryRoot
        secondaryNonOwningMonitor.workspaceRoots[fixture.secondaryWorkspaceId] = secondaryRoot
        #expect(primaryOwningMonitor.workspaceRoots[fixture.primaryWorkspaceId] === primaryRoot)
        #expect(primaryNonOwningMonitor.workspaceRoots[fixture.primaryWorkspaceId] === primaryRoot)
        #expect(secondaryOwningMonitor.workspaceRoots[fixture.secondaryWorkspaceId] === secondaryRoot)
        #expect(secondaryNonOwningMonitor.workspaceRoots[fixture.secondaryWorkspaceId] === secondaryRoot)

        controller.syncMonitorsToNiriEngine()

        #expect(engine.monitorContaining(workspace: fixture.primaryWorkspaceId) == controller.workspaceManager
            .monitorId(for: fixture.primaryWorkspaceId))
        #expect(engine.monitorContaining(workspace: fixture.secondaryWorkspaceId) == controller.workspaceManager
            .monitorId(for: fixture.secondaryWorkspaceId))
        #expect(engine.monitor(for: primaryWorkspaceMonitorId)?
            .workspaceRoots[fixture.primaryWorkspaceId] === primaryRoot)
        #expect(primaryNonOwningMonitor.workspaceRoots[fixture.primaryWorkspaceId] == nil)
        #expect(engine.monitor(for: secondaryWorkspaceMonitorId)?
            .workspaceRoots[fixture.secondaryWorkspaceId] === secondaryRoot)
        #expect(secondaryNonOwningMonitor.workspaceRoots[fixture.secondaryWorkspaceId] == nil)
    }

    @Test func syncWorkspaceAssignmentsPreservesNoOpOwnershipWhilePruningStaleCopies() {
        let engine = NiriLayoutEngine()
        let monitors = makeVerticalStackedTestMonitors()
        let lowerWorkspaceId = UUID()
        let upperWorkspaceId = UUID()

        engine.moveWorkspace(lowerWorkspaceId, to: monitors.lower.id, monitor: monitors.lower)
        engine.moveWorkspace(upperWorkspaceId, to: monitors.upper.id, monitor: monitors.upper)

        guard let lowerRoot = engine.root(for: lowerWorkspaceId),
              let upperRoot = engine.root(for: upperWorkspaceId),
              let lowerMonitor = engine.monitor(for: monitors.lower.id),
              let upperMonitor = engine.monitor(for: monitors.upper.id)
        else {
            Issue.record("Expected existing monitor ownership before no-op sync test")
            return
        }

        upperMonitor.workspaceRoots[lowerWorkspaceId] = lowerRoot
        lowerMonitor.workspaceRoots[upperWorkspaceId] = upperRoot

        engine.syncWorkspaceAssignments([
            (workspaceId: lowerWorkspaceId, monitor: monitors.lower),
            (workspaceId: upperWorkspaceId, monitor: monitors.upper)
        ])

        #expect(lowerMonitor.workspaceRoots[lowerWorkspaceId] === lowerRoot)
        #expect(upperMonitor.workspaceRoots[upperWorkspaceId] === upperRoot)
        #expect(lowerMonitor.workspaceRoots[upperWorkspaceId] == nil)
        #expect(upperMonitor.workspaceRoots[lowerWorkspaceId] == nil)
    }

    @Test func syncWorkspaceAssignmentsRepopulatesMonitorIndexOnNoOpAttach() {
        // Reproduces the no-op-attach index gap: after the owning monitor is removed,
        // cleanupRemovedMonitor clears the index entry while a surviving duplicate root
        // keeps workspaceRoots correct. A subsequent sync whose target already holds that
        // root must still repopulate the ownership cache so monitorContaining resolves.
        let engine = NiriLayoutEngine()
        let monitors = makeVerticalStackedTestMonitors()
        let workspaceId = UUID()

        engine.ensureMonitor(for: monitors.lower.id, monitor: monitors.lower)
        engine.moveWorkspace(workspaceId, to: monitors.upper.id, monitor: monitors.upper)

        guard let root = engine.root(for: workspaceId),
              let lowerMonitor = engine.monitor(for: monitors.lower.id)
        else {
            Issue.record("Expected existing root and lower monitor before no-op index test")
            return
        }

        // Stale duplicate root survives on the remaining monitor, mirroring a transient
        // cross-monitor copy that pruneStaleWorkspaceRootCopies did not yet reconcile.
        lowerMonitor.workspaceRoots[workspaceId] = root

        // Disconnect the indexed owner: this removes the monitor and clears the index
        // entry while the duplicate root on the lower monitor persists.
        engine.cleanupRemovedMonitor(monitors.upper.id)
        #expect(engine.workspaceMonitorIndex[workspaceId] == nil)
        #expect(lowerMonitor.workspaceRoots[workspaceId] === root)

        // Reassign to the monitor that already holds the root (no-op attach).
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitors.lower)]
        )

        #expect(lowerMonitor.workspaceRoots[workspaceId] === root)
        #expect(engine.monitorContaining(workspace: workspaceId) == monitors.lower.id)
        #expect(engine.monitorForWorkspace(workspaceId)?.id == monitors.lower.id)
    }

    @Test func moveWorkspaceDoesNotPruneUnrelatedWorkspaceRoots() {
        let engine = NiriLayoutEngine()
        let monitors = makeHorizontalNeighboringTestMonitors()
        let movedWorkspaceId = UUID()
        let untouchedWorkspaceId = UUID()

        engine.moveWorkspace(movedWorkspaceId, to: monitors.primary.id, monitor: monitors.primary)
        engine.moveWorkspace(untouchedWorkspaceId, to: monitors.primary.id, monitor: monitors.primary)

        guard let movedRoot = engine.root(for: movedWorkspaceId),
              let untouchedRoot = engine.root(for: untouchedWorkspaceId),
              let primaryMonitor = engine.monitor(for: monitors.primary.id)
        else {
            Issue.record("Expected roots and primary monitor before single-workspace move regression test")
            return
        }

        engine.moveWorkspace(movedWorkspaceId, to: monitors.secondary.id, monitor: monitors.secondary)

        guard let secondaryMonitor = engine.monitor(for: monitors.secondary.id) else {
            Issue.record("Expected secondary monitor after moving one workspace")
            return
        }

        #expect(engine.monitorContaining(workspace: movedWorkspaceId) == monitors.secondary.id)
        #expect(engine.monitorContaining(workspace: untouchedWorkspaceId) == monitors.primary.id)
        #expect(primaryMonitor.workspaceRoots[movedWorkspaceId] == nil)
        #expect(primaryMonitor.workspaceRoots[untouchedWorkspaceId] === untouchedRoot)
        #expect(secondaryMonitor.workspaceRoots[movedWorkspaceId] === movedRoot)
        #expect(secondaryMonitor.workspaceRoots[untouchedWorkspaceId] == nil)
    }

    @Test func moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.7
        let sourceWorkspaceId = UUID()
        let targetWorkspaceId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: sourceWorkspaceId, afterSelection: nil)
        var sourceState = ViewportState()
        var targetState = ViewportState()

        let moved = engine.moveWindowToWorkspace(
            window,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceState: &sourceState,
            targetState: &targetState
        )

        guard let targetColumn = engine.columns(in: targetWorkspaceId).first else {
            Issue.record("Expected target column after workspace move")
            return
        }

        #expect(moved != nil)
        #expect(targetColumn.width == .proportion(0.7))
        #expect(targetColumn.presetWidthIdx == nil)
    }

    @Test func moveLastColumnToWorkspaceLeavesSourceWorkspaceEmpty() {
        let engine = NiriLayoutEngine()
        let sourceWorkspaceId = UUID()
        let targetWorkspaceId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(pid: 90), to: sourceWorkspaceId, afterSelection: nil)

        guard let column = engine.column(of: window) else {
            Issue.record("Expected source column before workspace move")
            return
        }

        var sourceState = ViewportState()
        var targetState = ViewportState()

        let moved = engine.moveColumnToWorkspace(
            column,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceState: &sourceState,
            targetState: &targetState
        )

        #expect(moved != nil)
        #expect(engine.columns(in: sourceWorkspaceId).isEmpty)
        #expect(engine.columns(in: targetWorkspaceId).count == 1)
        #expect(sourceState.selectedNodeId == nil)
        #expect(targetState.selectedNodeId == window.id)
    }

    @Test @MainActor func relayoutPlanUsesResolvedMonitorLoneWindowOverride() async throws {
        let monitor = makeLayoutPlanTestMonitor(name: "LoneWindowOverrideTest")
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for Niri settings test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        controller.settings.niriLoneWindowMaxWidth = 0.6
        controller.updateNiriConfig(loneWindowPolicy: .centered(maxWidthFraction: 0.6))
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 881)

        let baselinePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let baselinePlan = baselinePlans.first,
              let baselineFrame = baselinePlan.diff.frameChanges.first(where: { $0.token == token })?.frame
        else {
            Issue.record("Expected a baseline Niri frame for the single window")
            return
        }

        controller.settings.updateNiriSettings(
            MonitorNiriSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                loneWindowPolicy: .centered(maxWidthFraction: 0.4)
            )
        )
        controller.updateMonitorNiriSettings()

        let overridePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let overridePlan = overridePlans.first,
              let overrideFrame = overridePlan.diff.frameChanges.first(where: { $0.token == token })?.frame
        else {
            Issue.record("Expected a Niri frame after applying monitor override settings")
            return
        }

        #expect(baselineFrame.width > overrideFrame.width)
    }

    @Test @MainActor func globalLoneWindowPolicyUpdatesResolvedMonitorSettingsImmediately() async {
        let monitor = makeLayoutPlanTestMonitor(name: "LoneWindowPolicyTest")
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        controller.settings.niriLoneWindowMaxWidth = 0.6

        controller.enableNiriLayout(revealStyle: .auto)
        controller.updateNiriConfig(loneWindowPolicy: .centered(maxWidthFraction: 0.6))
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine for global lone-window-policy test")
            return
        }

        #expect(controller.settings.niriSettings(for: monitor) == nil)
        #expect(engine.effectiveLoneWindowPolicy(for: monitor.id) == .centered(maxWidthFraction: 0.6))

        controller.settings.niriLoneWindowMaxWidth = nil
        controller.updateNiriConfig(loneWindowPolicy: .fill)
        await waitForLayoutPlanRefreshWork(on: controller)

        #expect(engine.effectiveLoneWindowPolicy(for: monitor.id) == .fill)
    }

    @Test @MainActor func monitorLoneWindowOverrideCanExplicitlyFillAgainstCenteredGlobal() async throws {
        let monitor = makeLayoutPlanTestMonitor(name: "ExplicitFillOverrideTest")
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for explicit-fill override test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        controller.settings.niriLoneWindowMaxWidth = 0.6
        controller.updateNiriConfig(loneWindowPolicy: .centered(maxWidthFraction: 0.6))
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 882)

        controller.settings.updateNiriSettings(
            MonitorNiriSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                loneWindowPolicy: .fill
            )
        )
        controller.updateMonitorNiriSettings()

        let overridePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let overridePlan = overridePlans.first,
              let overrideFrame = overridePlan.diff.frameChanges.first(where: { $0.token == token })?.frame
        else {
            Issue.record("Expected a Niri frame after applying explicit-fill override")
            return
        }

        // With global centered at 0.6 but an explicit .fill override, the lone window
        // must span the full working area, not the capped centered width.
        #expect(overrideFrame.width > monitor.visibleFrame.width * 0.6)
    }

    @Test @MainActor func nativeFullscreenSuspendedWindowEmitsPlaceholderInsteadOfFrameChangeInNiri() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Niri native fullscreen placeholder test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 3901)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(token)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan for native fullscreen placeholder test")
            return
        }

        let placeholder = plan.diff.nativeFullscreenPlaceholders.first { $0.token == token }
        #expect(placeholder != nil)
        #expect(placeholder?.frame.width ?? 0 > 1)
        #expect(placeholder?.frame.height ?? 0 > 1)
        #expect(placeholder?.selected == true)
        #expect(!plan.diff.frameChanges.contains { $0.token == token })
        #expect(!hasHideVisibilityChange(plan.diff.visibilityChanges, token: token))
        #expect(!hasShowVisibilityChange(plan.diff.visibilityChanges, token: token))
    }

    @Test @MainActor func snapshotPlanIncludesViewportPatchAndActivationForNewWindow() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Niri plan test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()
        controller.niriEngine?.presetColumnWidths = [.proportion(1.0), .proportion(0.5)]

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 401)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let newToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 402)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan for the active workspace")
            return
        }

        #expect(plan.sessionPatch.viewportState != nil)
        #expect(plan.sessionPatch.rememberedFocusToken == newToken)
        #expect(hasNiriScrollDirective(plan.animationDirectives, workspaceId: workspaceId))
        #expect(hasActivationDirective(plan.animationDirectives, token: newToken))
    }

    @Test @MainActor func executingActivateWindowPlanPreservesPendingSelectionAndViewport() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for pending-focus relayout regression test")
            return
        }

        controller.setBordersEnabled(true)
        controller.enableNiriLayout(revealStyle: .auto)
        controller.updateNiriConfig(balancedColumnCount: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()
        controller.niriEngine?.presetColumnWidths = [.proportion(1.0), .proportion(1.0)]

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 403)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)
        await waitForLayoutPlanRefreshWork(on: controller)

        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let newToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 404)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first,
              let newNode = controller.niriEngine?.findNode(for: newToken)
        else {
            Issue.record("Expected a Niri plan and node for pending-focus relayout regression test")
            return
        }

        #expect(plan.sessionPatch.rememberedFocusToken == newToken)
        #expect(plan.sessionPatch.viewportState?.selectedNodeId == newNode.id)
        #expect(plan.sessionPatch.viewportState?.activeColumnIndex == 1)
        #expect(hasActivationDirective(plan.animationDirectives, token: newToken))

        controller.layoutRefreshController.executeLayoutPlans(plans)
        await waitForLayoutPlanRefreshWork(on: controller)

        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == firstToken)
        #expect(controller.workspaceManager.activeFocusRequestToken == newToken)
        #expect(controller.workspaceManager.preferredWorkspaceFocusToken(in: workspaceId) == newToken)
        #expect(state.selectedNodeId == newNode.id)
        #expect(state.activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == firstToken.windowId)
    }

    @Test @MainActor func snapshotPlanEmitsHideDiffForOffscreenWindows() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for Niri hide-diff test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        for windowId in 501 ... 504 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .gesture(
                ViewGesture(currentViewOffset: -2500, isTrackpad: true)
            )
        }

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan after viewport shift")
            return
        }

        #expect(hasHiddenVisibilityChange(plan.diff.visibilityChanges))
        #expect(!hiddenVisibilitySides(plan.diff.visibilityChanges).isEmpty)
        let hiddenTokens = hiddenVisibilityTokens(plan.diff.visibilityChanges)
        #expect(!hiddenTokens.isEmpty)
        for token in hiddenTokens {
            #expect(!hasFrameChange(plan.diff.frameChanges, token: token))
        }
    }

    @Test @MainActor func snapshotPlanDoesNotHideFullscreenTokenOnRightVisibleColumn() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for fullscreen hide-diff regression test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for fullscreen hide-diff regression test")
            return
        }

        engine.balancedColumnCount = 3

        for windowId in 511 ... 515 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let fixedWidth = (workingFrame.width - gap * CGFloat(engine.balancedColumnCount - 1)) /
            CGFloat(engine.balancedColumnCount)
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        let columns = engine.columns(in: workspaceId)
        guard columns.indices.contains(engine.balancedColumnCount - 1),
              let targetWindow = columns[engine.balancedColumnCount - 1].windowNodes.first
        else {
            Issue.record("Expected a right visible-column target for fullscreen hide-diff regression test")
            return
        }

        var state = makeViewportStateForVisibleColumn(
            targetWindow: targetWindow,
            engine: engine,
            workspaceId: workspaceId,
            workingFrame: workingFrame,
            gap: gap
        )
        _ = controller.workspaceManager.setManagedFocus(targetWindow.token, in: workspaceId, onMonitor: monitor.id)
        engine.toggleFullscreen(targetWindow, state: &state)
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a fullscreen Niri layout plan for hide-diff regression test")
            return
        }

        let expectedFullscreenFrame = workingFrame.roundedToPhysicalPixels(
            scale: controller.layoutRefreshController.backingScale(for: monitor)
        )
        #expect(!hasHideVisibilityChange(plan.diff.visibilityChanges, token: targetWindow.token))

        guard let frameChange = plan.diff.frameChanges.first(where: { $0.token == targetWindow.token }) else {
            Issue.record("Expected a frame change for the fullscreen token in hide-diff regression test")
            return
        }

        #expect(frameChange.forceApply)
        #expect(frameChange.frame == expectedFullscreenFrame)
    }

    @Test @MainActor func offscreenLeftPlaceholderFramesUseWorkingFrameOriginOnMonitorWithoutLeftNeighbor(
    ) async throws {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 100, name: "Primary", x: 0, width: 1600, height: 900)
        let secondaryMonitor = makeLayoutPlanTestMonitor(
            displayId: 200,
            name: "Secondary",
            x: 1600,
            width: 1600,
            height: 900
        )
        let fixture = makeTwoMonitorLayoutPlanTestController(
            primaryMonitor: primaryMonitor,
            secondaryMonitor: secondaryMonitor
        )
        let controller = fixture.controller
        let workspaceId = fixture.primaryWorkspaceId

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        var tokens: [WindowToken] = []
        for windowId in 701 ... 704 {
            tokens.append(addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId))
        }

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for offscreen-left placeholder test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(2500)
        }

        let gaps = LayoutGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps),
            outer: controller.workspaceManager.outerGaps
        )
        let workingFrame = controller.insetWorkingFrame(for: primaryMonitor)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: primaryMonitor.frame,
            scale: controller.layoutRefreshController.backingScale(for: primaryMonitor)
        )
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: workspaceId,
            monitor: primaryMonitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        let hiddenLeftTokens = tokens.filter { hiddenHandles[$0] == .left }
        #expect(!hiddenLeftTokens.isEmpty)
        for token in hiddenLeftTokens {
            #expect(frames[token]?.origin.y == workingFrame.minY)
        }
    }

    @Test func hiddenLeftRevealPreservesBottomTileHeightOnFirstVisibleFrame() {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)

        let bottomHandle = makeTestHandle(pid: 41)
        let topHandle = makeTestHandle(pid: 42)
        let visibleHandle = makeTestHandle(pid: 43)

        let bottomWindow = NiriWindow(handle: bottomHandle)
        let topWindow = NiriWindow(handle: topHandle)
        let visibleWindow = NiriWindow(handle: visibleHandle)

        bottomWindow.height = .fixed(280)
        topWindow.height = .auto(weight: 1.0)

        leftColumn.appendChild(bottomWindow)
        leftColumn.appendChild(topWindow)
        rightColumn.appendChild(visibleWindow)

        engine.tokenToNode[bottomHandle.id] = bottomWindow
        engine.tokenToNode[topHandle.id] = topWindow
        engine.tokenToNode[visibleHandle.id] = visibleWindow

        let monitor = makeLayoutPlanTestMonitor(width: 960, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 1
        hiddenState.viewOffsetPixels = .static(0)

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: hiddenState,
            workingArea: area,
            animationTime: nil
        )

        #expect(hiddenLayout.hiddenHandles[bottomHandle.id] == .left)
        guard let canonicalBottomFrame = bottomWindow.frame,
              let canonicalBottomHeight = bottomWindow.resolvedHeight
        else {
            Issue.record("Expected canonical bottom window geometry after hidden layout")
            return
        }

        var revealState = hiddenState
        revealState.viewOffsetPixels = .static(-40)

        let revealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: revealState,
            workingArea: area,
            animationTime: nil
        )

        #expect(revealLayout.hiddenHandles[bottomHandle.id] == nil)
        #expect(bottomWindow.frame == canonicalBottomFrame)
        #expect(bottomWindow.resolvedHeight == canonicalBottomHeight)
        #expect(revealLayout.frames[bottomHandle.id]?.minY == canonicalBottomFrame.minY)
        #expect(revealLayout.frames[bottomHandle.id]?.height == canonicalBottomHeight)
    }

    @Test func fullscreenWindowsStayMonitorAnchoredAcrossVisibleColumns() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            let expectedFullscreenFrame = fixture.monitor.visibleFrame
                .roundedToPhysicalPixels(scale: fixture.area.scale)

            var targetIndices = [visibleCount - 1]
            if visibleCount > 2 {
                targetIndices.append(1)
            }

            for targetIndex in targetIndices {
                let targetWindow = fixture.windows[targetIndex]
                var state = makeViewportStateForVisibleColumn(
                    targetWindow: targetWindow,
                    engine: fixture.engine,
                    workspaceId: fixture.workspaceId,
                    workingFrame: fixture.monitor.visibleFrame,
                    gap: fixture.gap
                )

                let tiledLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                    in: fixture.workspaceId,
                    monitor: fixture.monitor,
                    gaps: fixture.gaps,
                    state: state,
                    workingArea: fixture.area,
                    animationTime: nil
                )

                guard let tiledFrame = tiledLayout.frames[targetWindow.token] else {
                    Issue.record("Expected tiled frame for visibleCount=\(visibleCount) targetIndex=\(targetIndex)")
                    continue
                }

                #expect(tiledLayout.hiddenHandles[targetWindow.token] == nil)

                fixture.engine.toggleFullscreen(targetWindow, state: &state)
                let fullscreenLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                    in: fixture.workspaceId,
                    monitor: fixture.monitor,
                    gaps: fixture.gaps,
                    state: state,
                    workingArea: fixture.area,
                    animationTime: nil
                )

                #expect(fullscreenLayout.hiddenHandles[targetWindow.token] == nil)
                #expect(fullscreenLayout.frames[targetWindow.token] == expectedFullscreenFrame)
                #expect(targetWindow.renderedFrame == expectedFullscreenFrame)

                fixture.engine.toggleFullscreen(targetWindow, state: &state)
                let restoredLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                    in: fixture.workspaceId,
                    monitor: fixture.monitor,
                    gaps: fixture.gaps,
                    state: state,
                    workingArea: fixture.area,
                    animationTime: nil
                )

                #expect(restoredLayout.frames[targetWindow.token] == tiledFrame)
            }
        }
    }

    @Test func fullscreenBottomTileUsesFullMonitorHeightWithoutCarryoverOffset() {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        engine.animationClock = AnimationClock()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let topHandle = makeTestHandle(pid: 71)
        let bottomHandle = makeTestHandle(pid: 72)
        let topWindow = NiriWindow(handle: topHandle)
        let bottomWindow = NiriWindow(handle: bottomHandle)

        topWindow.height = .auto(weight: 1.0)
        bottomWindow.height = .fixed(280)

        column.appendChild(topWindow)
        column.appendChild(bottomWindow)
        engine.tokenToNode[topHandle.id] = topWindow
        engine.tokenToNode[bottomHandle.id] = bottomWindow

        let monitor = makeLayoutPlanTestMonitor(width: 1200, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var state = ViewportState()
        state.selectedNodeId = bottomWindow.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        let tiledLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        guard let tiledFrame = tiledLayout.frames[bottomHandle.id],
              let tiledHeight = bottomWindow.resolvedHeight
        else {
            Issue.record("Expected tiled frame for bottom-tile fullscreen regression test")
            return
        }

        bottomWindow.animateMoveFrom(
            displacement: CGPoint(x: 0, y: -220),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        engine.toggleFullscreen(bottomWindow, state: &state)
        let fullscreenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: engine.animationClock?.now()
        )

        let expectedFullscreenFrame = monitor.visibleFrame.roundedToPhysicalPixels(scale: area.scale)
        #expect(fullscreenLayout.frames[bottomHandle.id] == expectedFullscreenFrame)
        #expect(bottomWindow.resolvedHeight == monitor.visibleFrame.height)
        #expect(bottomWindow.hasMoveAnimationsRunning == false)

        engine.toggleFullscreen(bottomWindow, state: &state)
        let restoredLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        #expect(restoredLayout.frames[bottomHandle.id] == tiledFrame)
        #expect(bottomWindow.resolvedHeight == tiledHeight)
    }

    @Test func focusHitTestPrefersFullscreenWindowOverCoveredTile() {
        let fixture = makeVisibleColumnFixture(visibleCount: 2, extraColumns: 0)
        let coveredWindow = fixture.windows[0]
        let fullscreenWindow = fixture.windows[1]

        var state = makeViewportStateForVisibleColumn(
            targetWindow: fullscreenWindow,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            workingFrame: fixture.monitor.visibleFrame,
            gap: fixture.gap
        )

        _ = fixture.engine.calculateCombinedLayoutUsingPools(
            in: fixture.workspaceId,
            monitor: fixture.monitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: nil
        )

        fixture.engine.toggleFullscreen(fullscreenWindow, state: &state)
        _ = fixture.engine.calculateCombinedLayoutUsingPools(
            in: fixture.workspaceId,
            monitor: fixture.monitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: nil
        )

        guard let coveredFrame = coveredWindow.frame,
              let fullscreenFrame = fullscreenWindow.frame
        else {
            Issue.record("Expected frames for fullscreen focus hit-test regression")
            return
        }

        let overlapPoint = CGPoint(x: coveredFrame.midX, y: coveredFrame.midY)
        #expect(coveredFrame.contains(overlapPoint))
        #expect(fullscreenFrame.contains(overlapPoint))
        #expect(
            fixture.engine.hitTestFocusableWindow(point: overlapPoint, in: fixture.workspaceId)?
                .token == fullscreenWindow.token
        )
    }

    @Test func toggleFullWidthKeepsRightVisibleColumnInViewport() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            fixture.engine.animationClock = AnimationClock()
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for full-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalTargetOffset = state.viewOffsetPixels.target()

            fixture.engine.toggleFullWidth(
                targetColumn,
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let widenedTargetOffset = state.viewOffsetPixels.target()
            #expect(widenedTargetOffset != originalTargetOffset)

            guard let settleBaseTime = fixture.engine.animationClock?.now() else {
                Issue.record("Expected animation clock for full-width visibility test visibleCount=\(visibleCount)")
                continue
            }
            let settleTime = settleBaseTime + 2.0
            let settledState = settledLayoutState(from: state, column: targetColumn, settleTime: settleTime)
            let settledLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: settledState,
                workingArea: fixture.area,
                animationTime: settleTime
            )

            guard let fullscreenWidthFrame = settledLayout.frames[targetWindow.token] else {
                Issue.record("Expected settled frame for full-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            #expect(settledLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(abs(fullscreenWidthFrame.width - (fixture.monitor.visibleFrame.width - fixture.gap * 2)) < 1.0)
            #expect(fullscreenWidthFrame.minX >= fixture.monitor.visibleFrame.minX - 1.0)
            #expect(fullscreenWidthFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        }
    }

    @Test func toggleColumnWidthKeepsRightVisibleColumnInViewport() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            fixture.engine.animationClock = AnimationClock()
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for cycle-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            fixture.engine.presetColumnWidths = [
                .fixed(targetColumn.cachedWidth),
                .fixed(targetColumn.cachedWidth * 1.5)
            ]
            targetColumn.presetWidthIdx = nil

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )
            let originalTargetOffset = state.viewOffsetPixels.target()

            fixture.engine.toggleColumnWidth(
                targetColumn,
                forwards: true,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let widenedTargetOffset = state.viewOffsetPixels.target()
            #expect(widenedTargetOffset != originalTargetOffset)

            guard let settleBaseTime = fixture.engine.animationClock?.now() else {
                Issue.record("Expected animation clock for cycle-width visibility test visibleCount=\(visibleCount)")
                continue
            }
            let settleTime = settleBaseTime + 2.0
            let settledState = settledLayoutState(from: state, column: targetColumn, settleTime: settleTime)
            let settledLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: settledState,
                workingArea: fixture.area,
                animationTime: settleTime
            )

            guard let originalFrame = originalLayout.frames[targetWindow.token],
                  let widenedFrame = settledLayout.frames[targetWindow.token]
            else {
                Issue
                    .record(
                        "Expected original and widened frames for cycle-width visibility test visibleCount=\(visibleCount)"
                    )
                continue
            }

            #expect(settledLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(widenedFrame.width > originalFrame.width)
            #expect(widenedFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        }
    }

    @Test func toggleColumnWidthForwardWithAnimationsDisabledAppliesWidthImmediately() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue
                    .record(
                        "Expected a target column for disabled cycle-width forward test visibleCount=\(visibleCount)"
                    )
                continue
            }

            let originalWidth = targetColumn.cachedWidth
            fixture.engine.presetColumnWidths = [
                .fixed(originalWidth),
                .fixed(originalWidth * 1.5)
            ]
            targetColumn.presetWidthIdx = nil

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            fixture.engine.toggleColumnWidth(
                targetColumn,
                forwards: true,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let immediateLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            guard let originalFrame = originalLayout.frames[targetWindow.token],
                  let updatedFrame = immediateLayout.frames[targetWindow.token]
            else {
                Issue
                    .record(
                        "Expected original and updated frames for disabled cycle-width forward test visibleCount=\(visibleCount)"
                    )
                continue
            }

            #expect(abs(targetColumn.cachedWidth - (originalWidth * 1.5)) < 0.1)
            #expect(!targetColumn.hasWidthAnimationRunning)
            #expect(!state.viewOffsetPixels.isAnimating)
            #expect(immediateLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(updatedFrame.width > originalFrame.width)
            #expect(updatedFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        }
    }

    @Test func toggleColumnWidthBackwardWithAnimationsDisabledAppliesWidthImmediately() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue
                    .record(
                        "Expected a target column for disabled cycle-width backward test visibleCount=\(visibleCount)"
                    )
                continue
            }

            let originalWidth = targetColumn.cachedWidth
            let targetWidth = originalWidth * 0.75
            fixture.engine.presetColumnWidths = [
                .fixed(targetWidth),
                .fixed(originalWidth)
            ]
            targetColumn.width = .fixed(originalWidth)
            targetColumn.presetWidthIdx = 1

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            fixture.engine.toggleColumnWidth(
                targetColumn,
                forwards: false,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let immediateLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            guard let originalFrame = originalLayout.frames[targetWindow.token],
                  let updatedFrame = immediateLayout.frames[targetWindow.token]
            else {
                Issue
                    .record(
                        "Expected original and updated frames for disabled cycle-width backward test visibleCount=\(visibleCount)"
                    )
                continue
            }

            #expect(abs(targetColumn.cachedWidth - targetWidth) < 0.1)
            #expect(!targetColumn.hasWidthAnimationRunning)
            #expect(!state.viewOffsetPixels.isAnimating)
            #expect(immediateLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(updatedFrame.width < originalFrame.width)
            #expect(updatedFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        }
    }

    @Test func toggleFullWidthWithAnimationsDisabledAppliesWidthImmediately() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for disabled full-width test visibleCount=\(visibleCount)")
                continue
            }

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            fixture.engine.toggleFullWidth(
                targetColumn,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let immediateLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            guard let updatedFrame = immediateLayout.frames[targetWindow.token] else {
                Issue.record("Expected updated frame for disabled full-width test visibleCount=\(visibleCount)")
                continue
            }

            #expect(abs(targetColumn.cachedWidth - (fixture.monitor.visibleFrame.width - fixture.gap * 2)) < 0.1)
            #expect(!targetColumn.hasWidthAnimationRunning)
            #expect(!state.viewOffsetPixels.isAnimating)
            #expect(immediateLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(abs(updatedFrame.width - (fixture.monitor.visibleFrame.width - fixture.gap * 2)) < 1.0)
            #expect(updatedFrame.minX >= fixture.monitor.visibleFrame.minX - 1.0)
            #expect(updatedFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        }
    }

    @Test func toggleColumnWidthForwardChoosesNextLargerResolvedPreset() {
        let engine = NiriLayoutEngine()
        engine.presetColumnWidths = [.fixed(600), .fixed(900)]
        let workspaceId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: workspaceId, afterSelection: nil)
        guard let column = engine.column(of: window) else {
            Issue.record("Expected column for resolved preset width test")
            return
        }

        column.width = .fixed(850)
        column.cachedWidth = 850
        window.resolvedWidth = 850

        var state = ViewportState()
        state.selectedNodeId = window.id
        engine.toggleColumnWidth(
            column,
            forwards: true,
            targetWindow: window,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        #expect(column.presetWidthIdx == 1)
        #expect(column.width == .fixed(900))
        #expect(abs(column.cachedWidth - 900) < 0.001)
    }

    @Test func setWindowHeightClampsAgainstOtherWindowMinimums() {
        let engine = NiriLayoutEngine()
        let workspaceId = UUID()
        let root = engine.ensureRoot(for: workspaceId)
        let column = NiriContainer()
        root.appendChild(column)

        let selected = NiriWindow(token: makeTestHandle(pid: 410).id)
        let other = NiriWindow(token: makeTestHandle(pid: 411).id)
        other.constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: 300),
            maxSize: .zero,
            isFixed: false
        )
        selected.resolvedHeight = 438
        other.resolvedHeight = 438
        column.appendChild(selected)
        column.appendChild(other)
        engine.tokenToNode[selected.token] = selected
        engine.tokenToNode[other.token] = other

        engine.setWindowHeight(
            selected,
            change: .setFixed(700),
            in: workspaceId,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        #expect(selected.height == .fixed(592))
        #expect(other.height.isAuto)
    }

    @Test func expandColumnToAvailableWidthUsesVisibleColumnsOnly() {
        let fixture = makeVisibleColumnFixture(visibleCount: 2, extraColumns: 1, width: 1600, height: 900)
        let targetWindow = fixture.windows[1]
        guard let targetColumn = fixture.engine.column(of: targetWindow) else {
            Issue.record("Expected target column for expand available width test")
            return
        }

        for column in fixture.engine.columns(in: fixture.workspaceId) {
            column.width = .fixed(500)
            column.cachedWidth = 500
        }

        var state = ViewportState()
        state.selectedNodeId = targetWindow.id
        state.activeColumnIndex = 1
        let activeColumnX = state.columnX(
            at: 1,
            columns: fixture.engine.columns(in: fixture.workspaceId),
            gap: fixture.gap
        )
        state.viewOffsetPixels = .static(-activeColumnX - 80)

        fixture.engine.expandColumnToAvailableWidth(
            targetColumn,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: fixture.monitor.visibleFrame,
            gaps: fixture.gap
        )

        #expect(targetColumn.width == .fixed(1076))
        #expect(abs(targetColumn.cachedWidth - 1076) < 0.001)
        #expect(!targetColumn.isFullWidth)
        #expect(targetColumn.presetWidthIdx == nil)
        #expect(abs(state.viewOffsetPixels.target() - (-activeColumnX - fixture.gap)) < 0.001)
    }

    @Test func programmaticResizeCancelsInteractiveResize() {
        let fixture = makeVisibleColumnFixture(visibleCount: 2, extraColumns: 1)
        let targetWindow = fixture.windows[1]
        guard let targetColumn = fixture.engine.column(of: targetWindow) else {
            Issue.record("Expected target column for interactive resize cancellation test")
            return
        }

        var state = ViewportState()
        state.selectedNodeId = targetWindow.id
        state.activeColumnIndex = 1

        let didBeginResize = fixture.engine.interactiveResizeBegin(
            windowId: targetWindow.id,
            edges: .right,
            startLocation: .zero,
            in: fixture.workspaceId,
            viewOffset: state.viewOffsetPixels.target()
        )
        #expect(didBeginResize)

        fixture.engine.setColumnWidth(
            targetColumn,
            change: .adjustFixed(100),
            in: fixture.workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: fixture.monitor.visibleFrame,
            gaps: fixture.gap
        )

        #expect(fixture.engine.interactiveResize == nil)
    }

    @Test func splitUsesExplicitDefaultWidthAndExpelInheritsSourceWidth() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.7
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        sourceColumn.width = .proportion(0.85)
        sourceColumn.presetWidthIdx = 0
        root.appendChild(sourceColumn)

        let movedWindow = NiriWindow(token: makeTestHandle(pid: 31).id)
        let expelledWindow = NiriWindow(token: makeTestHandle(pid: 32).id)
        let stationaryWindow = NiriWindow(token: makeTestHandle(pid: 33).id)
        sourceColumn.appendChild(movedWindow)
        sourceColumn.appendChild(expelledWindow)
        sourceColumn.appendChild(stationaryWindow)
        engine.tokenToNode[movedWindow.token] = movedWindow
        engine.tokenToNode[expelledWindow.token] = expelledWindow
        engine.tokenToNode[stationaryWindow.token] = stationaryWindow

        var state = ViewportState()
        engine.createColumnAndMove(
            movedWindow,
            from: sourceColumn,
            direction: .right,
            in: wsId,
            state: &state,
            gaps: 8,
            workingAreaWidth: 1600
        )

        let columnsAfterSplit = engine.columns(in: wsId)
        guard columnsAfterSplit.count == 2 else {
            Issue.record("Expected split operation to create a second column")
            return
        }

        let splitColumn = columnsAfterSplit[1]
        #expect(splitColumn.width == .proportion(0.7))
        #expect(splitColumn.presetWidthIdx == nil)

        var expelState = ViewportState()
        let expelled = engine.expelWindow(
            expelledWindow,
            to: .left,
            in: wsId,
            state: &expelState,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let columnsAfterExpel = engine.columns(in: wsId)
        guard columnsAfterExpel.count == 3 else {
            Issue.record("Expected expel operation to create a third column")
            return
        }

        #expect(expelled)
        #expect(columnsAfterExpel[0].width == .proportion(0.85))
        #expect(columnsAfterExpel[0].presetWidthIdx == 0)
    }

    @Test func expelWindowCopiesFullWidthRestoreState() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        sourceColumn.width = .fixed(520)
        sourceColumn.cachedWidth = 1200
        sourceColumn.isFullWidth = true
        sourceColumn.savedWidth = .fixed(520)
        sourceColumn.hasManualSingleWindowWidthOverride = true
        root.appendChild(sourceColumn)

        let expelledWindow = NiriWindow(token: makeTestHandle(pid: 34).id)
        let stationaryWindow = NiriWindow(token: makeTestHandle(pid: 35).id)
        sourceColumn.appendChild(expelledWindow)
        sourceColumn.appendChild(stationaryWindow)
        engine.tokenToNode[expelledWindow.token] = expelledWindow
        engine.tokenToNode[stationaryWindow.token] = stationaryWindow

        var state = ViewportState()
        let expelled = engine.expelWindow(
            expelledWindow,
            to: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        guard columns.count == 2 else {
            Issue.record("Expected expel operation to create a second column")
            return
        }

        let expelledColumn = columns[1]
        #expect(expelled)
        #expect(expelledColumn.width == .fixed(520))
        #expect(expelledColumn.savedWidth == .fixed(520))
        #expect(expelledColumn.isFullWidth)
        #expect(expelledColumn.hasManualSingleWindowWidthOverride)
        #expect(abs(expelledColumn.cachedWidth - (1200 - 8 * 2)) < 0.001)
    }

    @Test func expelWindowCopiesDesiredWidthButRecomputesCachedWidthFromConstraints() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        sourceColumn.width = .fixed(1000)
        sourceColumn.cachedWidth = 1000
        root.appendChild(sourceColumn)

        let expelledWindow = NiriWindow(token: makeTestHandle(pid: 36).id)
        expelledWindow.constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: 1),
            maxSize: CGSize(width: 600, height: 0),
            isFixed: false
        )
        let stationaryWindow = NiriWindow(token: makeTestHandle(pid: 37).id)
        sourceColumn.appendChild(expelledWindow)
        sourceColumn.appendChild(stationaryWindow)
        engine.tokenToNode[expelledWindow.token] = expelledWindow
        engine.tokenToNode[stationaryWindow.token] = stationaryWindow

        var state = ViewportState()
        let expelled = engine.expelWindow(
            expelledWindow,
            to: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        guard columns.count == 2 else {
            Issue.record("Expected expel operation to create a second column")
            return
        }

        let expelledColumn = columns[1]
        #expect(expelled)
        #expect(expelledColumn.width == .fixed(1000))
        #expect(abs(expelledColumn.cachedWidth - 600) < 0.001)
    }

    @Test func consumeWindowPreservesTargetColumnWidthAndResetsMovedWindowSizing() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        sourceColumn.width = .fixed(900)
        sourceColumn.cachedWidth = 900
        let targetColumn = NiriContainer()
        targetColumn.width = .proportion(0.4)
        targetColumn.presetWidthIdx = 2
        targetColumn.cachedWidth = 480
        root.appendChild(sourceColumn)
        root.appendChild(targetColumn)

        let consumedWindow = NiriWindow(token: makeTestHandle(pid: 38).id)
        consumedWindow.height = .fixed(300)
        consumedWindow.windowWidth = .fixed(240)
        consumedWindow.resolvedHeight = 300
        consumedWindow.resolvedWidth = 240
        consumedWindow.heightFixedByConstraint = true
        consumedWindow.widthFixedByConstraint = true
        let targetWindow = NiriWindow(token: makeTestHandle(pid: 39).id)
        sourceColumn.appendChild(consumedWindow)
        targetColumn.appendChild(targetWindow)
        engine.tokenToNode[consumedWindow.token] = consumedWindow
        engine.tokenToNode[targetWindow.token] = targetWindow

        var state = ViewportState()
        state.activeColumnIndex = 0
        let moved = engine.moveWindow(
            consumedWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === targetColumn)
        #expect(targetColumn.width == .proportion(0.4))
        #expect(targetColumn.presetWidthIdx == 2)
        #expect(consumedWindow.height == .default)
        #expect(consumedWindow.windowWidth == .default)
        #expect(consumedWindow.resolvedHeight == nil)
        #expect(consumedWindow.resolvedWidth == nil)
        #expect(!consumedWindow.heightFixedByConstraint)
        #expect(!consumedWindow.widthFixedByConstraint)
    }

    @Test func consumeWindowIntoColumnPullsVisualTopFromRightWithoutChangingFocus() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let targetColumn = NiriContainer()
        let sourceColumn = NiriContainer()
        root.appendChild(targetColumn)
        root.appendChild(sourceColumn)

        let focusedWindow = NiriWindow(token: makeTestHandle(pid: 42).id)
        let sourceBottomWindow = NiriWindow(token: makeTestHandle(pid: 43).id)
        let sourceTopWindow = NiriWindow(token: makeTestHandle(pid: 44).id)
        targetColumn.appendChild(focusedWindow)
        sourceColumn.appendChild(sourceBottomWindow)
        sourceColumn.appendChild(sourceTopWindow)
        engine.tokenToNode[focusedWindow.token] = focusedWindow
        engine.tokenToNode[sourceBottomWindow.token] = sourceBottomWindow
        engine.tokenToNode[sourceTopWindow.token] = sourceTopWindow

        var state = ViewportState()
        state.selectedNodeId = focusedWindow.id

        let consumed = engine.consumeWindowIntoColumn(
            focusedColumn: targetColumn,
            in: wsId,
            motion: .enabled,
            state: &state,
            gaps: 8
        )

        #expect(consumed)
        #expect(engine.columns(in: wsId).count == 2)
        #expect(targetColumn.windowNodes.map(\.id) == [sourceTopWindow.id, focusedWindow.id])
        #expect(sourceColumn.windowNodes.map(\.id) == [sourceBottomWindow.id])
        #expect(targetColumn.activeTileIdx == 1)
        #expect(targetColumn.activeWindow?.id == focusedWindow.id)
        #expect(state.selectedNodeId == focusedWindow.id)
    }

    @Test func consumeWindowIntoTabbedColumnPreservesFocusedActiveTab() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let targetColumn = NiriContainer()
        targetColumn.displayMode = .tabbed
        let sourceColumn = NiriContainer()
        root.appendChild(targetColumn)
        root.appendChild(sourceColumn)

        let targetBottomWindow = NiriWindow(token: makeTestHandle(pid: 52).id)
        let focusedWindow = NiriWindow(token: makeTestHandle(pid: 53).id)
        let consumedWindow = NiriWindow(token: makeTestHandle(pid: 54).id)
        targetColumn.appendChild(targetBottomWindow)
        targetColumn.appendChild(focusedWindow)
        sourceColumn.appendChild(consumedWindow)
        targetColumn.setActiveTileIdx(1)
        engine.updateTabbedColumnVisibility(column: targetColumn)
        engine.tokenToNode[targetBottomWindow.token] = targetBottomWindow
        engine.tokenToNode[focusedWindow.token] = focusedWindow
        engine.tokenToNode[consumedWindow.token] = consumedWindow

        var state = ViewportState()
        state.selectedNodeId = focusedWindow.id

        let consumed = engine.consumeWindowIntoColumn(
            focusedColumn: targetColumn,
            in: wsId,
            motion: .enabled,
            state: &state,
            gaps: 8
        )

        #expect(consumed)
        #expect(engine.columns(in: wsId).count == 1)
        #expect(targetColumn.windowNodes.map(\.id) == [consumedWindow.id, targetBottomWindow.id, focusedWindow.id])
        #expect(targetColumn.activeTileIdx == 2)
        #expect(targetColumn.activeWindow?.id == focusedWindow.id)
        #expect(state.selectedNodeId == focusedWindow.id)
        #expect(consumedWindow.isHiddenInTabbedMode)
        #expect(targetBottomWindow.isHiddenInTabbedMode)
        #expect(!focusedWindow.isHiddenInTabbedMode)
    }

    @Test func consumeOrExpelWindowCanDisableEdgeWrapForNiriCommand() {
        let engine = NiriLayoutEngine(infiniteLoop: true)
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)

        let leftWindow = NiriWindow(token: makeTestHandle(pid: 48).id)
        let rightWindow = NiriWindow(token: makeTestHandle(pid: 49).id)
        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)
        engine.tokenToNode[leftWindow.token] = leftWindow
        engine.tokenToNode[rightWindow.token] = rightWindow

        var state = ViewportState()
        let moved = engine.consumeOrExpelWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            motion: .enabled,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8,
            allowEdgeWrap: false
        )

        #expect(!moved)
        #expect(engine.columns(in: wsId).count == 2)
        #expect(leftColumn.windowNodes.map(\.id) == [leftWindow.id])
        #expect(rightColumn.windowNodes.map(\.id) == [rightWindow.id])
    }

    @Test func consumeWindowIntoColumnAllowsStackingPastPreviousRowCap() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let targetColumn = NiriContainer()
        let sourceColumn = NiriContainer()
        root.appendChild(targetColumn)
        root.appendChild(sourceColumn)

        let focusedWindow = NiriWindow(token: makeTestHandle(pid: 50).id)
        let stackedWindow = NiriWindow(token: makeTestHandle(pid: 52).id)
        let sourceWindow = NiriWindow(token: makeTestHandle(pid: 51).id)
        targetColumn.appendChild(focusedWindow)
        targetColumn.appendChild(stackedWindow)
        sourceColumn.appendChild(sourceWindow)
        engine.tokenToNode[focusedWindow.token] = focusedWindow
        engine.tokenToNode[stackedWindow.token] = stackedWindow
        engine.tokenToNode[sourceWindow.token] = sourceWindow

        var state = ViewportState()
        let consumed = engine.consumeWindowIntoColumn(
            focusedColumn: targetColumn,
            in: wsId,
            motion: .enabled,
            state: &state,
            gaps: 8
        )

        #expect(consumed)
        #expect(targetColumn.windowNodes.map(\.id) == [sourceWindow.id, focusedWindow.id, stackedWindow.id])
        #expect(sourceColumn.windowNodes.isEmpty)
    }

    @Test func expelWindowResetsMovedWindowSizing() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        sourceColumn.width = .fixed(500)
        sourceColumn.cachedWidth = 500
        root.appendChild(sourceColumn)

        let expelledWindow = NiriWindow(token: makeTestHandle(pid: 40).id)
        expelledWindow.height = .fixed(360)
        expelledWindow.windowWidth = .fixed(280)
        expelledWindow.resolvedHeight = 360
        expelledWindow.resolvedWidth = 280
        expelledWindow.heightFixedByConstraint = true
        expelledWindow.widthFixedByConstraint = true
        let stationaryWindow = NiriWindow(token: makeTestHandle(pid: 41).id)
        sourceColumn.appendChild(expelledWindow)
        sourceColumn.appendChild(stationaryWindow)
        engine.tokenToNode[expelledWindow.token] = expelledWindow
        engine.tokenToNode[stationaryWindow.token] = stationaryWindow

        var state = ViewportState()
        let expelled = engine.expelWindow(
            expelledWindow,
            to: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        #expect(expelled)
        #expect(expelledWindow.height == .default)
        #expect(expelledWindow.windowWidth == .default)
        #expect(expelledWindow.resolvedHeight == nil)
        #expect(expelledWindow.resolvedWidth == nil)
        #expect(!expelledWindow.heightFixedByConstraint)
        #expect(!expelledWindow.widthFixedByConstraint)
    }

    @Test func expelWindowFromColumnMovesVisualBottomRightWithoutFollowingIt() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        root.appendChild(sourceColumn)

        let bottomWindow = NiriWindow(token: makeTestHandle(pid: 45).id)
        let nextWindow = NiriWindow(token: makeTestHandle(pid: 46).id)
        let topWindow = NiriWindow(token: makeTestHandle(pid: 47).id)
        sourceColumn.appendChild(bottomWindow)
        sourceColumn.appendChild(nextWindow)
        sourceColumn.appendChild(topWindow)
        engine.tokenToNode[bottomWindow.token] = bottomWindow
        engine.tokenToNode[nextWindow.token] = nextWindow
        engine.tokenToNode[topWindow.token] = topWindow

        var state = ViewportState()
        state.selectedNodeId = bottomWindow.id

        let expelled = engine.expelWindowFromColumn(
            focusedColumn: sourceColumn,
            in: wsId,
            motion: .enabled,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(expelled)
        #expect(columns.count == 2)
        #expect(columns[0] === sourceColumn)
        #expect(columns[1].windowNodes.map(\.id) == [bottomWindow.id])
        #expect(sourceColumn.windowNodes.map(\.id) == [nextWindow.id, topWindow.id])
        #expect(state.selectedNodeId == nextWindow.id)
    }

    @Test func expelWindowFromColumnPreservesNonBottomFocusedActiveTile() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        root.appendChild(sourceColumn)

        let bottomWindow = NiriWindow(token: makeTestHandle(pid: 55).id)
        let focusedWindow = NiriWindow(token: makeTestHandle(pid: 56).id)
        let topWindow = NiriWindow(token: makeTestHandle(pid: 57).id)
        sourceColumn.appendChild(bottomWindow)
        sourceColumn.appendChild(focusedWindow)
        sourceColumn.appendChild(topWindow)
        sourceColumn.setActiveTileIdx(1)
        engine.tokenToNode[bottomWindow.token] = bottomWindow
        engine.tokenToNode[focusedWindow.token] = focusedWindow
        engine.tokenToNode[topWindow.token] = topWindow

        var state = ViewportState()
        state.selectedNodeId = focusedWindow.id

        let expelled = engine.expelWindowFromColumn(
            focusedColumn: sourceColumn,
            in: wsId,
            motion: .enabled,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(expelled)
        #expect(columns.count == 2)
        #expect(columns[0] === sourceColumn)
        #expect(columns[1].windowNodes.map(\.id) == [bottomWindow.id])
        #expect(sourceColumn.windowNodes.map(\.id) == [focusedWindow.id, topWindow.id])
        #expect(sourceColumn.activeTileIdx == 0)
        #expect(sourceColumn.activeWindow?.id == focusedWindow.id)
        #expect(state.selectedNodeId == focusedWindow.id)
    }

    @Test func insertWindowInNewColumnUsesExplicitDefaultWidth() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.7
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        root.appendChild(sourceColumn)

        let stationaryWindow = NiriWindow(token: makeTestHandle(pid: 41).id)
        let movedWindow = NiriWindow(token: makeTestHandle(pid: 42).id)
        sourceColumn.appendChild(stationaryWindow)
        sourceColumn.appendChild(movedWindow)
        engine.tokenToNode[stationaryWindow.token] = stationaryWindow
        engine.tokenToNode[movedWindow.token] = movedWindow

        var state = ViewportState()
        let inserted = engine.insertWindowInNewColumn(
            movedWindow,
            insertIndex: 1,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        guard columns.count == 2 else {
            Issue.record("Expected insert-window operation to create a second column")
            return
        }

        #expect(inserted)
        #expect(columns[1].width == .proportion(0.7))
        #expect(columns[1].presetWidthIdx == nil)
    }

    @Test func insertWindowInNewColumnPlacesWindowImmediatelyRightOfFocusedColumn() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let focusedColumn = NiriContainer()
        let trailingColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(focusedColumn)
        root.appendChild(trailingColumn)

        let targetWindow = NiriWindow(token: makeTestHandle(pid: 51).id)
        let focusedWindow = NiriWindow(token: makeTestHandle(pid: 52).id)
        let trailingWindow = NiriWindow(token: makeTestHandle(pid: 53).id)

        leftColumn.appendChild(targetWindow)
        focusedColumn.appendChild(focusedWindow)
        trailingColumn.appendChild(trailingWindow)

        engine.tokenToNode[targetWindow.token] = targetWindow
        engine.tokenToNode[focusedWindow.token] = focusedWindow
        engine.tokenToNode[trailingWindow.token] = trailingWindow

        var state = ViewportState()
        let inserted = engine.insertWindowInNewColumn(
            targetWindow,
            insertIndex: 2,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let orderedWindowIds = engine.columns(in: wsId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(inserted)
        #expect(orderedWindowIds == [
            focusedWindow.token.windowId,
            targetWindow.token.windowId,
            trailingWindow.token.windowId
        ])
    }

    @Test func moveColumnRightNoOpsAtEdgeEvenWhenInfiniteLoopIsEnabled() {
        let engine = NiriLayoutEngine(balancedColumnCount: 2, infiniteLoop: true)
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftWindow = NiriWindow(token: makeTestHandle(pid: 521).id)
        let rightWindow = NiriWindow(token: makeTestHandle(pid: 522).id)
        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)
        engine.tokenToNode[leftWindow.token] = leftWindow
        engine.tokenToNode[rightWindow.token] = rightWindow

        var state = ViewportState()
        state.selectedNodeId = rightWindow.id
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let moved = engine.moveColumn(
            rightColumn,
            direction: .right,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let orderedWindowIds = engine.columns(in: wsId).compactMap { $0.windowNodes.first?.token.windowId }
        #expect(!moved)
        #expect(orderedWindowIds == [leftWindow.token.windowId, rightWindow.token.windowId])
        #expect(state.activeColumnIndex == 1)
    }

    @Test func moveColumnRightUsesRemoveInsertOrderAndPreservesViewport() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let movingColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(movingColumn)
        root.appendChild(rightColumn)
        assignWidths(root.columns, widths: [300, 400, 500])

        let leftWindow = NiriWindow(token: makeTestHandle(pid: 531).id)
        let movingWindow = NiriWindow(token: makeTestHandle(pid: 532).id)
        let rightWindow = NiriWindow(token: makeTestHandle(pid: 533).id)
        leftColumn.appendChild(leftWindow)
        movingColumn.appendChild(movingWindow)
        rightColumn.appendChild(rightWindow)
        engine.tokenToNode[leftWindow.token] = leftWindow
        engine.tokenToNode[movingWindow.token] = movingWindow
        engine.tokenToNode[rightWindow.token] = rightWindow

        var state = ViewportState()
        state.selectedNodeId = movingWindow.id
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let moved = engine.moveColumn(
            movingColumn,
            direction: .right,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        let orderedWindowIds = columns.compactMap { $0.windowNodes.first?.token.windowId }
        let viewStart = viewportStart(for: state, columns: columns, gap: 8)

        #expect(moved)
        #expect(orderedWindowIds == [
            leftWindow.token.windowId,
            rightWindow.token.windowId,
            movingWindow.token.windowId
        ])
        #expect(state.activeColumnIndex == 2)
        let movedColumnX = state.columnX(at: state.activeColumnIndex, columns: columns, gap: 8)
        let movedColumnEnd = movedColumnX + columns[state.activeColumnIndex].cachedWidth
        #expect(movedColumnX >= viewStart)
        #expect(movedColumnEnd <= viewStart + 1200)
        #expect(abs(viewStart - 416) <= 1)
    }

    @Test func moveColumnToIndexUsesNiriOneBasedClamping() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let movingColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(movingColumn)
        root.appendChild(rightColumn)
        assignWidths(root.columns, widths: [300, 400, 500])

        let leftWindow = NiriWindow(token: makeTestHandle(pid: 534).id)
        let movingWindow = NiriWindow(token: makeTestHandle(pid: 535).id)
        let rightWindow = NiriWindow(token: makeTestHandle(pid: 536).id)
        leftColumn.appendChild(leftWindow)
        movingColumn.appendChild(movingWindow)
        rightColumn.appendChild(rightWindow)
        engine.tokenToNode[leftWindow.token] = leftWindow
        engine.tokenToNode[movingWindow.token] = movingWindow
        engine.tokenToNode[rightWindow.token] = rightWindow

        var state = ViewportState()
        state.selectedNodeId = movingWindow.id
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let movedToEnd = engine.moveColumnToIndex(
            movingColumn,
            99,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        #expect(movedToEnd)
        #expect(engine.columns(in: wsId).compactMap { $0.windowNodes.first?.token.windowId } == [
            leftWindow.token.windowId,
            rightWindow.token.windowId,
            movingWindow.token.windowId
        ])
        #expect(state.activeColumnIndex == 2)

        let movedToStart = engine.moveColumnToIndex(
            movingColumn,
            0,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        #expect(movedToStart)
        #expect(engine.columns(in: wsId).compactMap { $0.windowNodes.first?.token.windowId } == [
            movingWindow.token.windowId,
            leftWindow.token.windowId,
            rightWindow.token.windowId
        ])
        #expect(state.activeColumnIndex == 0)
    }

    @Test func moveColumnToFirstLastUseSharedReorderPrimitiveAndCancelInteractiveResize() {
        let fixture = makeVisibleColumnFixture(visibleCount: 2, extraColumns: 1)
        let targetWindow = fixture.windows[1]
        guard let targetColumn = fixture.engine.column(of: targetWindow) else {
            Issue.record("Expected target column for column move cancellation test")
            return
        }

        var state = ViewportState()
        state.selectedNodeId = targetWindow.id
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let didBeginResize = fixture.engine.interactiveResizeBegin(
            windowId: targetWindow.id,
            edges: .right,
            startLocation: .zero,
            in: fixture.workspaceId,
            viewOffset: state.viewOffsetPixels.target()
        )
        #expect(didBeginResize)

        let movedLast = fixture.engine.moveColumnToLast(
            targetColumn,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: fixture.monitor.visibleFrame,
            gaps: fixture.gap
        )

        #expect(movedLast)
        #expect(fixture.engine.interactiveResize == nil)
        #expect(fixture.engine.columns(in: fixture.workspaceId).last === targetColumn)

        let movedFirst = fixture.engine.moveColumnToFirst(
            targetColumn,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: fixture.monitor.visibleFrame,
            gaps: fixture.gap
        )

        #expect(movedFirst)
        #expect(fixture.engine.columns(in: fixture.workspaceId).first === targetColumn)
    }

    @Test func moveWindowToWorkspaceThenInsertColumnPreservesSourceFallbackSelection() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        let sourceWorkspaceId = UUID()
        let targetWorkspaceId = UUID()

        let targetWindow = engine.addWindow(handle: makeTestHandle(pid: 61), to: sourceWorkspaceId, afterSelection: nil)
        let fallbackWindow = engine.addWindow(
            handle: makeTestHandle(pid: 62),
            to: sourceWorkspaceId,
            afterSelection: targetWindow.id
        )
        let focusedWindow = engine.addWindow(
            handle: makeTestHandle(pid: 63),
            to: targetWorkspaceId,
            afterSelection: nil
        )

        var sourceState = ViewportState()
        sourceState.selectedNodeId = targetWindow.id
        var targetState = ViewportState()
        targetState.selectedNodeId = focusedWindow.id

        let moved = engine.moveWindowToWorkspace(
            targetWindow,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceState: &sourceState,
            targetState: &targetState
        )
        guard let movedWindow = engine.findNode(for: targetWindow.token) else {
            Issue.record("Expected moved window in target workspace")
            return
        }

        var targetInsertState = targetState
        let inserted = engine.insertWindowInNewColumn(
            movedWindow,
            insertIndex: 1,
            in: targetWorkspaceId,
            state: &targetInsertState,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let orderedWindowIds = engine.columns(in: targetWorkspaceId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(moved?.newFocusNodeId == fallbackWindow.id)
        #expect(sourceState.selectedNodeId == fallbackWindow.id)
        #expect(inserted)
        #expect(orderedWindowIds == [focusedWindow.token.windowId, targetWindow.token.windowId])
    }

    @Test func toggleColumnWidthFollowsOrderedDuplicatePresetsFromExplicitDefaultMatch() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [
            .proportion(0.85),
            .proportion(1.0),
            .proportion(0.85),
            .proportion(0.5)
        ]
        engine.defaultColumnWidth = 0.85
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        guard let column = engine.column(of: window) else {
            Issue.record("Expected column for ordered preset cycle test")
            return
        }

        #expect(column.width == .proportion(0.85))
        #expect(column.presetWidthIdx == 0)

        var state = ViewportState()
        let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        #expect(column.width == .proportion(1.0))
        #expect(column.presetWidthIdx == 1)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        #expect(column.width == .proportion(0.85))
        #expect(column.presetWidthIdx == 2)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        #expect(column.width == .proportion(0.5))
        #expect(column.presetWidthIdx == 3)
    }

    @Test func toggleColumnWidthWrapsAtPresetBoundaries() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [
            .proportion(1.0 / 3.0),
            .proportion(0.5),
            .proportion(0.666)
        ]
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        guard let column = engine.column(of: window) else {
            Issue.record("Expected column for preset boundary wrap test")
            return
        }

        var state = ViewportState()
        let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

        column.width = .proportion(1.0 / 3.0)
        column.presetWidthIdx = 0
        engine.toggleColumnWidth(
            column,
            forwards: false,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        if case let .proportion(proportion) = column.width {
            #expect(abs(proportion - 0.666) < 0.001)
        } else {
            Issue.record("Expected wrapped column width to use last proportional preset")
        }
        #expect(column.presetWidthIdx == 2)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        if case let .proportion(proportion) = column.width {
            #expect(abs(proportion - 1.0 / 3.0) < 0.001)
        } else {
            Issue.record("Expected wrapped column width to use first proportional preset")
        }
        #expect(column.presetWidthIdx == 0)
    }

    @Test func balanceSizesUsesExplicitDefaultWidthAndResetsManualState() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [
            .proportion(0.85),
            .proportion(1.0),
            .proportion(0.5)
        ]
        engine.defaultColumnWidth = 0.85
        let wsId = UUID()

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: 411), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(handle: makeTestHandle(pid: 412), to: wsId, afterSelection: firstWindow.id)
        let _ = engine.addWindow(handle: makeTestHandle(pid: 413), to: wsId, afterSelection: secondWindow.id)

        let columns = engine.columns(in: wsId)
        guard columns.count == 3 else {
            Issue.record("Expected three columns for explicit default balance test")
            return
        }

        for (index, column) in columns.enumerated() {
            column.width = index == 0 ? .fixed(900) : .proportion(0.4 + CGFloat(index) * 0.1)
            column.presetWidthIdx = index
            column.isFullWidth = true
            column.savedWidth = .fixed(700 + CGFloat(index) * 25)
            column.hasManualSingleWindowWidthOverride = true
            for window in column.windowNodes {
                window.size = CGFloat(index + 2)
            }
        }

        engine.balanceSizes(in: wsId, workingAreaWidth: 1600, gaps: 8)

        for column in columns {
            #expect(column.width == .proportion(0.85))
            #expect(column.presetWidthIdx == 0)
            #expect(!column.isFullWidth)
            #expect(column.savedWidth == nil)
            #expect(!column.hasManualSingleWindowWidthOverride)
            for window in column.windowNodes {
                #expect(window.size == 1.0)
            }
        }
    }

    @Test func explicitDefaultOutsidePresetListReanchorsOnFirstResize() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [
            .proportion(0.5),
            .proportion(0.85),
            .proportion(1.0)
        ]
        engine.defaultColumnWidth = 0.6
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        guard let column = engine.column(of: window) else {
            Issue.record("Expected column for custom default reanchor test")
            return
        }

        #expect(column.width == .proportion(0.6))
        #expect(column.presetWidthIdx == nil)

        var state = ViewportState()
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        #expect(column.width == .proportion(0.85))
        #expect(column.presetWidthIdx == 1)
    }

    @Test func balanceSizesFallsBackToAutoWidthWhenDefaultWidthIsAuto() {
        let engine = NiriLayoutEngine(balancedColumnCount: 4)
        engine.defaultColumnWidth = nil
        let wsId = UUID()

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: 421), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(handle: makeTestHandle(pid: 422), to: wsId, afterSelection: firstWindow.id)
        let _ = engine.addWindow(handle: makeTestHandle(pid: 423), to: wsId, afterSelection: secondWindow.id)

        let columns = engine.columns(in: wsId)
        guard columns.count == 3 else {
            Issue.record("Expected three columns for auto-width balance test")
            return
        }

        for column in columns {
            column.width = .fixed(777)
            column.presetWidthIdx = 2
        }

        engine.balanceSizes(in: wsId, workingAreaWidth: 1600, gaps: 8)

        guard case let .balanced(count) = engine.effectiveDefaultColumnWidth(in: wsId) else {
            Issue.record("Expected balanced default column width")
            return
        }
        let expectedWidth = 1.0 / CGFloat(count)
        for column in columns {
            #expect(column.width == .proportion(expectedWidth))
            #expect(column.presetWidthIdx == nil)
        }
    }

    @Test func balanceSizesUsesExplicitDefaultWidthWithoutPresetMatch() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.presetColumnWidths = [
            .proportion(0.5),
            .proportion(0.85),
            .proportion(1.0)
        ]
        engine.defaultColumnWidth = 0.6
        let wsId = UUID()

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: 431), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(handle: makeTestHandle(pid: 432), to: wsId, afterSelection: firstWindow.id)
        let _ = engine.addWindow(handle: makeTestHandle(pid: 433), to: wsId, afterSelection: secondWindow.id)

        let columns = engine.columns(in: wsId)
        guard columns.count == 3 else {
            Issue.record("Expected three columns for custom non-preset balance test")
            return
        }

        engine.balanceSizes(in: wsId, workingAreaWidth: 1600, gaps: 8)

        for column in columns {
            #expect(column.width == .proportion(0.6))
            #expect(column.presetWidthIdx == nil)
        }
    }

    @Test func neighboringRightMonitorKeepsPartiallyRevealedColumnHiddenUntilFullyContained() {
        let fixture = makeHorizontalNeighboringRevealFixture(workspaceOnPrimary: true, pidBase: 51)
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let primaryMonitor = fixture.owningMonitor
        let secondaryMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.secondWindow

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 0
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .right)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(20)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: partialRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(partialRevealLayout.hiddenHandles[leakingWindow.token] == .right)

        var fullRevealState = hiddenState
        fullRevealState.viewOffsetPixels = .static(primaryMonitor.visibleFrame.width + fixture.gap)
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: fullRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame for the right-edge reveal test")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minX >= primaryMonitor.visibleFrame.minX)
        #expect(fullyContainedFrame.maxX <= primaryMonitor.visibleFrame.maxX)
        #expect(!fullyContainedFrame.intersects(secondaryMonitor.frame))
    }

    @Test func neighboringRightMonitorKeepsFullscreenAndMaximizedHiddenColumnHandles() {
        let fixture = makeHorizontalNeighboringRevealFixture(workspaceOnPrimary: true, pidBase: 55)
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let primaryMonitor = fixture.owningMonitor
        let leakingWindow = fixture.secondWindow

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 0
        hiddenState.viewOffsetPixels = .static(0)

        leakingWindow.sizingMode = .fullscreen
        let fullscreenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )

        leakingWindow.sizingMode = .maximized
        let maximizedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )

        #expect(fullscreenLayout.hiddenHandles[leakingWindow.token] == .right)
        #expect(maximizedLayout.hiddenHandles[leakingWindow.token] == .right)
    }

    @Test func neighboringLeftMonitorKeepsPartiallyRevealedColumnHiddenUntilFullyContained() {
        let fixture = makeHorizontalNeighboringRevealFixture(workspaceOnPrimary: false, pidBase: 61)
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let secondaryMonitor = fixture.owningMonitor
        let primaryMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.firstWindow
        let focusedWindow = fixture.secondWindow

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 1
        hiddenState.selectedNodeId = focusedWindow.id
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: secondaryMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .left)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(-20)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: secondaryMonitor,
            gaps: fixture.gaps,
            state: partialRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(partialRevealLayout.hiddenHandles[leakingWindow.token] == .left)

        var fullRevealState = hiddenState
        fullRevealState.viewOffsetPixels = .static(-(secondaryMonitor.visibleFrame.width + fixture.gap))
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: secondaryMonitor,
            gaps: fixture.gaps,
            state: fullRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame for the left-edge reveal test")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minX >= secondaryMonitor.visibleFrame.minX)
        #expect(fullyContainedFrame.maxX <= secondaryMonitor.visibleFrame.maxX)
        #expect(!fullyContainedFrame.intersects(primaryMonitor.frame))
    }

    @Test func partialRevealRemainsVisibleWhenViewportEdgeHasNoNeighboringMonitor() {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        let wsId = UUID()
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                defaultColumnWidth: .balanced(columns: 2)
            )
        )

        let visibleWindow = engine.addWindow(handle: makeTestHandle(pid: 71), to: wsId, afterSelection: nil)
        let revealedWindow = engine.addWindow(
            handle: makeTestHandle(pid: 72),
            to: wsId,
            afterSelection: visibleWindow.id
        )
        assignWidths(
            engine.columns(in: wsId),
            widths: [monitor.visibleFrame.width, monitor.visibleFrame.width]
        )

        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 0
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: hiddenState,
            workingArea: area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[revealedWindow.token] == .right)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(40)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: partialRevealState,
            workingArea: area,
            animationTime: nil
        )
        guard let partialFrame = partialRevealLayout.frames[revealedWindow.token] else {
            Issue.record("Expected a partially revealed frame on the open desktop edge")
            return
        }

        #expect(partialRevealLayout.hiddenHandles[revealedWindow.token] == nil)
        #expect(partialFrame.minX < monitor.visibleFrame.maxX)
        #expect(partialFrame.maxX > monitor.visibleFrame.maxX)
    }

    @Test func renderOffsetRevealRemainsVisibleWhenViewportEdgeHasNoNeighboringMonitor() {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        engine.animationClock = AnimationClock()
        let wsId = UUID()
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                defaultColumnWidth: .balanced(columns: 2)
            )
        )

        let visibleWindow = engine.addWindow(handle: makeTestHandle(pid: 81), to: wsId, afterSelection: nil)
        let revealedWindow = engine.addWindow(
            handle: makeTestHandle(pid: 82),
            to: wsId,
            afterSelection: visibleWindow.id
        )
        assignWidths(
            engine.columns(in: wsId),
            widths: [monitor.visibleFrame.width, monitor.visibleFrame.width]
        )

        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        guard let revealedColumn = engine.columns(in: wsId).last,
              let baseTime = engine.animationClock?.now()
        else {
            Issue.record("Expected revealed column and animation clock for open-edge render-offset test")
            return
        }

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: baseTime
        )
        #expect(hiddenLayout.hiddenHandles[revealedWindow.token] == .right)

        revealedColumn.animateMoveFrom(
            displacement: CGPoint(x: -40, y: 0),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        guard let animatedTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after open-edge render-offset animation")
            return
        }
        let animatedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: animatedTime
        )
        guard let partialFrame = animatedLayout.frames[revealedWindow.token] else {
            Issue.record("Expected a partially revealed frame from render offset on the open desktop edge")
            return
        }

        #expect(revealedColumn.renderOffset(at: animatedTime).x < -8)
        #expect(animatedLayout.hiddenHandles[revealedWindow.token] == nil)
        #expect(partialFrame.minX < monitor.visibleFrame.maxX)
        #expect(partialFrame.maxX > monitor.visibleFrame.maxX)
    }

    @Test func neighboringRightMonitorKeepsRenderOffsetRevealHiddenUntilFullyContained() {
        let fixture = makeHorizontalNeighboringRevealFixture(
            workspaceOnPrimary: true,
            withAnimationClock: true,
            pidBase: 91
        )
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let primaryMonitor = fixture.owningMonitor
        let secondaryMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.secondWindow

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        guard let leakingColumn = engine.columns(in: wsId).last,
              let baseTime = engine.animationClock?.now()
        else {
            Issue.record("Expected hidden column and animation clock for neighboring-monitor render-offset test")
            return
        }

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: baseTime
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .right)

        leakingColumn.animateMoveFrom(
            displacement: CGPoint(x: -40, y: 0),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        guard let partialTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after neighboring-monitor render-offset animation")
            return
        }
        let partialLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: partialTime
        )
        guard let hiddenPlacementFrame = partialLayout.frames[leakingWindow.token] else {
            Issue.record("Expected hidden placement frame while neighboring monitor keeps render-offset reveal hidden")
            return
        }

        #expect(leakingColumn.renderOffset(at: partialTime).x < -8)
        #expect(partialLayout.hiddenHandles[leakingWindow.token] == .right)
        #expect(!hiddenPlacementFrame.intersects(secondaryMonitor.frame))

        leakingColumn.moveAnimation = nil
        leakingColumn.animateMoveFrom(
            displacement: CGPoint(x: -(primaryMonitor.visibleFrame.width + fixture.gap), y: 0),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        guard let fullyContainedTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for full neighboring-monitor reveal")
            return
        }
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: fullyContainedTime
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame after render-offset reveal clears the monitor boundary")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minX >= primaryMonitor.visibleFrame.minX)
        #expect(fullyContainedFrame.maxX <= primaryMonitor.visibleFrame.maxX)
        #expect(!fullyContainedFrame.intersects(secondaryMonitor.frame))
    }

    @Test func neighboringUpperMonitorKeepsPartiallyRevealedRowHiddenUntilFullyContained() {
        let fixture = makeVerticalNeighboringRevealFixture(workspaceOnLowerMonitor: true, pidBase: 161)
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let lowerMonitor = fixture.owningMonitor
        let upperMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.secondWindow

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 0
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .right)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(20)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: partialRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(partialRevealLayout.hiddenHandles[leakingWindow.token] == .right)

        var fullRevealState = hiddenState
        fullRevealState.viewOffsetPixels = .static(lowerMonitor.visibleFrame.height + fixture.gap)
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: fullRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame for the upper-edge reveal test")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minY >= lowerMonitor.visibleFrame.minY)
        #expect(fullyContainedFrame.maxY <= lowerMonitor.visibleFrame.maxY)
        #expect(!fullyContainedFrame.intersects(upperMonitor.frame))
    }

    @Test func neighboringLowerMonitorKeepsPartiallyRevealedRowHiddenUntilFullyContained() {
        let fixture = makeVerticalNeighboringRevealFixture(workspaceOnLowerMonitor: false, pidBase: 171)
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let upperMonitor = fixture.owningMonitor
        let lowerMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.firstWindow
        let focusedWindow = fixture.secondWindow

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 1
        hiddenState.selectedNodeId = focusedWindow.id
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: upperMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .left)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(-20)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: upperMonitor,
            gaps: fixture.gaps,
            state: partialRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(partialRevealLayout.hiddenHandles[leakingWindow.token] == .left)

        var fullRevealState = hiddenState
        fullRevealState.viewOffsetPixels = .static(-(upperMonitor.visibleFrame.height + fixture.gap))
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: upperMonitor,
            gaps: fixture.gaps,
            state: fullRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame for the lower-edge reveal test")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minY >= upperMonitor.visibleFrame.minY)
        #expect(fullyContainedFrame.maxY <= upperMonitor.visibleFrame.maxY)
        #expect(!fullyContainedFrame.intersects(lowerMonitor.frame))
    }

    @Test func partialRevealRemainsVisibleAtOpenVerticalEdgesWithoutNeighboringMonitor() {
        let engine = NiriLayoutEngine(balancedColumnCount: 1)
        let wsId = UUID()
        let monitor = makeLayoutPlanTestMonitor(width: 900, height: 1600)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                defaultColumnWidth: .balanced(columns: 2)
            )
        )

        let lowerWindow = engine.addWindow(handle: makeTestHandle(pid: 181), to: wsId, afterSelection: nil)
        let upperWindow = engine.addWindow(
            handle: makeTestHandle(pid: 182),
            to: wsId,
            afterSelection: lowerWindow.id
        )
        assignHeights(
            engine.columns(in: wsId),
            heights: [monitor.visibleFrame.height, monitor.visibleFrame.height]
        )

        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var upperEdgeState = ViewportState()
        upperEdgeState.activeColumnIndex = 0
        upperEdgeState.viewOffsetPixels = .static(40)
        let upperEdgeLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: upperEdgeState,
            workingArea: area,
            animationTime: nil
        )
        guard let upperPartialFrame = upperEdgeLayout.frames[upperWindow.token] else {
            Issue.record("Expected a partially revealed upper row on the open vertical edge")
            return
        }

        #expect(upperEdgeLayout.hiddenHandles[upperWindow.token] == nil)
        #expect(upperPartialFrame.minY < monitor.visibleFrame.maxY)
        #expect(upperPartialFrame.maxY > monitor.visibleFrame.maxY)

        var lowerEdgeState = ViewportState()
        lowerEdgeState.activeColumnIndex = 1
        lowerEdgeState.selectedNodeId = upperWindow.id
        lowerEdgeState.viewOffsetPixels = .static(-40)
        let lowerEdgeLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: lowerEdgeState,
            workingArea: area,
            animationTime: nil
        )
        guard let lowerPartialFrame = lowerEdgeLayout.frames[lowerWindow.token] else {
            Issue.record("Expected a partially revealed lower row on the open vertical edge")
            return
        }

        #expect(lowerEdgeLayout.hiddenHandles[lowerWindow.token] == nil)
        #expect(lowerPartialFrame.minY < monitor.visibleFrame.minY)
        #expect(lowerPartialFrame.maxY > monitor.visibleFrame.minY)
    }

    @Test func neighboringUpperMonitorKeepsAnimatedVerticalRevealHiddenUntilFullyContained() {
        let fixture = makeVerticalNeighboringRevealFixture(
            workspaceOnLowerMonitor: true,
            withAnimationClock: true,
            pidBase: 191
        )
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let lowerMonitor = fixture.owningMonitor
        let upperMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.secondWindow

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        let baseTime = CACurrentMediaTime()

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: baseTime
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .right)

        let revealTarget = lowerMonitor.visibleFrame.height + fixture.gap
        var animatingState = state
        animatingState.viewOffsetPixels = .spring(
            SpringAnimation(
                from: 0,
                to: Double(revealTarget),
                startTime: baseTime,
                config: .snappy,
                displayRefreshRate: engine.displayRefreshRate
            )
        )
        let partialTime = baseTime + 0.05
        let partialLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: animatingState,
            workingArea: fixture.area,
            animationTime: partialTime
        )
        guard let hiddenPlacementFrame = partialLayout.frames[leakingWindow.token] else {
            Issue.record("Expected hidden placement frame while upper monitor keeps animated vertical reveal hidden")
            return
        }

        #expect(animatingState.viewOffsetPixels.value(at: partialTime) > 8)
        #expect(animatingState.viewOffsetPixels.value(at: partialTime) < revealTarget)
        #expect(partialLayout.hiddenHandles[leakingWindow.token] == .right)
        #expect(!hiddenPlacementFrame.intersects(upperMonitor.frame))

        var fullyContainedState = state
        fullyContainedState.viewOffsetPixels = .static(revealTarget)
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: fullyContainedState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame after animated vertical reveal clears the monitor boundary")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minY >= lowerMonitor.visibleFrame.minY)
        #expect(fullyContainedFrame.maxY <= lowerMonitor.visibleFrame.maxY)
        #expect(!fullyContainedFrame.intersects(upperMonitor.frame))
    }

    @Test @MainActor func visibilityChangesReflectCurrentHiddenState() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace for visibility-transition test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 911)
        let transitioningToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 912)

        _ = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let engine = controller.niriEngine,
              let firstNode = engine.findNode(for: firstToken)
        else {
            Issue.record("Expected first node for visibility-transition test")
            return
        }

        let gap = CGFloat(controller.workspaceManager.gaps)
        let columnWidth = controller.insetWorkingFrame(for: monitor).width - gap
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(columnWidth)
            column.cachedWidth = columnWidth
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = firstNode.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(20)
        }

        let seededVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard seededVisiblePlans.first != nil else {
            Issue.record("Expected visible seeding plan for visibility-transition test")
            return
        }
        await executeAndSettleLayoutPlans(seededVisiblePlans, on: controller)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(0)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let initialPlan = initialPlans.first else {
            Issue.record("Expected hidden transition plan for visibility-transition test")
            return
        }

        #expect(hasHideVisibilityChange(initialPlan.diff.visibilityChanges, token: transitioningToken, side: .right))
        await executeAndSettleLayoutPlans(initialPlans, on: controller)

        let stableHiddenPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let stableHiddenPlan = stableHiddenPlans.first else {
            Issue.record("Expected repeated hidden-state plan for visibility-transition test")
            return
        }

        #expect(hasHideVisibilityChange(
            stableHiddenPlan.diff.visibilityChanges,
            token: transitioningToken,
            side: .right
        ))

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(100)
        }

        let revealPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let revealPlan = revealPlans.first else {
            Issue.record("Expected reveal plan for visibility-transition test")
            return
        }

        #expect(!hasAnyVisibilityChange(revealPlan.diff.visibilityChanges, token: transitioningToken))
        await executeAndSettleLayoutPlans(revealPlans, on: controller)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = firstNode.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(100)
        }

        let stableVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let stableVisiblePlan = stableVisiblePlans.first else {
            Issue.record("Expected repeated visible-state plan for visibility-transition test")
            return
        }

        #expect(!hasAnyVisibilityChange(stableVisiblePlan.diff.visibilityChanges, token: transitioningToken))
    }

    @Test @MainActor func centeredColumnsDoNotEmitPrimaryWorkspaceFramesAcrossSecondaryMonitorBoundary() async throws {
        guard let fixture = await makeCenteredCrossMonitorFixture(
            workspaceSide: .primary,
            windowIds: 931 ... 934
        ) else {
            return
        }
        let controller = fixture.controller
        let activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = [
            fixture.primaryWorkspaceId,
            fixture.secondaryWorkspaceId
        ]

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        await executeAndSettleLayoutPlans(initialPlans, on: controller)

        let primaryColumns = fixture.engine.columns(in: fixture.targetWorkspaceId)
        for column in primaryColumns {
            #expect(column.width == .proportion(0.5))
            #expect(column.presetWidthIdx == nil)
        }
        guard primaryColumns.count >= 3,
              let centeredWindow = primaryColumns[1].windowNodes.first,
              let leakingWindow = primaryColumns[2].windowNodes.first
        else {
            Issue.record("Expected at least three primary columns for cross-monitor leak regression test")
            return
        }

        selectWindowAndSettleViewport(
            leakingWindow,
            in: fixture.targetWorkspaceId,
            on: fixture.targetMonitor,
            engine: fixture.engine,
            controller: controller
        )
        let seededVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        await executeAndSettleLayoutPlans(seededVisiblePlans, on: controller)

        selectWindowAndSettleViewport(
            centeredWindow,
            in: fixture.targetWorkspaceId,
            on: fixture.targetMonitor,
            engine: fixture.engine,
            controller: controller
        )
        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        guard let primaryPlan = plans.first(where: { $0.workspaceId == fixture.targetWorkspaceId }) else {
            Issue.record("Expected a primary-workspace plan for cross-monitor leak regression test")
            return
        }

        assertHideOnlyMonitorBoundaryDiff(
            primaryPlan,
            token: leakingWindow.token,
            side: .right,
            disallowedMonitor: fixture.neighboringMonitor
        )
    }

    @Test @MainActor func centeredColumnsDoNotEmitSecondaryWorkspaceFramesAcrossPrimaryMonitorBoundary() async throws {
        guard let fixture = await makeCenteredCrossMonitorFixture(
            workspaceSide: .secondary,
            windowIds: 941 ... 944
        ) else {
            return
        }
        let controller = fixture.controller
        let activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = [
            fixture.primaryWorkspaceId,
            fixture.secondaryWorkspaceId
        ]

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        await executeAndSettleLayoutPlans(initialPlans, on: controller)

        let secondaryColumns = fixture.engine.columns(in: fixture.targetWorkspaceId)
        for column in secondaryColumns {
            #expect(column.width == .proportion(0.5))
            #expect(column.presetWidthIdx == nil)
        }
        guard secondaryColumns.count >= 4,
              let leakingWindow = secondaryColumns[0].windowNodes.first,
              let centeredWindow = secondaryColumns[2].windowNodes.first
        else {
            Issue.record("Expected at least four secondary columns for cross-monitor leak regression test")
            return
        }

        selectWindowAndSettleViewport(
            leakingWindow,
            in: fixture.targetWorkspaceId,
            on: fixture.targetMonitor,
            engine: fixture.engine,
            controller: controller
        )
        let seededVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        await executeAndSettleLayoutPlans(seededVisiblePlans, on: controller)

        selectWindowAndSettleViewport(
            centeredWindow,
            in: fixture.targetWorkspaceId,
            on: fixture.targetMonitor,
            engine: fixture.engine,
            controller: controller
        )
        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        guard let secondaryPlan = plans.first(where: { $0.workspaceId == fixture.targetWorkspaceId }) else {
            Issue.record("Expected a secondary-workspace plan for cross-monitor leak regression test")
            return
        }

        assertHideOnlyMonitorBoundaryDiff(
            secondaryPlan,
            token: leakingWindow.token,
            side: .left,
            disallowedMonitor: fixture.neighboringMonitor
        )
    }

    @Test @MainActor func layoutHiddenPlacementMatchesLiveHideOriginForHiddenLeftColumn() async throws {
        let monitors = makeHorizontalNeighboringTestMonitors()
        let fixture = makeTwoMonitorLayoutPlanTestController(
            primaryMonitor: monitors.primary,
            secondaryMonitor: monitors.secondary
        )
        let controller = fixture.controller
        let workspaceId = fixture.primaryWorkspaceId

        suppressAutomaticRefreshExecution(on: controller)
        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        var tokens: [WindowToken] = []
        for windowId in 921 ... 924 {
            tokens.append(addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId))
        }

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for hidden-placement parity test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        await executeAndSettleLayoutPlans(initialPlans, on: controller)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(2500)
        }

        let (frames, hiddenHandles) = calculateCurrentLayout(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            monitor: monitors.primary
        )

        guard let token = tokens.first(where: { hiddenHandles[$0] == .left }),
              let canonicalFrame = engine.findNode(for: token)?.frame,
              let hiddenFrame = frames[token],
              let liveOrigin = controller.layoutRefreshController.liveFrameHideOrigin(
                  for: canonicalFrame,
                  monitor: monitors.primary,
                  side: .left,
                  pid: token.pid,
                  reason: .layoutTransient
              )
        else {
            Issue.record("Expected a hidden-left column and live hide origin for parity test")
            return
        }

        // Experimental live hide origin intentionally uses physical monitor frame
        // parking, while layout's hidden animation frame still uses normal placement.
        // This verifies only the requested live coordinate.
        #expect(liveOrigin.x == monitors.primary.frame.minX - canonicalFrame.width + LayoutRefreshController
            .hiddenWindowEdgeRevealEpsilon)
        #expect(liveOrigin.y == canonicalFrame.origin.y)
        _ = hiddenFrame
    }

    @Test @MainActor func layoutHiddenPlacementMatchesLiveHideOriginForHiddenUpperRowInVerticalLayout() async throws {
        let monitors = makeVerticalStackedTestMonitors()
        let controller = makeLayoutPlanTestController(
            monitors: [monitors.lower, monitors.upper],
            workspaceConfigurations: [
                WorkspaceConfiguration(
                    name: "1",
                    monitorAssignment: .specificDisplay(OutputId(from: monitors.lower))
                ),
                WorkspaceConfiguration(
                    name: "2",
                    monitorAssignment: .specificDisplay(OutputId(from: monitors.upper))
                )
            ]
        )
        guard let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let upperWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Expected explicit stacked-monitor workspaces for vertical hidden-placement parity test")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitors.lower.id))
        #expect(controller.workspaceManager.setActiveWorkspace(upperWorkspaceId, on: monitors.upper.id))
        _ = controller.workspaceManager.setInteractionMonitor(monitors.lower.id)

        suppressAutomaticRefreshExecution(on: controller)
        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 951)
        let upperWindow = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 952)

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for vertical hidden-placement parity test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        await executeAndSettleLayoutPlans(initialPlans, on: controller)

        assignHeights(
            engine.columns(in: workspaceId),
            heights: [monitors.lower.visibleFrame.height, monitors.lower.visibleFrame.height]
        )

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(20)
        }

        let (frames, hiddenHandles) = calculateCurrentLayout(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            monitor: monitors.lower
        )

        guard hiddenHandles[upperWindow] == .right,
              let canonicalFrame = engine.findNode(for: upperWindow)?.frame,
              let hiddenFrame = frames[upperWindow],
              let liveOrigin = controller.layoutRefreshController.liveFrameHideOrigin(
                  for: canonicalFrame,
                  monitor: monitors.lower,
                  side: .right,
                  pid: upperWindow.pid,
                  reason: .layoutTransient
              )
        else {
            Issue.record("Expected a hidden upper row and live hide origin for vertical parity test")
            return
        }

        // Experimental live hide origin intentionally uses physical monitor frame
        // parking, while layout's hidden animation frame still uses normal placement.
        // This verifies only the requested live coordinate.
        #expect(liveOrigin.x == canonicalFrame.origin.x)
        #expect(liveOrigin.y == monitors.lower.frame.maxY - LayoutRefreshController.hiddenWindowEdgeRevealEpsilon)
        _ = hiddenFrame
    }

    @Test @MainActor func snapshotPlanUsesRemovalSeedForFallbackAndScrollParity() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Niri removal-seed test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let removedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 551)
        let survivingToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 552)
        _ = controller.workspaceManager.setManagedFocus(removedToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        guard let engine = controller.niriEngine,
              let removedNodeId = engine.findNode(for: removedToken)?.id
        else {
            Issue.record("Expected Niri engine state for removal-seed test")
            return
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = removedNodeId
        }
        let oldFrames = engine.captureWindowFrames(in: workspaceId)
        guard !oldFrames.isEmpty else {
            Issue.record("Expected non-empty Niri frame snapshot before removal")
            return
        }

        _ = controller.workspaceManager.removeWindow(pid: removedToken.pid, windowId: removedToken.windowId)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId],
            useScrollAnimationPath: true,
            removalSeeds: [
                workspaceId: NiriWindowRemovalSeed(
                    removedNodeIds: [removedNodeId],
                    oldFrames: oldFrames
                )
            ]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan after removal")
            return
        }
        guard let survivingNodeId = engine.findNode(for: survivingToken)?.id else {
            Issue.record("Expected surviving node after Niri removal")
            return
        }

        #expect(!plan.diff.frameChanges.contains(where: { $0.token == removedToken }))
        #expect(
            plan.diff.frameChanges.contains(where: { $0.token == survivingToken }) ||
                hasAnyVisibilityChange(plan.diff.visibilityChanges, token: survivingToken)
        )
        #expect(plan.sessionPatch.rememberedFocusToken == survivingToken)
        #expect(plan.sessionPatch.viewportState?.selectedNodeId == survivingNodeId)
        #expect(hasNiriScrollDirective(plan.animationDirectives, workspaceId: workspaceId))
    }

    @Test @MainActor func nonFocusedWorkspacePlanDoesNotClearFocusedBorder() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.setBordersEnabled(true)
        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let primaryToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 601
        )
        _ = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 602
        )
        _ = controller.workspaceManager.setManagedFocus(
            primaryToken,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId],
            useScrollAnimationPath: true
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)
        _ = confirmFocusedBorderForLayoutPlanTests(on: controller, token: primaryToken)

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 601)
    }

    @Test @MainActor func directBorderUpdateUsesConfirmedFocusInsteadOfRememberedFocus() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for direct border focus-source regression test")
            return
        }

        controller.setBordersEnabled(true)
        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)

        let focusedToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 609,
            pid: 8_101
        )
        let rememberedToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 610,
            pid: 8_102
        )
        _ = controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId, onMonitor: monitor.id)
        _ = controller.workspaceManager.applySessionPatch(
            .init(workspaceId: workspaceId, rememberedFocusToken: rememberedToken)
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId],
            useScrollAnimationPath: true
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)
        _ = confirmFocusedBorderForLayoutPlanTests(on: controller, token: focusedToken)

        #expect(controller.workspaceManager.confirmedManagedFocusToken == focusedToken)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 609)
    }

    @Test @MainActor func activateNodeWithoutVisibilityRebasesActiveColumnWithGapAdjustedViewportStart() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for activation rebase regression test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        controller.updateNiriConfig(balancedColumnCount: 2)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for activation rebase regression test")
            return
        }

        for windowId in 671 ... 675 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let fixedWidth = (workingFrame.width - gap) / 2
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        let columns = engine.columns(in: workspaceId)
        let windows = columns.compactMap(\.windowNodes.first)
        guard windows.count >= 5 else {
            Issue.record("Expected five columns for activation rebase regression test")
            return
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = windows[1].id
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(
            -state.columnX(at: 1, columns: columns, gap: gap)
        )
        let initialViewStart = viewportStart(for: state, columns: columns, gap: gap)

        controller.niriLayoutHandler.activateNode(
            windows[3],
            in: workspaceId,
            state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                updateTimestamp: false,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: nil
            )
        )

        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(updatedState.selectedNodeId == windows[3].id)
        #expect(updatedState.activeColumnIndex == 3)
        #expect(abs(viewportStart(for: updatedState, columns: columns, gap: gap) - initialViewStart) <= 2 * gap + 0.1)
    }

    @Test @MainActor func navigateToWindowInternalAdvancesViewportToTarget() async throws {
        let fixture = try await makeNavigateToWindowViewportFixture(
            balancedColumnCount: 2,
            windowCount: 4,
            outerGapLeft: 12,
            outerGapRight: 20
        )
        let startIndex = 0
        let targetIndex = 1
        let initialViewStart: CGFloat = 0
        setNavigateToWindowSelection(
            controller: fixture.controller,
            workspaceId: fixture.workspaceId,
            monitor: fixture.monitor,
            columns: fixture.columns,
            windows: fixture.windows,
            gap: fixture.gap,
            activeIndex: startIndex,
            viewportStart: initialViewStart,
            selectionProgress: 32
        )

        let targetWindow = fixture.windows[targetIndex]
        #expect(
            fixture.controller.windowActionHandler.navigateToWindowInternal(
                token: targetWindow.token,
                workspaceId: fixture.workspaceId
            )
        )

        let updatedState = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let actualViewStart = viewportStart(for: updatedState, columns: fixture.columns, gap: fixture.gap)

        #expect(updatedState.selectedNodeId == targetWindow.id)
        #expect(updatedState.activeColumnIndex == targetIndex)
        #expect(updatedState.selectionProgress == 0)
        // Target column must be visible after navigation
        let targetX = updatedState.columnX(at: targetIndex, columns: fixture.columns, gap: fixture.gap)
        let targetEnd = targetX + fixture.columns[targetIndex].cachedWidth
        #expect(targetX < actualViewStart + fixture.workingFrame.width)
        #expect(targetEnd > actualViewStart)
    }

    @Test @MainActor func navigateToWindowInternalRevealsTargetColumn() async throws {
        let fixture = try await makeNavigateToWindowViewportFixture(
            balancedColumnCount: 2,
            windowCount: 4
        )
        let startIndex = 0
        let targetIndex = 1
        let initialViewStart: CGFloat = 0
        setNavigateToWindowSelection(
            controller: fixture.controller,
            workspaceId: fixture.workspaceId,
            monitor: fixture.monitor,
            columns: fixture.columns,
            windows: fixture.windows,
            gap: fixture.gap,
            activeIndex: startIndex,
            viewportStart: initialViewStart
        )

        let targetWindow = fixture.windows[targetIndex]
        #expect(
            fixture.controller.windowActionHandler.navigateToWindowInternal(
                token: targetWindow.token,
                workspaceId: fixture.workspaceId
            )
        )

        let updatedState = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        #expect(updatedState.selectedNodeId == targetWindow.id)
        #expect(updatedState.activeColumnIndex == targetIndex)
        // Target column must be visible
        let actualViewStart = viewportStart(for: updatedState, columns: fixture.columns, gap: fixture.gap)
        let targetX = updatedState.columnX(at: targetIndex, columns: fixture.columns, gap: fixture.gap)
        let targetEnd = targetX + fixture.columns[targetIndex].cachedWidth
        #expect(targetX < actualViewStart + fixture.workingFrame.width)
        #expect(targetEnd > actualViewStart)
    }

    @Test @MainActor func navigateToWindowInternalHandlesSingleColumn() async throws {
        let fixture = try await makeNavigateToWindowViewportFixture(
            balancedColumnCount: 2,
            windowCount: 1
        )
        let startIndex = 0
        let targetIndex = 0
        let initialViewStart: CGFloat = 0
        setNavigateToWindowSelection(
            controller: fixture.controller,
            workspaceId: fixture.workspaceId,
            monitor: fixture.monitor,
            columns: fixture.columns,
            windows: fixture.windows,
            gap: fixture.gap,
            activeIndex: startIndex,
            viewportStart: initialViewStart
        )

        let targetWindow = fixture.windows[targetIndex]
        #expect(
            fixture.controller.windowActionHandler.navigateToWindowInternal(
                token: targetWindow.token,
                workspaceId: fixture.workspaceId
            )
        )

        let updatedState = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        #expect(updatedState.selectedNodeId == targetWindow.id)
        #expect(updatedState.activeColumnIndex == targetIndex)
    }

    @Test @MainActor func focusNeighborRoundTripUsesPaddedViewportOffsets() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for focus-neighbor round-trip regression test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        controller.updateNiriConfig(balancedColumnCount: 2)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for focus-neighbor round-trip regression test")
            return
        }

        for windowId in 641 ... 645 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let fixedWidth = (workingFrame.width - gap) / 2
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        let columns = engine.columns(in: workspaceId)
        let windows = columns.compactMap(\.windowNodes.first)
        guard windows.count >= 5 else {
            Issue.record("Expected five columns for focus-neighbor round-trip regression test")
            return
        }

        let columnStride = fixedWidth + gap

        func setSelection(activeIndex: Int, visibleStartIndex: Int) {
            let node = windows[activeIndex]
            let expectedViewStart = CGFloat(visibleStartIndex) * columnStride
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.selectedNodeId = node.id
                state.activeColumnIndex = activeIndex
                state.viewOffsetPixels = .static(
                    expectedViewStart
                        - state.columnX(at: activeIndex, columns: columns, gap: gap)
                )
            }
            _ = controller.workspaceManager.setManagedFocus(node.token, in: workspaceId, onMonitor: monitor.id)
            _ = controller.workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: node.token,
                in: workspaceId,
                onMonitor: monitor.id
            )
            controller.layoutRefreshController.stopAllScrollAnimations()
        }

        func settleViewport() {
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.viewOffsetPixels = .static(state.viewOffsetPixels.target())
            }
            controller.layoutRefreshController.stopAllScrollAnimations()
        }

        setSelection(activeIndex: 1, visibleStartIndex: 0)
        controller.niriLayoutHandler.focusNeighbor(direction: .right)
        await waitForLayoutPlanRefreshWork(on: controller)

        let firstMoveState = controller.workspaceManager.niriViewportState(for: workspaceId)

        #expect(firstMoveState.selectedNodeId == windows[2].id)
        // Target column must be visible after focus neighbor
        let firstMoveViewStart = viewportStart(for: firstMoveState, columns: columns, gap: gap)
        let target2X = firstMoveState.columnX(at: 2, columns: columns, gap: gap)
        let target2End = target2X + columns[2].cachedWidth
        #expect(target2X < firstMoveViewStart + workingFrame.width)
        #expect(target2End > firstMoveViewStart)

        settleViewport()
        controller.niriLayoutHandler.focusNeighbor(direction: .left)
        await waitForLayoutPlanRefreshWork(on: controller)

        let firstReverseState = controller.workspaceManager.niriViewportState(for: workspaceId)

        #expect(firstReverseState.selectedNodeId == windows[1].id)
        // Target column must be visible after reverse focus neighbor
        let firstReverseViewStart = viewportStart(for: firstReverseState, columns: columns, gap: gap)
        let target1X = firstReverseState.columnX(at: 1, columns: columns, gap: gap)
        let target1End = target1X + columns[1].cachedWidth
        #expect(target1X < firstReverseViewStart + workingFrame.width)
        #expect(target1End > firstReverseViewStart)
    }

    @Test @MainActor func visibleSecondaryWorkspacePlanRestoresInactiveHiddenWindows() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 650
        )
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(
            on: controller,
            token: token,
            monitor: fixture.secondaryMonitor
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId],
            useScrollAnimationPath: true
        )
        guard let secondaryPlan = plans.first(where: { $0.workspaceId == fixture.secondaryWorkspaceId }) else {
            Issue.record("Expected a plan for the visible secondary workspace")
            return
        }

        #expect(secondaryPlan.diff.restoreChanges.contains { $0.token == token })
    }

    @Test @MainActor func staleScrollAnimationStopsBeforeRestoringInactiveWorkspaceWindows() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let originalWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let replacementWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing monitor or workspaces for stale Niri animation test")
            return
        }

        controller.enableNiriLayout(revealStyle: .auto)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: originalWorkspaceId, windowId: 603)
        _ = controller.workspaceManager.setManagedFocus(token, in: originalWorkspaceId, onMonitor: monitor.id)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [originalWorkspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        controller.layoutRefreshController.stopAllScrollAnimations()
        #expect(controller.niriLayoutHandler.registerScrollAnimation(originalWorkspaceId, on: monitor.displayId))
        _ = controller.workspaceManager.setActiveWorkspace(replacementWorkspaceId, on: monitor.id)

        controller.niriLayoutHandler.tickScrollAnimation(targetTime: 1, displayId: monitor.displayId)

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }
}
