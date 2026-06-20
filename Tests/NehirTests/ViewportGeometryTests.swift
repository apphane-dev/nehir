// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
import Testing

private func makeViewportGestureContainers(
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

@Suite struct ViewportGeometryTests {
    @Test func fitOffsetUsesModeAwareAreasForNormalMaximizedAndFullscreen() {
        let state = ViewportState()
        let workingArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let parentArea = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let gap: CGFloat = 10

        let normal = makeViewportGestureContainers(widths: [600], modes: [.normal])
        let maximized = makeViewportGestureContainers(widths: [600], modes: [.maximized])
        let fullscreen = makeViewportGestureContainers(widths: [600], modes: [.fullscreen])

        let areas = state.normalizedFittingAreas(
            viewportSpan: workingArea.width,
            workingArea: workingArea,
            viewFrame: parentArea
        )

        let normalOffset = state.computeModeAwareFitOffset(
            currentViewStart: 0,
            targetPos: 0,
            targetSpan: 600,
            mode: .normal,
            areas: areas,
            gap: gap
        )
        let maximizedOffset = state.computeModeAwareFitOffset(
            currentViewStart: 0,
            targetPos: 0,
            targetSpan: 600,
            mode: .maximized,
            areas: areas,
            gap: gap
        )
        let fullscreenOffset = state.computeModeAwareFitOffset(
            currentViewStart: 700,
            targetPos: 0,
            targetSpan: 600,
            mode: .fullscreen,
            areas: areas,
            gap: gap
        )

        #expect(abs(normalOffset + gap) < 0.001)
        #expect(abs(maximizedOffset) < 0.001)
        #expect(abs(fullscreenOffset) < 0.001)
    }

    @Test func centeredOffsetUsesModeAwareAreaAndFullscreenAnchor() {
        let state = ViewportState()
        let workingArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let parentArea = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let gap: CGFloat = 10

        let normal = makeViewportGestureContainers(widths: [600], modes: [.normal])
        let maximized = makeViewportGestureContainers(widths: [600], modes: [.maximized])
        let fullscreen = makeViewportGestureContainers(widths: [600], modes: [.fullscreen])

        let normalOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: normal,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )
        let maximizedOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: maximized,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )
        let fullscreenOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: fullscreen,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )

        #expect(abs(normalOffset + 200) < 0.001)
        #expect(abs(maximizedOffset + 300) < 0.001)
        #expect(abs(fullscreenOffset) < 0.001)
    }

    @Test func centeredOffsetUsesWorkingAreaRelativeCoordinatesForInsetDock() {
        let state = ViewportState()
        let workingArea = CGRect(x: 100, y: 0, width: 1_000, height: 800)
        let parentArea = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let gap: CGFloat = 10

        let normal = makeViewportGestureContainers(widths: [600], modes: [.normal])
        let maximized = makeViewportGestureContainers(widths: [600], modes: [.maximized])

        let normalOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: normal,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )
        let maximizedOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: maximized,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )

        #expect(abs(normalOffset + 200) < 0.001)
        #expect(abs(maximizedOffset + 200) < 0.001)
    }

    @Test func fullWidthNormalColumnDoesNotInheritLeftDockInset() {
        let state = ViewportState()
        let workingArea = CGRect(x: 100, y: 0, width: 1_000, height: 800)
        let parentArea = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let normal = makeViewportGestureContainers(widths: [1_000], modes: [.normal])

        let offset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: normal,
            gap: 10,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )

        #expect(abs(offset) < 0.001)
    }

    @Test func updateGestureDoesNotClampOrAdvanceSelectionDuringSwipe() {
        var state = ViewportState()
        state.activeColumnIndex = 1
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        let steps = state.updateGesture(
            deltaPixels: 10_000,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 1200
        )

        #expect(steps == nil)
        #expect(state.selectionProgress == 0)

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected active gesture state")
            return
        }

        #expect(abs(gesture.currentViewOffset - 10_000) < 0.001)
    }

    @Test func updateGestureDoesNotClampGenericNonTrackpadGesture() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 10_000,
            timestamp: 1.0,
            isTrackpad: false,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected active gesture state")
            return
        }

        #expect(abs(gesture.currentViewOffset - 10_000) < 0.001)
    }

    @Test func endGestureUsesNiriLargeColumnCorrection() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99

        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 1_000,
            timestamp: 1.0,
            isTrackpad: false,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled
        )

        #expect(state.activeColumnIndex == 1)
        // With the new snap grid, the bounded viewport clips to the strip upper bound
        // and snaps to the nearest snap point, producing a positive offset.
        #expect(abs(Double(state.viewOffsetPixels.target()) - 275.0) < 0.001)
        #expect(state.viewOffsetToRestore == nil)
    }

    @Test func endGesturePreservesRestoreOffsetWhenColumnDoesNotChange() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            isTrackpad: false
        )

        #expect(state.activeColumnIndex == 0)
        #expect(state.viewOffsetToRestore == 99)
    }

    @Test func endGestureCanPreserveTrackpadOffsetWithoutSnapping() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 240,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false
        )

        #expect(state.activeColumnIndex == 0)
        #expect(state.viewOffsetPixels.isGesture == false)
        #expect(state.viewOffsetPixels.isAnimating == false)
        #expect(abs(Double(state.viewOffsetPixels.target()) - 100) < 0.001)
        #expect(state.viewOffsetToRestore == 99)

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 120,
            timestamp: 2.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false
        )

        #expect(abs(Double(state.viewOffsetPixels.target()) - 150) < 0.001)
    }

    @Test func slowTrackpadGestureSnapsBackToCurrentColumn() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 20,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )
        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .disabled,
            isTrackpad: true,
            timestamp: 1.5
        )

        #expect(state.activeColumnIndex == 0)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) + 10) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 10) < 0.001)
    }

    @Test func fastTrackpadGestureUsesProjectedMomentumForSnapTarget() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 200,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )
        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .disabled,
            isTrackpad: true,
            timestamp: 1.016
        )

        #expect(state.activeColumnIndex == 2)
        // New snap grid includes strip boundary points; high-velocity projection snaps to upper bound
        let expectedViewPos = Double(state.targetViewPosPixels(columns: columns, gap: 10))
        let expectedOffset = Double(state.viewOffsetPixels.target())
        #expect(expectedViewPos >= 430) // snaps to or beyond col-2 right edge
        // offset is relative to active column; may be positive with overscroll bounds
        #expect(expectedViewPos < 2_000) // still bounded by strip
    }

    @Test func trackpadMomentumSnapAtStripEndNeverWrapsToFront() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300, 300, 300])

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 2_000,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )
        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .disabled,
            isTrackpad: true,
            timestamp: 1.016
        )

        #expect(state.activeColumnIndex == 4)
        // Snap grid constrains to strip boundaries; never wraps to front
        let expectedViewPos = Double(state.targetViewPosPixels(columns: columns, gap: 10))
        #expect(expectedViewPos >= 0) // stays within strip bounds
        #expect(expectedViewPos < 2_000) // does not wrap past content
    }

    @Test func preservedTrackpadOffsetKeepsHalfVisibleActiveColumn() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)
        state.viewOffsetPixels.gestureRef?.applyDelta(120)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false
        )

        #expect(state.activeColumnIndex == 0)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 120) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) - 120) < 0.001)
        #expect(state.viewOffsetToRestore == 99)
    }

    @Test func preservedTrackpadOffsetRebasesToMostVisibleColumnWithoutMovingView() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)
        state.viewOffsetPixels.gestureRef?.applyDelta(220)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 220) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 90) < 0.001)
        #expect(state.viewOffsetToRestore == nil)
    }

    @Test func preservedTrackpadOffsetClampsAtStripEndWithoutWrappingToFront() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)
        state.viewOffsetPixels.gestureRef?.applyDelta(10_000)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false
        )

        #expect(state.activeColumnIndex == 4)
        #expect(state.viewOffsetPixels.isAnimating)
        // New bounds allow intentional edge overscroll
        let expectedViewPos = Double(state.targetViewPosPixels(columns: columns, gap: 10))
        #expect(expectedViewPos > 1_000) // past old maxViewStart
        #expect(expectedViewPos < 2_000) // but still bounded
        let expectedOffset = Double(state.viewOffsetPixels.target())
        #expect(expectedOffset > 0) // positive offset due to overscroll allowance
    }

    @Test func endGesturePreservingTrackpadOffsetClampsPastContentBounds() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 10_000,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            isTrackpad: true,
            snapToColumn: false
        )

        #expect(state.activeColumnIndex == 1)
        // New bounds allow edge overscroll: targetViewPos clamps to new upper bound
        let actualViewPos = Double(state.targetViewPosPixels(columns: columns, gap: 10))
        #expect(actualViewPos > 410) // beyond old maxViewStart
        #expect(actualViewPos < 700) // still within reasonable bounds
    }

    @Test func gestureIgnoresMismatchedInputSource() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 500,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected gesture to remain active after mismatched update")
            return
        }
        #expect(gesture.currentViewOffset == 0)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            isTrackpad: true
        )

        #expect(state.viewOffsetPixels.isGesture)
    }

    @Test func endGestureUsesParentFrameRightStrutForSnapTarget() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [900, 900])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 2_000,
            timestamp: 1.0,
            isTrackpad: false,
            columns: columns,
            gap: 10,
            viewportWidth: 1_000
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 1_000,
            motion: .disabled,
            isTrackpad: false,
            workingArea: CGRect(x: 100, y: 0, width: 1_000, height: 800),
            viewFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )

        #expect(state.activeColumnIndex == 1)
        // New snap grid uses viewportWidth for snapping; offset reflects bounded snap position
        let actualOffset = Double(state.viewOffsetPixels.target())
        #expect(actualOffset != 0) // viewport should have moved
    }

    @Test func updateGestureReturnsNilForZeroWidthSingleColumn() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [0])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        let steps = state.updateGesture(
            deltaPixels: 120,
            timestamp: 1.0,
            columns: columns,
            gap: 8,
            viewportWidth: 1_200
        )

        #expect(steps == nil)
        #expect(state.selectionProgress == 0)

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected gesture state to remain active for zero-width regression test")
            return
        }

        #expect(gesture.currentViewOffset.isFinite)
    }

    @Test func endGestureRetainsStableOffsetForInvalidGeometry() {
        struct Scenario {
            let label: String
            let columns: [NiriContainer]
        }

        let scenarios: [Scenario] = [
            .init(label: "empty columns", columns: []),
            .init(label: "zero-width column", columns: makeViewportGestureContainers(widths: [0]))
        ]

        for scenario in scenarios {
            var state = ViewportState()
            state.activeColumnIndex = 2
            state.viewOffsetPixels = .static(-32)
            state.selectionProgress = 17
            state.viewOffsetToRestore = 99
            state.activatePrevColumnOnRemoval = 42

            guard state.beginGesture(isTrackpad: false, columns: scenario.columns) else {
                #expect(scenario.columns.isEmpty, Comment(rawValue: scenario.label))
                #expect(state.viewOffsetPixels.isGesture == false, Comment(rawValue: scenario.label))
                continue
            }

            guard let gesture = state.viewOffsetPixels.gestureRef else {
                Issue.record("Expected gesture state for \(scenario.label)")
                continue
            }

            gesture.currentViewOffset = -123.5

            state.endGesture(
                columns: scenario.columns,
                gap: 8,
                viewportWidth: 1_200,
                motion: .enabled
            )

            #expect(state.activeColumnIndex == 2, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetPixels.isGesture == false, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetPixels.isAnimating == false, Comment(rawValue: scenario.label))
            #expect(abs(Double(state.viewOffsetPixels.target()) + 123.5) < 0.001, Comment(rawValue: scenario.label))
            #expect(state.selectionProgress == 0, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetToRestore == nil, Comment(rawValue: scenario.label))
            #expect(state.activatePrevColumnOnRemoval == nil, Comment(rawValue: scenario.label))
        }
    }
}
