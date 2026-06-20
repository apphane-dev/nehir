import AppKit
import Foundation
import OSLog

extension NiriLayoutEngine {
    private static let pureLayoutBridgeLogger = Logger(subsystem: "com.nehir", category: "pure-layout-bridge")

    struct PureLayoutSnapshot: Equatable {
        var columns: [[WindowToken]]
        var activeColumnIndex: Int?
        var activeWindowIndices: [Int]
        var focusedWindowID: WindowToken?
    }

    enum PureLayoutFocusResult {
        case handled(NiriNode?)
        case unsupported
    }

    /// Uses the platform-free `PureLayoutReducer` as the focus decision engine,
    /// then applies the resulting active-tile indices back onto the live Niri tree.
    /// Geometry, viewport scrolling, and activation remain owned by Niri runtime code.
    func pureLayoutFocusTarget(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> PureLayoutFocusResult {
        guard let pureDirection = PureDirection(direction: direction, orientation: orientation),
              let currentWindow = currentSelection as? NiriWindow,
              let before = pureLayoutWorld(
                  in: workspaceId,
                  selectedWindow: currentWindow,
                  infiniteLoop: effectiveInfiniteLoop(in: workspaceId)
              )
        else {
            return .unsupported
        }

        let after = PureLayoutReducer.focus(pureDirection, in: before)

        guard after != before,
              let focusedToken = after.activeWorkspace?.focusedWindowID,
              let target = findNode(for: focusedToken)
        else {
            return .handled(nil)
        }

        applyPureLayoutActiveTileIndices(after, in: workspaceId)
        assertPureLayoutSnapshotMatches(
            Self.pureLayoutSnapshot(after),
            selectedWindow: target,
            in: workspaceId
        )

        if direction.primaryStep(for: orientation) != nil {
            state.activatePrevColumnOnRemoval = nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )

        return .handled(target)
    }

    enum PureLayoutMovePlan: Equatable {
        case noChange
        case verticalSwap(targetToken: WindowToken)
        case horizontalExpel
        case horizontalConsume(targetColumnIndexBeforeMove: Int)
        case unsupported
    }

    struct PureLayoutMoveDecision: Equatable {
        var plan: PureLayoutMovePlan
        var expectedSnapshot: PureLayoutSnapshot?
    }

    func assertPureLayoutSnapshotMatches(
        _ expected: PureLayoutSnapshot?,
        selectedWindow: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let expected else { return }
        guard let actual = livePureLayoutSnapshot(in: workspaceId, selectedWindow: selectedWindow) else {
            Self.pureLayoutBridgeLogger.error("Niri runtime could not be snapshotted after pure layout operation")
            assertionFailure("Niri runtime could not be snapshotted after pure layout operation")
            return
        }
        guard actual != expected else { return }

        Self.pureLayoutBridgeLogger.error("Niri runtime diverged from PureLayoutReducer. expected=\(String(describing: expected), privacy: .public), actual=\(String(describing: actual), privacy: .public)")
        assertionFailure("Niri runtime diverged from PureLayoutReducer. expected=\(expected), actual=\(actual)")
    }

    /// Uses `PureLayoutReducer` as the focused-window move decision engine and
    /// returns the concrete runtime operation Niri should execute. Niri still
    /// owns tree mutation, viewport state, and animation, but the choice of
    /// no-op / vertical swap / horizontal expel / horizontal consume comes from
    /// the shared pure model.
    func pureLayoutMoveDecision(
        _ window: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        allowEdgeWrap: Bool,
        orientation: Monitor.Orientation
    ) -> PureLayoutMoveDecision {
        guard let pureDirection = PureDirection(direction: direction, orientation: orientation),
              let before = pureLayoutWorld(
                  in: workspaceId,
                  selectedWindow: window,
                  infiniteLoop: allowEdgeWrap && effectiveInfiniteLoop(in: workspaceId)
              ),
              let beforeWorkspace = before.activeWorkspace,
              let beforeActiveColumnIndex = beforeWorkspace.activeColumnIndex,
              beforeWorkspace.columns.indices.contains(beforeActiveColumnIndex)
        else {
            return PureLayoutMoveDecision(plan: .unsupported, expectedSnapshot: nil)
        }

        let after = PureLayoutReducer.moveFocusedWindow(pureDirection, in: before)
        let expectedSnapshot = Self.pureLayoutSnapshot(after)
        guard after != before else {
            return PureLayoutMoveDecision(plan: .noChange, expectedSnapshot: expectedSnapshot)
        }
        guard let afterWorkspace = after.activeWorkspace else {
            logUnsupportedPureLayoutMove(direction: direction, reason: "missing after workspace")
            return PureLayoutMoveDecision(plan: .unsupported, expectedSnapshot: expectedSnapshot)
        }

        if pureDirection.horizontalStep == nil {
            return classifyPureLayoutVerticalMove(
                window: window,
                direction: direction,
                beforeWorkspace: beforeWorkspace,
                beforeActiveColumnIndex: beforeActiveColumnIndex,
                afterWorkspace: afterWorkspace,
                expectedSnapshot: expectedSnapshot
            )
        }

        return classifyPureLayoutHorizontalMove(
            direction: direction,
            beforeWorkspace: beforeWorkspace,
            beforeActiveColumnIndex: beforeActiveColumnIndex,
            afterWorkspace: afterWorkspace,
            expectedSnapshot: expectedSnapshot
        )
    }

    private func classifyPureLayoutVerticalMove(
        window: NiriWindow,
        direction: Direction,
        beforeWorkspace: CoreWorkspace<WorkspaceDescriptor.ID, WindowToken>,
        beforeActiveColumnIndex: Int,
        afterWorkspace: CoreWorkspace<WorkspaceDescriptor.ID, WindowToken>,
        expectedSnapshot: PureLayoutSnapshot
    ) -> PureLayoutMoveDecision {
        guard let afterActiveColumnIndex = afterWorkspace.activeColumnIndex,
              afterWorkspace.columns.indices.contains(afterActiveColumnIndex),
              afterActiveColumnIndex == beforeActiveColumnIndex
        else {
            logUnsupportedPureLayoutMove(direction: direction, reason: "vertical move changed active column")
            return PureLayoutMoveDecision(plan: .unsupported, expectedSnapshot: expectedSnapshot)
        }

        let beforeColumn = beforeWorkspace.columns[beforeActiveColumnIndex]
        let afterActiveWindowIndex = afterWorkspace.columns[afterActiveColumnIndex].activeWindowIndex
        guard beforeColumn.windows.indices.contains(afterActiveWindowIndex) else {
            logUnsupportedPureLayoutMove(direction: direction, reason: "vertical target index outside before column")
            return PureLayoutMoveDecision(plan: .unsupported, expectedSnapshot: expectedSnapshot)
        }

        let displacedToken = beforeColumn.windows[afterActiveWindowIndex].id
        guard displacedToken != window.token else {
            logUnsupportedPureLayoutMove(direction: direction, reason: "vertical move did not identify displaced window")
            return PureLayoutMoveDecision(plan: .unsupported, expectedSnapshot: expectedSnapshot)
        }
        return PureLayoutMoveDecision(plan: .verticalSwap(targetToken: displacedToken), expectedSnapshot: expectedSnapshot)
    }

    private func classifyPureLayoutHorizontalMove(
        direction: Direction,
        beforeWorkspace: CoreWorkspace<WorkspaceDescriptor.ID, WindowToken>,
        beforeActiveColumnIndex: Int,
        afterWorkspace: CoreWorkspace<WorkspaceDescriptor.ID, WindowToken>,
        expectedSnapshot: PureLayoutSnapshot
    ) -> PureLayoutMoveDecision {
        let sourceColumn = beforeWorkspace.columns[beforeActiveColumnIndex]
        if sourceColumn.windows.count > 1 {
            return PureLayoutMoveDecision(plan: .horizontalExpel, expectedSnapshot: expectedSnapshot)
        }

        guard let afterActiveColumnIndex = afterWorkspace.activeColumnIndex,
              afterWorkspace.columns.indices.contains(afterActiveColumnIndex)
        else {
            logUnsupportedPureLayoutMove(direction: direction, reason: "horizontal consume missing active target column")
            return PureLayoutMoveDecision(plan: .unsupported, expectedSnapshot: expectedSnapshot)
        }

        let targetColumnID = afterWorkspace.columns[afterActiveColumnIndex].id.rawValue
        guard beforeWorkspace.columns.indices.contains(targetColumnID) else {
            logUnsupportedPureLayoutMove(direction: direction, reason: "horizontal consume target does not map to a before column")
            return PureLayoutMoveDecision(plan: .unsupported, expectedSnapshot: expectedSnapshot)
        }
        return PureLayoutMoveDecision(plan: .horizontalConsume(targetColumnIndexBeforeMove: targetColumnID), expectedSnapshot: expectedSnapshot)
    }

    private func logUnsupportedPureLayoutMove(direction: Direction, reason: String) {
        Self.pureLayoutBridgeLogger.error("Unsupported PureLayout move transform for direction=\(direction.rawValue, privacy: .public): \(reason, privacy: .public)")
        assertionFailure("Unsupported PureLayout move transform for direction=\(direction): \(reason)")
    }

    private static func pureLayoutSnapshot(
        _ world: CoreWorld<WorkspaceDescriptor.ID, WindowToken>
    ) -> PureLayoutSnapshot {
        guard let workspace = world.activeWorkspace else {
            return PureLayoutSnapshot(columns: [], activeColumnIndex: nil, activeWindowIndices: [], focusedWindowID: nil)
        }

        return PureLayoutSnapshot(
            columns: workspace.columns.map { $0.windows.map(\.id) },
            activeColumnIndex: workspace.activeColumnIndex,
            activeWindowIndices: workspace.columns.map(\.activeWindowIndex),
            focusedWindowID: workspace.focusedWindowID
        )
    }

    private func livePureLayoutSnapshot(
        in workspaceId: WorkspaceDescriptor.ID,
        selectedWindow: NiriWindow
    ) -> PureLayoutSnapshot? {
        let niriColumns = columns(in: workspaceId)
        guard !niriColumns.isEmpty else { return nil }

        var activeColumnIndex: Int?
        var snapshotColumns: [[WindowToken]] = []
        var activeWindowIndices: [Int] = []

        for (columnIndex, column) in niriColumns.enumerated() {
            let windows = column.windowNodes
            guard !windows.isEmpty else { return nil }

            if windows.contains(where: { $0 === selectedWindow }) {
                activeColumnIndex = columnIndex
            }

            snapshotColumns.append(windows.map(\.token))
            activeWindowIndices.append(min(max(column.activeTileIdx, 0), windows.count - 1))
        }

        let focusedWindowID = activeColumnIndex.flatMap { columnIndex -> WindowToken? in
            guard snapshotColumns.indices.contains(columnIndex),
                  activeWindowIndices.indices.contains(columnIndex)
            else { return nil }
            let activeWindowIndex = activeWindowIndices[columnIndex]
            guard snapshotColumns[columnIndex].indices.contains(activeWindowIndex) else { return nil }
            return snapshotColumns[columnIndex][activeWindowIndex]
        }

        return PureLayoutSnapshot(
            columns: snapshotColumns,
            activeColumnIndex: activeColumnIndex,
            activeWindowIndices: activeWindowIndices,
            focusedWindowID: focusedWindowID
        )
    }

    private func pureLayoutWorld(
        in workspaceId: WorkspaceDescriptor.ID,
        selectedWindow: NiriWindow,
        infiniteLoop: Bool
    ) -> CoreWorld<WorkspaceDescriptor.ID, WindowToken>? {
        let niriColumns = columns(in: workspaceId)
        guard !niriColumns.isEmpty else { return nil }

        var activeColumnIndex: Int?
        var coreColumns: [CoreColumn<WindowToken>] = []

        for (columnIndex, column) in niriColumns.enumerated() {
            let windows = column.windowNodes
            guard !windows.isEmpty else { return nil }

            let selectedIndex = windows.firstIndex { $0 === selectedWindow }
            let clampedActiveIndex = min(max(column.activeTileIdx, 0), windows.count - 1)
            let activeWindowIndex = selectedIndex ?? clampedActiveIndex

            if selectedIndex != nil {
                activeColumnIndex = columnIndex
            }

            coreColumns.append(
                CoreColumn(
                    id: CoreColumnID(rawValue: columnIndex),
                    windows: windows.map { CoreWindow(id: $0.token) },
                    activeWindowIndex: activeWindowIndex
                )
            )
        }

        guard let activeColumnIndex else { return nil }

        return CoreWorld(
            workspaces: [
                CoreWorkspace(
                    id: workspaceId,
                    columns: coreColumns,
                    activeColumnIndex: activeColumnIndex
                )
            ],
            activeWorkspaceIndex: 0,
            nextColumnID: coreColumns.count,
            config: PureLayoutConfig(infiniteLoop: infiniteLoop)
        )
    }

    private func applyPureLayoutActiveTileIndices(
        _ world: CoreWorld<WorkspaceDescriptor.ID, WindowToken>,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let workspace = world.activeWorkspace else { return }
        let niriColumns = columns(in: workspaceId)

        for (index, pureColumn) in workspace.columns.enumerated() where niriColumns.indices.contains(index) {
            let niriColumn = niriColumns[index]
            guard !niriColumn.windowNodes.isEmpty else { continue }
            let clampedActiveIndex = min(max(pureColumn.activeWindowIndex, 0), niriColumn.windowNodes.count - 1)
            niriColumn.setActiveTileIdx(clampedActiveIndex)
            updateTabbedColumnVisibility(column: niriColumn)
        }
    }
}

private extension PureDirection {
    /// Maps display-space directions onto PureLayout's logical axes.
    ///
    /// PureLayout models columns on its horizontal axis and stack position on its
    /// vertical axis. A vertical monitor rotates the user's display-space commands:
    /// up/down move between columns, while left/right move within a stack.
    init?(direction: Direction, orientation: Monitor.Orientation) {
        switch orientation {
        case .horizontal:
            switch direction {
            case .left: self = .left
            case .right: self = .right
            case .up: self = .up
            case .down: self = .down
            }
        case .vertical:
            switch direction {
            case .up: self = .left
            case .down: self = .right
            case .right: self = .up
            case .left: self = .down
            }
        }
    }
}
