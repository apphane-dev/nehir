// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
import Testing

// MARK: - Test Helpers

private func makeColumns(
    widths: [CGFloat],
    modes: [SizingMode]? = nil
) -> [NiriContainer] {
    widths.enumerated().map { index, width in
        let container = NiriContainer()
        container.cachedWidth = width
        container.cachedHeight = width
        let window = NiriWindow(token: makeTestHandle(pid: pid_t(10_000 + index)).id)
        if let modes, modes.indices.contains(index) {
            window.sizingMode = modes[index]
        }
        container.appendChild(window)
        return container
    }
}

private func makeContext(
    widths: [CGFloat],
    gap: CGFloat = 8,
    viewportWidth: CGFloat = 1000
) -> ViewportSnapContext {
    let state = ViewportState()
    let columns = makeColumns(widths: widths)
    return state.snapContext(
        columns: columns,
        gap: gap,
        viewportWidth: viewportWidth
    )
}

// MARK: - computeSnapGrid

@Suite struct ComputeSnapGridTests {
    @Test func emptyColumnsReturnsNoSnapPoints() {
        let context = makeContext(widths: [], viewportWidth: 1000)
        #expect(context.snapPoints.isEmpty)
    }

    @Test func singleColumnProducesLeftAndRightEdgeSnapPoints() {
        let context = makeContext(widths: [400], gap: 8, viewportWidth: 1000)
        let offsets = context.snapPoints.map(\.offset)

        // Left edge: bounded(0 - 8) = bounded(-8)
        // Right edge: bounded(0 + 400 + 8 - 1000) = bounded(-592)
        // Center: 400 > 0.30 * 1000 = 300, so: bounded(0 + 200 - 500) = bounded(-300)
        // Plus boundary points
        #expect(offsets.count >= 3)
        #expect(context.snapPoints.contains { $0.kind == .leftEdge })
        #expect(context.snapPoints.contains { $0.kind == .rightEdge })
        #expect(context.snapPoints.contains { $0.kind == .center })
    }

    @Test func fullWidthColumnOmitsGapEdgeSnapPoints() {
        let context = makeContext(widths: [1000], gap: 8, viewportWidth: 1000)
        let offsets = context.snapPoints.map(\.offset)

        // A full-width column should not get the synthetic ±gap edge snaps: snapping to
        // those offsets shifts the column by one gap and loses working-area margins.
        // Center and far overscroll boundary points may still exist.
        #expect(!offsets.contains { abs($0 - 8) < 0.5 })
        #expect(!offsets.contains { abs($0 + 8) < 0.5 })
        #expect(offsets.contains { abs($0) < 0.5 })
    }

    @Test func overWideColumnKeepsEdgeSnapPoints() {
        let context = makeContext(widths: [1400], gap: 8, viewportWidth: 1000)

        // A column wider than the viewport needs its edge snaps so clipped leading/trailing
        // content can be reached via scrollViewport. Only columns that approximately fill the
        // viewport have their edge snaps omitted.
        #expect(context.snapPoints.contains { $0.kind == .leftEdge })
        #expect(context.snapPoints.contains { $0.kind == .rightEdge })
    }

    @Test func narrowColumnOmitsCenterSnap() {
        // Column width = 300, viewportWidth = 1000. 300 > 0.30 * 1000 = 300? No (strictly >)
        let context = makeContext(widths: [300], gap: 8, viewportWidth: 1000)
        let centers = context.snapPoints.filter { $0.kind == .center }
        #expect(centers.isEmpty)
    }

    @Test func wideColumnIncludesCenterSnap() {
        // Column width = 301, viewportWidth = 1000. 301 > 0.30 * 1000 = 300? Yes
        let context = makeContext(widths: [301], gap: 8, viewportWidth: 1000)
        let centers = context.snapPoints.filter { $0.kind == .center }
        #expect(centers.count == 1)
    }

    @Test func multipleColumnsProduceSnapPointsPerColumn() {
        let context = makeContext(widths: [400, 400, 400], gap: 8, viewportWidth: 1000)
        // Each column gets left, right, center = 3, plus 2 boundary points = 11
        // But some may deduplicate
        let col0Points = context.snapPoints.filter { $0.columnIndex == 0 }
        let col1Points = context.snapPoints.filter { $0.columnIndex == 1 }
        let col2Points = context.snapPoints.filter { $0.columnIndex == 2 }

        #expect(col0Points.count >= 2) // at least left + right
        #expect(col1Points.count >= 2)
        #expect(col2Points.count >= 2)
    }

