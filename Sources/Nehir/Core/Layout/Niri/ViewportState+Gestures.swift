import AppKit
import Foundation

let VIEW_GESTURE_WORKING_AREA_MOVEMENT: Double = 1200.0

extension ViewportState {
    @discardableResult
    mutating func beginGesture(isTrackpad: Bool, columns: [NiriContainer]) -> Bool {
        guard !columns.isEmpty else { return false }
        let currentOffset = viewOffsetPixels.current()
        viewOffsetPixels = .gesture(ViewGesture(currentViewOffset: Double(currentOffset), isTrackpad: isTrackpad))
        preservesUnsnappedGestureOffset = false
        selectionProgress = 0.0
        return true
    }

    mutating func updateGesture(
        deltaPixels: CGFloat,
        timestamp: TimeInterval,
        isTrackpad: Bool? = nil,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> Int? {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return nil
        }
        if let isTrackpad, isTrackpad != gesture.isTrackpad {
            return nil
        }

        gesture.tracker.push(delta: Double(deltaPixels), timestamp: timestamp)

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / VIEW_GESTURE_WORKING_AREA_MOVEMENT
            : 1.0
        let pos = gesture.tracker.position * normFactor
        let viewOffset = pos + gesture.deltaFromTracker

        gesture.currentViewOffset = viewOffset
        return nil
    }

    mutating func endGesture(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        isTrackpad: Bool? = nil,
        snapToColumn: Bool = true,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0,
        timestamp: TimeInterval? = nil
    ) {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return
        }
        if let isTrackpad, isTrackpad != gesture.isTrackpad {
            return
        }

        let currentOffsetForFallback = gesture.current()
        let now = timestamp ?? animationClock?.now() ?? CACurrentMediaTime()
        gesture.tracker.push(delta: 0, timestamp: now)

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / VIEW_GESTURE_WORKING_AREA_MOVEMENT
            : 1.0
        let pos = gesture.tracker.position * normFactor
        let currentOffset = pos + gesture.deltaFromTracker

        guard !columns.isEmpty else {
            endGestureWithoutSnap(currentOffset: currentOffsetForFallback)
            return
        }

        let totalColumnWidth = Double(totalWidth(columns: columns, gap: gap))
        guard totalColumnWidth.isFinite, totalColumnWidth > 0 else {
            endGestureWithoutSnap(currentOffset: currentOffsetForFallback)
            return
        }

        gesture.currentViewOffset = currentOffset

        let velocity = gesture.tracker.velocity() * normFactor

        guard snapToColumn else {
            endGesturePreservingCurrentOffset(
                currentOffset: currentOffset,
                velocity: velocity,
                columns: columns,
                gap: gap,
                viewportWidth: viewportWidth,
                motion: motion,
                timestamp: now
            )
            return
        }

        let projectedTrackerPos = gesture.tracker.projectedEndPosition() * normFactor
        let projectedOffset = projectedTrackerPos + gesture.deltaFromTracker

        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let projectedViewPos = Double(activeColX) + projectedOffset
        let areas = normalizedFittingAreas(
            viewportSpan: viewportWidth,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: .horizontal,
            scale: scale
        )

        let context = snapContext(columns: columns, gap: gap, viewportWidth: areas.span(of: areas.working))
        guard let targetSnap = context.closest(to: CGFloat(projectedViewPos)) else {
            endGestureWithoutSnap(currentOffset: currentOffsetForFallback)
            return
        }
        let result = SnapResult(viewPos: Double(targetSnap.offset), columnIndex: targetSnap.columnIndex)

        let newColX = columnX(at: result.columnIndex, columns: columns, gap: gap)
        let offsetDelta = activeColX - newColX

        let previousActiveColumnIndex = activeColumnIndex
        activeColumnIndex = result.columnIndex
        if previousActiveColumnIndex != result.columnIndex {
            viewOffsetToRestore = nil
        }

        let targetOffset = result.viewPos - Double(newColX)

        guard motion.animationsEnabled else {
            viewOffsetPixels = .static(CGFloat(targetOffset))
            preservesUnsnappedGestureOffset = false
            activatePrevColumnOnRemoval = nil
            selectionProgress = 0.0
            return
        }

        let animation = SpringAnimation(
            from: currentOffset + Double(offsetDelta),
            to: targetOffset,
            initialVelocity: velocity,
            startTime: now,
            config: springConfig,
            displayRefreshRate: displayRefreshRate
        )
        viewOffsetPixels = .spring(animation)
        preservesUnsnappedGestureOffset = false

