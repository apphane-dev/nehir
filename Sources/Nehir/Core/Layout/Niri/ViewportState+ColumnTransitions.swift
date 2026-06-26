// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

extension ViewportState {
    mutating func setActiveColumn(
        _ index: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        animate: Bool = false,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = index.clamped(to: 0 ... (columns.count - 1))

        let oldActiveColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let newActiveColX = columnX(at: clampedIndex, columns: columns, gap: gap)
        let offsetDelta = oldActiveColX - newActiveColX

        withRecordedViewportMutation(reason: "setActiveColumn.rebase") { state in
            state.viewOffsetPixels.offset(delta: Double(offsetDelta))
            state.activeColumnIndex = clampedIndex
        }

        let targetOffset = computeCenteredOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            workingArea: workingArea,
            viewFrame: viewFrame,
            scale: scale
        )

        if animate {
            animateToOffset(targetOffset, motion: motion)
        } else {
            setStaticViewOffsetPixels(targetOffset, reason: "setActiveColumn.staticTarget")
            preservesUnsnappedGestureOffset = false
        }
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func transitionToColumn(
        _ newIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        animate: Bool,
        scale: CGFloat = 2.0,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = newIndex.clamped(to: 0 ... (columns.count - 1))

        let oldActiveColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let newActiveColX = columnX(at: clampedIndex, columns: columns, gap: gap)
        withRecordedViewportMutation(reason: "transitionToColumn.rebase") { state in
            state.activeColumnIndex = clampedIndex
            state.viewOffsetPixels.offset(delta: Double(oldActiveColX - newActiveColX))
        }

        let context = snapContext(columns: columns, gap: gap, viewportWidth: viewportWidth)
        let currentViewStart = newActiveColX + viewOffsetPixels.target()
        let targetSnap = context.snapPoints(for: clampedIndex).closest(to: currentViewStart)
        let targetOffset = targetSnap.map { context.targetOffset(for: $0, in: self) }
            ?? context.targetOffset(forViewportStart: currentViewStart, activeColumnIndex: clampedIndex, in: self)

        let pixel: CGFloat = 1.0 / max(scale, 1.0)
        let toDiff = targetOffset - viewOffsetPixels.target()
        if abs(toDiff) < pixel {
            offsetViewOffsetPixels(delta: Double(toDiff), reason: "transitionToColumn.pixelSnap")
            preservesUnsnappedGestureOffset = false
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            return
        }

        if animate {
            animateToOffset(targetOffset, motion: motion, scale: scale)
        } else {
            setStaticViewOffsetPixels(targetOffset, reason: "transitionToColumn.staticTarget")
            preservesUnsnappedGestureOffset = false
        }

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func snapToColumn(
        _ columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = columnIndex.clamped(to: 0 ... (columns.count - 1))
        activeColumnIndex = clampedIndex

        let targetOffset = computeCenteredOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )
        setStaticViewOffsetPixels(targetOffset, reason: "snapToColumn")
        preservesUnsnappedGestureOffset = false
        selectionProgress = 0
    }

    mutating func scrollByPixels(
        _ deltaPixels: CGFloat,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        changeSelection: Bool
    ) -> Int? {
        guard abs(deltaPixels) > CGFloat.ulpOfOne else { return nil }
        guard !columns.isEmpty else { return nil }

        let totalW = totalWidth(columns: columns, gap: gap)
        guard totalW > 0 else { return nil }

        let currentOffset = viewOffsetPixels.current()
        let activeIndex = activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        let activeX = columnX(at: activeIndex, columns: columns, gap: gap)
        let context = snapContext(columns: columns, gap: gap, viewportWidth: viewportWidth)
        let newOffset = context.targetOffset(
            forViewportStart: activeX + currentOffset + deltaPixels,
            activeColumnIndex: activeIndex,
            in: self
        )

        setStaticViewOffsetPixels(newOffset, reason: "scrollByPixels")
        preservesUnsnappedGestureOffset = false

        if changeSelection {
            selectionProgress += deltaPixels
            let avgColumnWidth = totalW / CGFloat(columns.count)
            let steps = Int((selectionProgress / avgColumnWidth).rounded(.towardZero))
            if steps != 0 {
                selectionProgress -= CGFloat(steps) * avgColumnWidth
                return steps
            }
        }

        return nil
    }
}