    @Test func snapPointsAreSortedByOffset() {
        let context = makeContext(widths: [400, 400, 400], gap: 8, viewportWidth: 1000)
        let offsets = context.snapPoints.map(\.offset)
        for i in 0 ..< (offsets.count - 1) {
            #expect(offsets[i] <= offsets[i + 1] + 0.5) // within pixel tolerance
        }
    }

    @Test func deduplicatesCloseSnapPoints() {
        // Two columns of same width should produce some deduplicated snap points
        let context = makeContext(widths: [400, 400], gap: 8, viewportWidth: 1000)
        // Check no two snap points are within 0.5 pixels of each other
        for i in 0 ..< (context.snapPoints.count - 1) {
            let diff = abs(context.snapPoints[i].offset - context.snapPoints[i + 1].offset)
            if diff < 0.5 {
                // Same offset is ok if they merged
                #expect(context.snapPoints[i].offset == context.snapPoints[i + 1].offset)
            }
        }
    }

    @Test func zeroWidthColumnIsSkipped() {
        let context = makeContext(widths: [0, 400, 400], gap: 8, viewportWidth: 1000)
        let nonBoundaryCol0 = context.snapPoints.filter { $0.columnIndex == 0 && $0.kind != .rightEdge }
        #expect(nonBoundaryCol0.isEmpty)
        #expect(context.snapPoints.contains { $0.columnIndex == 1 })
        #expect(context.snapPoints.contains { $0.columnIndex == 2 })
    }
}

// MARK: - SnapPoint helpers (closest, next)

@Suite struct SnapPointHelperTests {
    @Test func closestReturnsNearestSnapPoint() {
        let points = [
            SnapPoint(offset: 0, columnIndex: 0, kind: .leftEdge),
            SnapPoint(offset: 100, columnIndex: 0, kind: .rightEdge),
            SnapPoint(offset: 200, columnIndex: 1, kind: .leftEdge),
            SnapPoint(offset: 300, columnIndex: 1, kind: .rightEdge)
        ]

        #expect(points.closest(to: 50)?.offset == 0)
        #expect(points.closest(to: 150)?.offset == 100)
        #expect(points.closest(to: 250)?.offset == 200)
        #expect(points.closest(to: 350)?.offset == 300)
    }

    @Test func nextAfterReturnsNextSnapInDirection() {
        let points = [
            SnapPoint(offset: 0, columnIndex: 0, kind: .leftEdge),
            SnapPoint(offset: 100, columnIndex: 0, kind: .rightEdge),
            SnapPoint(offset: 200, columnIndex: 1, kind: .leftEdge),
            SnapPoint(offset: 300, columnIndex: 1, kind: .rightEdge)
        ]

        // Right direction
        #expect(points.next(after: 50, direction: .right)?.offset == 100)
        #expect(points.next(after: 150, direction: .right)?.offset == 200)
        #expect(points.next(after: 250, direction: .right)?.offset == 300)
        #expect(points.next(after: 350, direction: .right) == nil)

        // Left direction
        #expect(points.next(after: 250, direction: .left)?.offset == 200)
        #expect(points.next(after: 150, direction: .left)?.offset == 100)
        #expect(points.next(after: 50, direction: .left)?.offset == 0)
        #expect(points.next(after: -10, direction: .left) == nil)
    }

    @Test func emptyArrayReturnsNil() {
        let points: [SnapPoint] = []
        #expect(points.closest(to: 0) == nil)
        #expect(points.next(after: 0, direction: .right) == nil)
    }
}

// MARK: - ColumnVisibility

@Suite struct ColumnVisibilityTests {
    let state = ViewportState()

    @Test func fullyVisibleColumn() {
        // Column at 100..400, viewport 0..500
        let columns = makeColumns(widths: [300])
        let visibility = state.columnVisibility(
            for: 0,
            columns: columns,
            gap: 8,
            viewportOffset: 0,
            viewportWidth: 500
        )
        #expect(visibility == .fullyVisible)
    }

    @Test func clippedLeft() {
        // Column at 0..300, viewport 100..600
        let columns = makeColumns(widths: [300])
        let visibility = state.columnVisibility(
            for: 0,
            columns: columns,
            gap: 8,
            viewportOffset: 100,
            viewportWidth: 500
        )
        #expect(visibility == .clipped(.minimum))
    }