        activatePrevColumnOnRemoval = nil
        selectionProgress = 0.0
    }

    struct SnapResult {
        let viewPos: Double
        let columnIndex: Int
    }

    private struct PreservedGestureOffset {
        let initialOffset: Double
        let finalOffset: Double
        let normalizedActiveColumn: Int
        let didClampToBounds: Bool
    }

    private mutating func endGesturePreservingCurrentOffset(
        currentOffset: Double,
        velocity: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        timestamp: TimeInterval
    ) {
        var initialOffset = currentOffset
        var finalOffset = currentOffset
        var shouldAnimateBoundsCorrection = false
        let totalColumnWidth = Double(totalWidth(columns: columns, gap: gap))
        let viewportWidth = Double(viewportWidth)

        if let preservedOffset = normalizedPreservedGestureOffset(
            currentOffset: currentOffset,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            totalColumnWidth: totalColumnWidth
        ) {
            initialOffset = preservedOffset.initialOffset
            finalOffset = preservedOffset.finalOffset
            shouldAnimateBoundsCorrection = preservedOffset.didClampToBounds
            if activeColumnIndex != preservedOffset.normalizedActiveColumn {
                viewOffsetToRestore = nil
            }
            activeColumnIndex = preservedOffset.normalizedActiveColumn
        }

        if shouldAnimateBoundsCorrection, motion.animationsEnabled {
            viewOffsetPixels = .spring(SpringAnimation(
                from: initialOffset,
                to: finalOffset,
                initialVelocity: velocity,
                startTime: timestamp,
                config: springConfig,
                displayRefreshRate: displayRefreshRate
            ))
        } else {
            viewOffsetPixels = .static(CGFloat(finalOffset))
        }
        preservesUnsnappedGestureOffset = true
        activatePrevColumnOnRemoval = nil
        selectionProgress = 0.0
    }

    private func normalizedPreservedGestureOffset(
        currentOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: Double,
        totalColumnWidth: Double
    ) -> PreservedGestureOffset? {
        guard !columns.isEmpty,
              totalColumnWidth.isFinite,
              totalColumnWidth > 0,
              viewportWidth.isFinite,
              viewportWidth > 0
        else {
            return nil
        }

        let previousActiveColumn = activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        let gap = Double(gap)
        var positions: [Double] = []
        positions.reserveCapacity(columns.count)
        var runningPosition = 0.0
        for column in columns {
            positions.append(runningPosition)
            runningPosition += Double(column.cachedWidth) + gap
        }

        let previousActiveX = positions[previousActiveColumn]
        let rawViewStart = previousActiveX + currentOffset
        let bounds = viewportStartBounds(
            columns: columns,
            gap: CGFloat(gap),
            viewportWidth: CGFloat(viewportWidth)
        )
        let viewStart = rawViewStart.clamped(to: Double(bounds.lowerBound) ... Double(bounds.upperBound))
        let viewEnd = viewStart + viewportWidth
        let didClampToBounds = abs(viewStart - rawViewStart) > 0.001

        let currentColumnWidth = max(0, Double(columns[previousActiveColumn].cachedWidth))
        let currentColumnOverlap = visibleOverlap(
            start: previousActiveX,
            end: previousActiveX + currentColumnWidth,
            viewStart: viewStart,
            viewEnd: viewEnd
        )
        let normalizedActiveColumn: Int
        if currentColumnWidth > 0, currentColumnOverlap + 0.001 >= currentColumnWidth / 2.0 {
            normalizedActiveColumn = previousActiveColumn
        } else {
            let viewportCenter = viewStart + viewportWidth / 2.0
            var bestIndex = previousActiveColumn
            var bestOverlap = -Double.infinity
            var bestCenterDistance = Double.infinity

            for (index, column) in columns.enumerated() {
                let columnStart = positions[index]
                let columnWidth = max(0, Double(column.cachedWidth))
                let columnEnd = columnStart + columnWidth
                let overlap = visibleOverlap(
                    start: columnStart,
                    end: columnEnd,
                    viewStart: viewStart,
                    viewEnd: viewEnd
                )
                let centerDistance = abs((columnStart + columnEnd) / 2.0 - viewportCenter)

                if overlap > bestOverlap + 0.001 ||
                    (abs(overlap - bestOverlap) <= 0.001 && centerDistance < bestCenterDistance)
                {
                    bestIndex = index
                    bestOverlap = overlap
                    bestCenterDistance = centerDistance
                }
            }

            normalizedActiveColumn = bestIndex
        }

        let normalizedActiveX = positions[normalizedActiveColumn]
        return PreservedGestureOffset(
            initialOffset: rawViewStart - normalizedActiveX,
            finalOffset: viewStart - normalizedActiveX,
            normalizedActiveColumn: normalizedActiveColumn,
            didClampToBounds: didClampToBounds
        )
    }

    private func visibleOverlap(
        start: Double,
        end: Double,
        viewStart: Double,
        viewEnd: Double
    ) -> Double {
        max(0, min(end, viewEnd) - max(start, viewStart))
    }

    private mutating func endGestureWithoutSnap(currentOffset: Double) {
        viewOffsetPixels = .static(CGFloat(currentOffset))
        preservesUnsnappedGestureOffset = false
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
    }
}
