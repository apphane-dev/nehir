// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

extension NiriLayoutEngine {
    @discardableResult
    func toggleColumnTabbed(
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal
    ) -> Bool {
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId),
              let column = column(of: selectedNode)
        else {
            return false
        }

        let availableStackSpan: CGFloat = switch orientation {
        case .horizontal: workingFrame.height
        case .vertical: workingFrame.width
        }
        let overflowsAsStack = wouldOverflowAsStack(
            column: column,
            availableSpan: availableStackSpan,
            gaps: gaps,
            orientation: orientation
        )

        if column.displayMode == .tabbed {
            if overflowsAsStack {
                return splitOverflowTabbedColumn(column, in: workspaceId, state: &state)
            }
            return setColumnDisplay(.normal, for: column, motion: motion)
        }

        if column.usesOverflowTabbedMode {
            if overflowsAsStack {
                return splitOverflowTabbedColumn(column, in: workspaceId, state: &state)
            }
            column.usesOverflowTabbedMode = false
            updateTabbedColumnVisibility(column: column)
            return true
        }

        return setColumnDisplay(.tabbed, for: column, motion: motion)
    }

    func stackOverflowMetrics(
        windows: [NiriWindow],
        availableSpan: CGFloat,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> (requiredSpan: CGFloat, overflows: Bool) {
        guard !windows.isEmpty else { return (0, false) }
        let requiredWindowSpan = windows.reduce(CGFloat.zero) { partial, window in
            let constraints = window.constraints.normalized()
            let minimumSpan = switch orientation {
            case .horizontal: constraints.minSize.height
            case .vertical: constraints.minSize.width
            }
            return partial + max(NiriAxisSolver.minimumRenderableSpan, minimumSpan)
        }
        let requiredSpan = requiredWindowSpan + gaps * CGFloat(max(0, windows.count - 1))
        return (requiredSpan, requiredSpan > availableSpan + 0.5)
    }

    private func wouldOverflowAsStack(
        column: NiriContainer,
        availableSpan: CGFloat,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        let windows = column.windowNodes
        guard windows.count > 1 else { return false }
        return stackOverflowMetrics(
            windows: windows,
            availableSpan: availableSpan,
            gaps: gaps,
            orientation: orientation
        ).overflows
    }

    private func splitOverflowTabbedColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> Bool {
        guard let root = roots[workspaceId] else { return false }
        let windows = column.windowNodes
        guard windows.count > 1 else { return false }

        let activeIndex = column.activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        let activeWindow = windows[activeIndex]
        var insertionReference: NiriNode = column

        column.displayMode = .normal
        column.usesOverflowTabbedMode = false

        for window in windows where window !== activeWindow {
            let newColumn = NiriContainer()
            copySplitColumnState(from: column, to: newColumn)
            root.insertAfter(newColumn, reference: insertionReference)
            insertionReference = newColumn

            window.detach()
            newColumn.appendChild(window)
            window.isHiddenInTabbedMode = false
            newColumn.setActiveTileIdx(0)
        }

        activeWindow.isHiddenInTabbedMode = false
        column.setActiveTileIdx(0)
        state.selectedNodeId = activeWindow.id
        state.activeColumnIndex = columnIndex(of: column, in: workspaceId) ?? state.activeColumnIndex

        if LayoutTrace.isEnabled {
            LayoutTrace.log(
                "stackOverflow.split column=\(column.id.uuid.uuidString) windows=\(windows.count) active=\(activeWindow.token.windowId)"
            )
        }

        return true
    }

    private func copySplitColumnState(from sourceColumn: NiriContainer, to targetColumn: NiriContainer) {
        targetColumn.width = sourceColumn.width
        targetColumn.presetWidthIdx = sourceColumn.presetWidthIdx
        targetColumn.cachedWidth = sourceColumn.cachedWidth
        targetColumn.isFullWidth = sourceColumn.isFullWidth
        targetColumn.savedWidth = sourceColumn.savedWidth
        targetColumn.hasManualSingleWindowWidthOverride = sourceColumn.hasManualSingleWindowWidthOverride
    }

    @discardableResult
    func setColumnDisplay(
        _ mode: ColumnDisplay,
        for column: NiriContainer,
        motion: MotionSnapshot,
        gaps: CGFloat = 0
    ) -> Bool {
        guard column.displayMode != mode else { return false }

        if let resize = interactiveResize,
           let resizeWindow = findNode(by: resize.windowId) as? NiriWindow,
           let resizeColumn = findColumn(containing: resizeWindow, in: resize.workspaceId),
           resizeColumn.id == column.id
        {
            clearInteractiveResize()
        }

        let windows = column.windowNodes
        guard !windows.isEmpty else {
            column.displayMode = mode
            return true
        }

        let prevOrigin = tilesOrigin(column: column)

        column.displayMode = mode
        let newOrigin = tilesOrigin(column: column)
        let originDelta = CGPoint(x: prevOrigin.x - newOrigin.x, y: prevOrigin.y - newOrigin.y)

        column.displayMode = .normal
        let tileOffsets = computeTileOffsets(column: column, gaps: gaps)

        for (idx, window) in windows.enumerated() {
            var yDelta = idx < tileOffsets.count ? tileOffsets[idx] : 0
            yDelta -= prevOrigin.y

            if mode == .normal {
                yDelta *= -1
            }

            let delta = CGPoint(x: originDelta.x, y: originDelta.y + yDelta)
            if delta.x != 0 || delta.y != 0 {
                window.animateMoveFrom(
                    displacement: delta,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate,
                    animated: motion.animationsEnabled
                )
            }
        }

        column.displayMode = mode
        updateTabbedColumnVisibility(column: column)

        return true
    }

    func updateTabbedColumnVisibility(column: NiriContainer) {
        let windows = column.windowNodes
        guard !windows.isEmpty else { return }

        column.clampActiveTileIdx()

        if column.isEffectivelyTabbed {
            for (idx, window) in windows.enumerated() {
                let isActive = idx == column.activeTileIdx
                window.isHiddenInTabbedMode = !isActive
            }
        } else {
            for window in windows {
                window.isHiddenInTabbedMode = false
            }
        }
    }

    @discardableResult
    func activateTab(at index: Int, in column: NiriContainer) -> Bool {
        guard column.displayMode == .tabbed else { return false }

        let prevIdx = column.activeTileIdx
        column.setActiveTileIdx(index)

        if prevIdx != column.activeTileIdx {
            updateTabbedColumnVisibility(column: column)
            return true
        }
        return false
    }

    func activeColumn(in _: WorkspaceDescriptor.ID, state: ViewportState) -> NiriContainer? {
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId)
        else {
            return nil
        }
        return column(of: selectedNode)
    }
}