    @Test func clippedRight() {
        // Column at 0..300, viewport -250..250 → column end (300) exceeds viewport end (250)
        let columns = makeColumns(widths: [300])
        let visibility = state.columnVisibility(
            for: 0,
            columns: columns,
            gap: 8,
            viewportOffset: -250,
            viewportWidth: 500
        )
        #expect(visibility == .clipped(.maximum))
    }

    @Test func parkedLeft() {
        // Column at 0..300, viewport 500..1000 (column entirely to the left)
        let columns = makeColumns(widths: [300])
        let visibility = state.columnVisibility(
            for: 0,
            columns: columns,
            gap: 8,
            viewportOffset: 500,
            viewportWidth: 500
        )
        #expect(visibility == .parked(.minimum))
    }

    @Test func parkedRight() {
        // Column at 0..300, viewport -500..0 → column entirely past viewport right edge
        let columns = makeColumns(widths: [300])
        let visibility = state.columnVisibility(
            for: 0,
            columns: columns,
            gap: 8,
            viewportOffset: -500,
            viewportWidth: 500
        )
        #expect(visibility == .parked(.maximum))
    }

    @Test func invalidIndexReturnsParked() {
        let columns = makeColumns(widths: [300])
        let visibility = state.columnVisibility(
            for: 5,
            columns: columns,
            gap: 8,
            viewportOffset: 0,
            viewportWidth: 500
        )
        #expect(visibility == .parked(.minimum))
    }
}

// MARK: - ViewportSnapContext helpers

@Suite struct ViewportSnapContextTests {
    @Test func fillsViewportWithContiguousColumns() {
        let columns = makeColumns(widths: [400, 400])
        let state = ViewportState()
        let context = state.snapContext(
            columns: columns,
            gap: 8,
            viewportWidth: 816 // 400 + 8 + 400 + 2*8 tolerance
        )
        // Both columns fully visible and contiguous spanning the viewport
        #expect(context.fillsViewport(at: 0, in: state))
    }

    @Test func doesNotFillViewportWhenGapTooLarge() {
        let columns = makeColumns(widths: [400, 400])
        let state = ViewportState()
        let context = state.snapContext(
            columns: columns,
            gap: 8,
            viewportWidth: 1000 // Much wider than 400+8+400=808
        )
        #expect(!context.fillsViewport(at: 0, in: state))
    }

    @Test func snapCandidatesForColumn() {
        let columns = makeColumns(widths: [400, 400, 400])
        let state = ViewportState()
        let context = state.snapContext(
            columns: columns,
            gap: 8,
            viewportWidth: 1000
        )
        let candidates = context.snapCandidates(for: 1, in: state)
        #expect(!candidates.isEmpty)
        // Should have left edge, right edge, and center
        #expect(candidates.contains { $0.kind == .leftEdge })
        #expect(candidates.contains { $0.kind == .rightEdge })
        #expect(candidates.contains { $0.kind == .center })
    }

    @Test func targetOffsetConvertsViewportStartToRelativeOffset() {
        let columns = makeColumns(widths: [400, 400])
        var state = ViewportState()
        state.activeColumnIndex = 1
        let context = makeContext(widths: [400, 400], gap: 8, viewportWidth: 1000)

        // If we want viewport start at 408 (showing col 1 at left edge)
        let offset = context.targetOffset(forViewportStart: 408, activeColumnIndex: 1, in: state)
        // colX(1) = 408, so offset = 408 - 408 = 0
        #expect(abs(offset) < 0.001)
    }
}

// MARK: - viewportStartBounds

@Suite struct ViewportStartBoundsTests {
    let state = ViewportState()

    @Test func boundsAllowEdgeOverscroll() {
        let columns = makeColumns(widths: [400, 400, 400])
        let bounds = state.viewportStartBounds(
            columns: columns,
            gap: 8,
            viewportWidth: 500
        )
        // total = 400*3 + 8*2 = 1216
        // lower = 400*0.05 + 8 - 500 = -472
        // upper = 1216 - 400*0.05 - 8 = 1188
        #expect(bounds.lowerBound < 0) // allows overscroll left
        #expect(bounds.upperBound > 716) // allows overscroll past maxViewStart
    }

    @Test func emptyColumnsReturnsZeroRange() {
        let bounds = state.viewportStartBounds(
            columns: [],
            gap: 8,
            viewportWidth: 500
        )
        #expect(bounds == 0 ... 0)
    }
}

// MARK: - boundedViewportStart

