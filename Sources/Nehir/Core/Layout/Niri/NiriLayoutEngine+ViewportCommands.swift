// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

extension NiriLayoutEngine {
    @discardableResult
    func scrollViewport(
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriWindow? {
        guard direction == .left || direction == .right else { return nil }
        let scale = displayScale(in: workspaceId)
        prepareAndSeedSingleWindowViewport(
            in: workspaceId,
            workingFrame: workingFrame,
            scale: scale,
            gaps: gaps,
            state: &state
        )
        let columns = columns(in: workspaceId)
        guard !columns.isEmpty else { return nil }
        let context = makeViewportSnapContext(
            columns: columns,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            intentionallyDoesNotFillViewport: loneWindowIntentionallyDoesNotFillViewport(in: workspaceId)
        )
        guard !context.snapPoints.isEmpty else { return nil }

        let currentViewStart = context.currentViewStart(in: state)
        let targetSnap = context.next(after: currentViewStart, direction: direction)
            ?? (direction == .left ? context.snapPoints.first : context.snapPoints.last)
        guard let targetSnap else { return nil }

        let oldActiveIndex = state.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        var newActiveIndex = oldActiveIndex
        if case .parked = context.visibility(of: oldActiveIndex, viewportOffset: targetSnap.offset, in: state) {
            newActiveIndex = nearestVisibleColumnIndex(
                to: oldActiveIndex,
                viewportOffset: targetSnap.offset,
                context: context,
                state: state
            ) ?? targetSnap.columnIndex
        }

        if newActiveIndex != oldActiveIndex {
            let oldX = state.columnX(at: oldActiveIndex, columns: columns, gap: gaps)
            let newX = state.columnX(at: newActiveIndex, columns: columns, gap: gaps)
            state.withRecordedViewportMutation(reason: "scrollViewport.rebaseActiveColumn") { state in
                state.viewOffsetPixels.offset(delta: Double(oldX - newX))
                state.activeColumnIndex = newActiveIndex
            }
            state.viewOffsetToRestore = nil
        }

        state.animateToOffset(context.targetOffset(for: targetSnap, in: state), motion: motion, scale: scale)
        return syncViewportSelectionToActiveColumn(columns: columns, state: &state)
    }

    @discardableResult
    func scrollToReveal(
        columnIndex: Int,
        isFFM: Bool,
        state: inout ViewportState,
        context: ViewportSnapContext,
        motion: MotionSnapshot,
        scale: CGFloat = 2.0,
        animationConfig: SpringConfig? = nil,
        allowFullyVisibleAutomaticRecenter: Bool = false,
        trigger: RevealTrigger = .automatic
    ) -> Bool {
        guard !isFFM else { return false }
        guard context.columns.indices.contains(columnIndex), !context.snapPoints.isEmpty else { return false }

        let viewStart = context.currentViewStart(in: state)
        let visibility = context.visibility(of: columnIndex, viewportOffset: viewStart, in: state)
        let pixel = 1.0 / max(scale, 1.0)

        let targetSnaps = context.snapCandidates(for: columnIndex, in: state)
        let closest = targetSnaps.closest(to: viewStart)
        let center = targetSnaps.first { $0.kind == .center }

        func autoSnap() -> SnapPoint? {
            if let closest, context.fillsViewport(at: closest.offset, in: state) {
                return closest
            }
            return center ?? closest
        }

        let targetSnap: SnapPoint?
        switch visibility {
        case .fullyVisible:
            guard !trigger.respectsScrollLock || !state.isScrollLocked else { return false }
            // Re-centering a fully visible filling group is viewport-position maintenance,
            // not a reveal. Keep the proportional slack / lone-column centering contract
            // even when no hidden content needs to be revealed, while still honoring
            // scroll lock for automatic triggers.
            if context.fillsViewport(at: viewStart, in: state) {
                guard let centeredStart = context.centeredFillingViewportStart(
                    at: viewStart,
                    in: state,
                    pixelTolerance: pixel
                ),
                    abs(centeredStart - viewStart) > pixel
                else {
                    return false
                }
                let targetOffset = context.targetOffset(
                    forViewportStart: centeredStart,
                    activeColumnIndex: state.activeColumnIndex,
                    in: state
                )
                state.animateToOffset(targetOffset, motion: motion, config: animationConfig, scale: scale)
                return true
            }
            guard revealStyle == .auto,
                  trigger == .explicitNavigation || allowFullyVisibleAutomaticRecenter
            else { return false }
            targetSnap = autoSnap()
        case .parked,
             .clipped:
            guard !trigger.respectsScrollLock || !state.isScrollLocked else { return false }
            targetSnap = switch revealStyle {
            case .auto:
                autoSnap()
            case .closest:
                closest
            case .center:
                center ?? closest
            }
        }

        guard let targetSnap else { return false }
        let targetOffset = context.targetOffset(for: targetSnap, in: state)
        guard abs(targetOffset - state.viewOffsetPixels.target()) > pixel else { return false }

        state.animateToOffset(targetOffset, motion: motion, config: animationConfig, scale: scale)
        return true
    }

    func syncViewportSelectionToActiveColumn(columns: [NiriContainer], state: inout ViewportState) -> NiriWindow? {
        guard columns.indices.contains(state.activeColumnIndex) else { return nil }
        let activeColumn = columns[state.activeColumnIndex]
        let windows = activeColumn.windowNodes
        guard !windows.isEmpty else { return nil }
        let activeTileIndex = activeColumn.activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        let selectedWindow = windows[activeTileIndex]
        state.selectedNodeId = selectedWindow.id
        return selectedWindow
    }

    func activeTileTokenNearestViewport(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> WindowToken? {
        activeTileTokensNearestViewport(
            in: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps
        ).first
    }

    func activeTileTokensNearestViewport(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> [WindowToken] {
        let columns = columns(in: workspaceId)
        guard !columns.isEmpty else { return [] }
        let context = makeViewportSnapContext(
            columns: columns,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            intentionallyDoesNotFillViewport: loneWindowIntentionallyDoesNotFillViewport(in: workspaceId)
        )
        guard !context.snapPoints.isEmpty else { return [] }
        let viewStart = context.currentViewStart(in: state)
        return visibleColumnIndicesNearestViewport(
            toViewportOffset: viewStart,
            context: context,
            state: state,
            includeClipped: false
        )
        .compactMap { columnIndex in
            guard columns.indices.contains(columnIndex) else { return nil }
            let column = columns[columnIndex]
            let windows = column.windowNodes
            guard !windows.isEmpty else { return nil }
            let activeTileIndex = column.activeTileIdx.clamped(to: 0 ... (windows.count - 1))
            return windows[activeTileIndex].token
        }
    }

    private func nearestVisibleColumnIndex(
        to index: Int,
        viewportOffset: CGFloat,
        context: ViewportSnapContext,
        state: ViewportState
    ) -> Int? {
        visibleColumnIndices(viewportOffset: viewportOffset, context: context, state: state)
            .min { lhs, rhs in
                let lDistance = abs(lhs - index)
                let rDistance = abs(rhs - index)
                if lDistance != rDistance { return lDistance < rDistance }
                return lhs < rhs
            }
    }

    private func visibleColumnIndicesNearestViewport(
        toViewportOffset viewportOffset: CGFloat,
        context: ViewportSnapContext,
        state: ViewportState,
        includeClipped: Bool = true
    ) -> [Int] {
        visibleColumnIndices(
            viewportOffset: viewportOffset,
            context: context,
            state: state,
            includeClipped: includeClipped
        )
        .sorted { lhs, rhs in
            let lhsDistance = context.snapCandidates(for: lhs, in: state)
                .map { abs($0.offset - viewportOffset) }
                .min() ?? .greatestFiniteMagnitude
            let rhsDistance = context.snapCandidates(for: rhs, in: state)
                .map { abs($0.offset - viewportOffset) }
                .min() ?? .greatestFiniteMagnitude
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs < rhs
        }
    }

    private func visibleColumnIndices(
        viewportOffset: CGFloat,
        context: ViewportSnapContext,
        state: ViewportState,
        includeClipped: Bool = true
    ) -> [Int] {
        context.columns.indices.filter { candidate in
            switch context.visibility(of: candidate, viewportOffset: viewportOffset, in: state) {
            case .fullyVisible:
                return true
            case .clipped:
                return includeClipped
            case .parked:
                return false
            }
        }
    }

    func makeViewportSnapContext(
        columns: [NiriContainer],
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        viewportWidth: CGFloat? = nil,
        intentionallyDoesNotFillViewport: Bool = false
    ) -> ViewportSnapContext {
        state.snapContext(
            columns: columns,
            gap: gaps,
            viewportWidth: viewportWidth ?? workingFrame.width,
            intentionallyDoesNotFillViewport: intentionallyDoesNotFillViewport
        )
    }

    private func cancelInteractiveResize(
        for column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let resize = interactiveResize, resize.workspaceId == workspaceId else { return }
        guard let resizeWindow = findNode(by: resize.windowId) as? NiriWindow,
              let resizeColumn = findColumn(containing: resizeWindow, in: workspaceId),
              resizeColumn === column
        else {
            return
        }

        clearInteractiveResize()
    }
}
