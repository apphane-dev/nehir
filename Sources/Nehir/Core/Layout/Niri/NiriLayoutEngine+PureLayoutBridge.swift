import AppKit
import Foundation

extension NiriLayoutEngine {
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
        applyPureLayoutActiveTileIndices(after, in: workspaceId)

        guard after != before,
              let focusedToken = after.activeWorkspace?.focusedWindowID,
              let target = findNode(for: focusedToken)
        else {
            return .handled(nil)
        }

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

    /// Uses `PureLayoutReducer` as the focused-window move decision engine and
    /// returns the concrete runtime operation Niri should execute. Niri still
    /// owns tree mutation, viewport state, and animation, but the choice of
    /// no-op / vertical swap / horizontal expel / horizontal consume comes from
    /// the shared pure model.
    func pureLayoutMovePlan(
        _ window: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        allowEdgeWrap: Bool
    ) -> PureLayoutMovePlan {
        guard let pureDirection = PureDirection(direction: direction, orientation: .horizontal),
              let before = pureLayoutWorld(
                  in: workspaceId,
                  selectedWindow: window,
                  infiniteLoop: allowEdgeWrap && effectiveInfiniteLoop(in: workspaceId)
              ),
              let beforeWorkspace = before.activeWorkspace,
              let beforeActiveColumnIndex = beforeWorkspace.activeColumnIndex,
              beforeWorkspace.columns.indices.contains(beforeActiveColumnIndex)
        else {
            return .unsupported
        }

        let after = PureLayoutReducer.moveFocusedWindow(pureDirection, in: before)
        guard after != before else { return .noChange }
        guard let afterWorkspace = after.activeWorkspace else {
            return .unsupported
        }

        if pureDirection.horizontalStep == nil {
            guard let afterActiveColumnIndex = afterWorkspace.activeColumnIndex,
                  afterWorkspace.columns.indices.contains(afterActiveColumnIndex),
                  afterActiveColumnIndex == beforeActiveColumnIndex
            else {
                return .unsupported
            }

            let beforeColumn = beforeWorkspace.columns[beforeActiveColumnIndex]
            let afterActiveWindowIndex = afterWorkspace.columns[afterActiveColumnIndex].activeWindowIndex
            guard beforeColumn.windows.indices.contains(afterActiveWindowIndex) else {
                return .unsupported
            }

            let displacedToken = beforeColumn.windows[afterActiveWindowIndex].id
            guard displacedToken != window.token else { return .unsupported }
            return .verticalSwap(targetToken: displacedToken)
        }

        if afterWorkspace.columns.count == beforeWorkspace.columns.count + 1 {
            return .horizontalExpel
        }

        if afterWorkspace.columns.count == beforeWorkspace.columns.count - 1,
           let afterActiveColumnIndex = afterWorkspace.activeColumnIndex,
           afterWorkspace.columns.indices.contains(afterActiveColumnIndex)
        {
            let targetColumnID = afterWorkspace.columns[afterActiveColumnIndex].id.rawValue
            guard beforeWorkspace.columns.indices.contains(targetColumnID) else {
                return .unsupported
            }
            return .horizontalConsume(targetColumnIndexBeforeMove: targetColumnID)
        }

        return .unsupported
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