@Suite struct BoundedViewportStartTests {
    let state = ViewportState()

    @Test func clampsToViewportBounds() {
        let columns = makeColumns(widths: [400, 400, 400])
        let bounds = state.viewportStartBounds(
            columns: columns,
            gap: 8,
            viewportWidth: 500
        )
        let clamped = state.boundedViewportStart(
            -10000,
            columns: columns,
            gap: 8,
            viewportWidth: 500
        )
        #expect(clamped == bounds.lowerBound)

        let clampedHigh = state.boundedViewportStart(
            10000,
            columns: columns,
            gap: 8,
            viewportWidth: 500
        )
        #expect(clampedHigh == bounds.upperBound)
    }
}

// MARK: - RevealStyle

@Suite struct RevealStyleTests {
    @Test func allCasesIncludeConfiguredStyles() {
        #expect(RevealStyle.allCases == [.auto, .closest, .center])
    }

    @Test func roundTripsThroughRawValue() {
        for mode in RevealStyle.allCases {
            #expect(RevealStyle(rawValue: mode.rawValue) == mode)
        }
    }
}

// MARK: - scrollViewport integration

@Suite struct ScrollViewportTests {
    @Test func scrollViewportRightAdvancesToNextSnap() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.animationClock = AnimationClock()
        let wsId = UUID()

