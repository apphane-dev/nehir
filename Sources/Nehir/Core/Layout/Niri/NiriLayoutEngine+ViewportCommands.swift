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
            state.viewOffsetPixels.offset(delta: Double(oldX - newX))
            state.activeColumnIndex = newActiveIndex
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
        animationConfig: SpringConfig? = nil
    ) -> Bool {
        guard !isFFM else { return false }
        guard context.columns.indices.contains(columnIndex), !context.snapPoints.isEmpty else { return false }

        let viewStart = context.currentViewStart(in: state)
        let visibility = context.visibility(of: columnIndex, viewportOffset: viewStart, in: state)
        let pixel = 1.0 / max(scale, 1.0)

        func targetColumnSnapCandidates() -> [SnapPoint] {
            context.snapCandidates(for: columnIndex, in: state)
        }

        func defaultSnap() -> SnapPoint? {
            let targetSnaps = targetColumnSnapCandidates()
            let closest = targetSnaps.closest(to: viewStart)
            if let closest, context.fillsViewport(at: closest.offset, in: state) {
                return closest
            }
            return targetSnaps.first { $0.kind == .center }
                ?? closest
        }

        let targetSnap: SnapPoint?
        switch visibility {
        case .fullyVisible:
            if revealPartial != .default {
                return false
            }
            if context.fillsViewport(at: viewStart, in: state) {
                if let centeredStart = context.centeredFillingViewportStart(
                    at: viewStart,
                    in: state,
                    pixelTolerance: pixel
                ),
                    abs(centeredStart - viewStart) > pixel
                {
                    let targetOffset = context.targetOffset(
                        forViewportStart: centeredStart,
                        activeColumnIndex: state.activeColumnIndex,
                        in: state
                    )
                    state.animateToOffset(targetOffset, motion: motion, config: animationConfig, scale: scale)
                    return true
                }
                return false
            }
            targetSnap = defaultSnap()
        case .parked:
            targetSnap = revealPartial == .default
                ? defaultSnap()
                : targetColumnSnapCandidates().closest(to: viewStart)
        case .clipped:
            switch revealPartial {
            case .default:
                targetSnap = defaultSnap()
            case .off:
                return false
            case .snapClosest:
                targetSnap = targetColumnSnapCandidates().closest(to: viewStart)
            case .snapCenter:
                let targetSnaps = targetColumnSnapCandidates()
                targetSnap = targetSnaps.first { $0.kind == .center }
                    ?? targetSnaps.closest(to: viewStart)
            }
        }

        guard let targetSnap else { return false }
        let targetOffset = context.targetOffset(for: targetSnap, in: state)
        guard abs(targetOffset - state.viewOffsetPixels.target()) > pixel else { return false }

        state.animateToOffset(targetOffset, motion: motion, config: animationConfig, scale: scale)
        return true
    }

    /// Reveals a column in response to a focus activation (e.g. clicking or
    /// focusing a window). Unlike the layout-driven `scrollToReveal`:
    /// - Activating an already fully visible column never moves the viewport.
    /// - Parked (fully hidden) columns are revealed with the fixed default snap,
    ///   independent of `revealPartial`; that policy is for clipped/partially
    ///   visible content only.
    /// - Clipped columns delegate to `scrollToReveal`, where `revealPartial` applies.
    @discardableResult
    func revealForFocusActivation(
        columnIndex: Int,
        isFFM: Bool,
        state: inout ViewportState,
        context: ViewportSnapContext,
        motion: MotionSnapshot,
        scale: CGFloat = 2.0,
        animationConfig: SpringConfig? = nil
    ) -> Bool {
        guard !isFFM else { return false }
        guard context.columns.indices.contains(columnIndex), !context.snapPoints.isEmpty else { return false }

        let viewStart = context.currentViewStart(in: state)
        let visibility = context.visibility(of: columnIndex, viewportOffset: viewStart, in: state)
        switch visibility {
        case .fullyVisible:
            return false
        case .parked:
            // Parked columns are fully hidden offscreen; reveal them with the
            // fixed default snap, independent of `revealPartial` (a policy for
            // clipped content). Mirrors `defaultSnap()` in `scrollToReveal`:
            // closest snap when it fills the viewport, otherwise the center snap.
            let targetSnaps = context.snapCandidates(for: columnIndex, in: state)
            let closest = targetSnaps.closest(to: viewStart)
            let fixedSnap: SnapPoint
            if let closest, context.fillsViewport(at: closest.offset, in: state) {
                fixedSnap = closest
            } else if let center = targetSnaps.first(where: { $0.kind == .center }) {
                fixedSnap = center
            } else if let closest {
                fixedSnap = closest
            } else {
                return false
            }
            let pixel = 1.0 / max(scale, 1.0)
            let targetOffset = context.targetOffset(for: fixedSnap, in: state)
            guard abs(targetOffset - state.viewOffsetPixels.target()) > pixel else { return false }
            state.animateToOffset(targetOffset, motion: motion, config: animationConfig, scale: scale)
            return true
        case .clipped:
            return scrollToReveal(
                columnIndex: columnIndex,
                isFFM: isFFM,
                state: &state,
                context: context,
                motion: motion,
                scale: scale,
                animationConfig: animationConfig
            )
        }
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

    private func nearestVisibleColumnIndex(
        to index: Int,
        viewportOffset: CGFloat,
        context: ViewportSnapContext,
        state: ViewportState
    ) -> Int? {
        context.columns.indices
            .filter { candidate in
                if case .parked = context.visibility(of: candidate, viewportOffset: viewportOffset, in: state) {
                    return false
                }
                return true
            }
            .min { lhs, rhs in
                let lDistance = abs(lhs - index)
                let rDistance = abs(rhs - index)
                if lDistance != rDistance { return lDistance < rDistance }
                return lhs < rhs
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