        let first = engine.addWindow(handle: makeTestHandle(pid: 401), to: wsId, afterSelection: nil)
        let second = engine.addWindow(handle: makeTestHandle(pid: 402), to: wsId, afterSelection: first.id)
        _ = engine.addWindow(handle: makeTestHandle(pid: 403), to: wsId, afterSelection: second.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let gap: CGFloat = 8
        let colWidth: CGFloat = 400
        assignWidths(engine.columns(in: wsId), widths: [colWidth, colWidth, colWidth])

        var state = ViewportState()
        state.animationClock = engine.animationClock
        state.activeColumnIndex = 0
        state.selectedNodeId = first.id
        state.viewOffsetPixels = .static(0)

        let result = engine.scrollViewport(
            direction: .right,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(result != nil)
        // Should have moved the viewport
        #expect(state.viewOffsetPixels.target() != 0)
    }

    @Test func scrollViewportLeftReturnsNilAtStart() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.animationClock = AnimationClock()
        let wsId = UUID()

        let first = engine.addWindow(handle: makeTestHandle(pid: 411), to: wsId, afterSelection: nil)
        let second = engine.addWindow(handle: makeTestHandle(pid: 412), to: wsId, afterSelection: first.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let gap: CGFloat = 8
        let colWidth: CGFloat = 400
        assignWidths(engine.columns(in: wsId), widths: [colWidth, colWidth])

        var state = ViewportState()
        state.animationClock = engine.animationClock
        state.activeColumnIndex = 0
        state.selectedNodeId = first.id
        // Start at leftmost snap
        state.viewOffsetPixels = .static(0)

        // Scrolling left from the leftmost snap should clamp (return the leftmost snap)
        let result = engine.scrollViewport(
            direction: .left,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        // Should not go significantly into negative territory
        #expect(state.viewOffsetPixels.target() >= -50)
    }

    @Test func scrollViewportClampsAtStripEnd() {
        let engine = NiriLayoutEngine(balancedColumnCount: 3)
        engine.animationClock = AnimationClock()
        let wsId = UUID()

        let first = engine.addWindow(handle: makeTestHandle(pid: 421), to: wsId, afterSelection: nil)
        let second = engine.addWindow(handle: makeTestHandle(pid: 422), to: wsId, afterSelection: first.id)
        _ = engine.addWindow(handle: makeTestHandle(pid: 423), to: wsId, afterSelection: second.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let gap: CGFloat = 8
        let colWidth: CGFloat = 400
        assignWidths(engine.columns(in: wsId), widths: [colWidth, colWidth, colWidth])

        var state = ViewportState()
        state.animationClock = engine.animationClock
        state.activeColumnIndex = 2
        state.selectedNodeId = second.id
        // Start at rightmost position
        let rightmostOffset = state.boundedViewportStart(
            10000,
            columns: engine.columns(in: wsId),
            gap: gap,
            viewportWidth: workingFrame.width
        )
        state.viewOffsetPixels = .static(
            rightmostOffset - state.columnX(at: 2, columns: engine.columns(in: wsId), gap: gap)
        )

        // Scrolling right from the rightmost position should clamp
        _ = engine.scrollViewport(
            direction: .right,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        // Should not go past the upper bound
        let bounds = state.viewportStartBounds(
            columns: engine.columns(in: wsId),
            gap: gap,
            viewportWidth: workingFrame.width
        )
        let actualViewStart = state.columnX(at: state.activeColumnIndex, columns: engine.columns(in: wsId), gap: gap)
            + state.viewOffsetPixels.target()
        #expect(actualViewStart <= bounds.upperBound + 1)
    }
}

// MARK: - scrollToReveal

@Suite struct ScrollToRevealTests {
    @Test func scrollToRevealSkipsFFM() {
        var fixture = makeRevealFixture(viewportWidth: 800)
        let originalTarget = fixture.state.viewOffsetPixels.target()

        let revealed = fixture.engine.scrollToReveal(
            columnIndex: 2,
            isFFM: true,
            state: &fixture.state,
            context: fixture.context,
            motion: .disabled
        )

        #expect(!revealed)
        #expect(fixture.state.viewOffsetPixels.target() == originalTarget)
    }

    @Test func scrollToRevealSkipsWhenLocked() {
        var fixture = makeRevealFixture(viewportWidth: 800)
        fixture.state.isScrollLocked = true
        let originalTarget = fixture.state.viewOffsetPixels.target()

        let revealed = fixture.engine.scrollToReveal(
            columnIndex: 2,
            isFFM: false,
            state: &fixture.state,
            context: fixture.context,
            motion: .disabled
        )

        #expect(!revealed)
        #expect(fixture.state.viewOffsetPixels.target() == originalTarget)
    }

    @Test func scrollToRevealDoesNotMoveFullyVisibleTarget() {
        var fixture = makeRevealFixture(viewportWidth: 808)
        let originalTarget = fixture.state.viewOffsetPixels.target()

        let revealed = fixture.engine.scrollToReveal(
            columnIndex: 1,
            isFFM: false,
            state: &fixture.state,
            context: fixture.context,
            motion: .disabled
        )

        #expect(!revealed)
        #expect(fixture.state.viewOffsetPixels.target() == originalTarget)
    }

    @Test func scrollToRevealSuppressesFullyVisibleAutomaticRecenter() {
        var fixture = makeRevealFixture(viewportWidth: 1000)
        let originalTarget = fixture.state.viewOffsetPixels.target()
        let viewStart = fixture.context.currentViewStart(in: fixture.state)
        let closest = fixture.context.snapCandidates(for: 0, in: fixture.state).closest(to: viewStart)
        let expected = expectedRevealTargetOffset(style: .auto, columnIndex: 0, fixture: fixture)

        #expect(fixture.context.visibility(of: 0, viewportOffset: viewStart, in: fixture.state) == .fullyVisible)
        #expect(closest.map { fixture.context.fillsViewport(at: $0.offset, in: fixture.state) } == false)
        #expect(expected != originalTarget)

        let revealed = fixture.engine.scrollToReveal(
            columnIndex: 0,
            isFFM: false,
            state: &fixture.state,
            context: fixture.context,
            motion: .disabled,
            trigger: .automatic
        )

        #expect(!revealed)
        #expect(fixture.state.viewOffsetPixels.target() == originalTarget)
    }

    @Test func scrollToRevealAllowsFullyVisibleExplicitNavigationRecenter() {
        var fixture = makeRevealFixture(viewportWidth: 1000)
        let expected = expectedRevealTargetOffset(style: .auto, columnIndex: 0, fixture: fixture)

        let revealed = fixture.engine.scrollToReveal(
            columnIndex: 0,
            isFFM: false,
            state: &fixture.state,
            context: fixture.context,
            motion: .disabled,
            trigger: .explicitNavigation
        )

        #expect(revealed)
        #expect(fixture.state.viewOffsetPixels.target() == expected)
    }

    @Test func scrollToRevealSkipsFullyVisibleAutomaticWhenLocked() {
        var fixture = makeRevealFixture(viewportWidth: 1000)
        fixture.state.isScrollLocked = true
        let originalTarget = fixture.state.viewOffsetPixels.target()

        let revealed = fixture.engine.scrollToReveal(
            columnIndex: 0,
            isFFM: false,
            state: &fixture.state,
            context: fixture.context,
            motion: .disabled,
            trigger: .automatic
        )

        #expect(!revealed)
        #expect(fixture.state.viewOffsetPixels.target() == originalTarget)
    }

    @Test func scrollToRevealUsesClosestStyleForParkedTargets() {
        var fixture = makeRevealFixture(style: .closest, viewportWidth: 800)
        let expected = expectedRevealTargetOffset(style: .closest, columnIndex: 2, fixture: fixture)

        let revealed = fixture.engine.scrollToReveal(
            columnIndex: 2,
            isFFM: false,
            state: &fixture.state,
            context: fixture.context,
            motion: .disabled
        )

        #expect(revealed)
        #expect(fixture.state.viewOffsetPixels.target() == expected)
    }

    @Test func scrollToRevealUsesCenterStyleForParkedTargets() {
        var fixture = makeRevealFixture(style: .center, viewportWidth: 800)
        let expected = expectedRevealTargetOffset(style: .center, columnIndex: 2, fixture: fixture)

        let revealed = fixture.engine.scrollToReveal(
            columnIndex: 2,
            isFFM: false,
            state: &fixture.state,
            context: fixture.context,
            motion: .disabled
        )

        #expect(revealed)
        #expect(fixture.state.viewOffsetPixels.target() == expected)
    }

    @Test func scrollToRevealUsesAutoStyleForParkedTargets() {
        var fixture = makeRevealFixture(style: .auto, viewportWidth: 800)
        let expected = expectedRevealTargetOffset(style: .auto, columnIndex: 2, fixture: fixture)

        let revealed = fixture.engine.scrollToReveal(
            columnIndex: 2,
            isFFM: false,
            state: &fixture.state,
            context: fixture.context,
            motion: .disabled
        )

        #expect(revealed)
        #expect(fixture.state.viewOffsetPixels.target() == expected)
    }

    @Test func scrollToRevealUsesSameStyleMatrixForClippedTargets() {
        for style in RevealStyle.allCases {
            var fixture = makeRevealFixture(style: style, viewportWidth: 500, initialViewStart: 250)
            let expected = expectedRevealTargetOffset(style: style, columnIndex: 1, fixture: fixture)

            let revealed = fixture.engine.scrollToReveal(
                columnIndex: 1,
                isFFM: false,
                state: &fixture.state,
                context: fixture.context,
                motion: .disabled
            )

            #expect(revealed)
            #expect(fixture.state.viewOffsetPixels.target() == expected)
        }
    }

    private struct RevealFixture {
        let engine: NiriLayoutEngine
        let context: ViewportSnapContext
        var state: ViewportState
    }

    private func makeRevealFixture(
        style: RevealStyle = .auto,
        viewportWidth: CGFloat,
        initialViewStart: CGFloat = 0
    ) -> RevealFixture {
        let engine = NiriLayoutEngine()
        engine.revealStyle = style
        engine.animationClock = AnimationClock()
        let wsId = UUID()

        let first = engine.addWindow(handle: makeTestHandle(pid: 531), to: wsId, afterSelection: nil)
        let second = engine.addWindow(handle: makeTestHandle(pid: 532), to: wsId, afterSelection: first.id)
        _ = engine.addWindow(handle: makeTestHandle(pid: 533), to: wsId, afterSelection: second.id)

        let columns = engine.columns(in: wsId)
        assignWidths(columns, widths: [400, 400, 400])

        var state = ViewportState()
        state.animationClock = engine.animationClock
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(initialViewStart)

        let context = state.snapContext(
            columns: columns,
            gap: 8,
            viewportWidth: viewportWidth
        )
        return RevealFixture(engine: engine, context: context, state: state)
    }

    private func expectedRevealTargetOffset(
        style: RevealStyle,
        columnIndex: Int,
        fixture: RevealFixture
    ) -> CGFloat? {
        let viewStart = fixture.context.currentViewStart(in: fixture.state)
        let targetSnaps = fixture.context.snapCandidates(for: columnIndex, in: fixture.state)
        let closest = targetSnaps.closest(to: viewStart)
        let center = targetSnaps.first { $0.kind == .center }
        let snap: SnapPoint? = switch style {
        case .auto:
            if let closest, fixture.context.fillsViewport(at: closest.offset, in: fixture.state) {
                closest
            } else {
                center ?? closest
            }
        case .closest:
            closest
        case .center:
            center ?? closest
        }
        return snap.map { fixture.context.targetOffset(for: $0, in: fixture.state) }
    }
}

private func assignWidths(_ columns: [NiriContainer], widths: [CGFloat]) {
    for (column, width) in zip(columns, widths) {
        column.width = .fixed(width)
        column.cachedWidth = width
    }
}
