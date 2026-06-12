import CoreGraphics
import Foundation

let niriViewportPreParkMargin: CGFloat = 16

struct SnapPoint: Equatable {
    let offset: CGFloat
    let columnIndex: Int
    let kind: Kind

    enum Kind: Equatable {
        case leftEdge
        case rightEdge
        case center

        var sortOrder: Int {
            switch self {
            case .leftEdge: 0
            case .rightEdge: 1
            case .center: 2
            }
        }
    }
}

extension Array where Element == SnapPoint {
    func closest(to offset: CGFloat) -> SnapPoint? {
        self.min { abs($0.offset - offset) < abs($1.offset - offset) }
    }

    func next(after offset: CGFloat, direction: Direction, pixelTolerance: CGFloat = 0.5) -> SnapPoint? {
        switch direction {
        case .left:
            return last { $0.offset < offset - pixelTolerance }
        case .right:
            return first { $0.offset > offset + pixelTolerance }
        case .up, .down:
            return nil
        }
    }

    func sortedAndDeduped(pixelTolerance: CGFloat = 0.5) -> [SnapPoint] {
        filter { $0.offset.isFinite }
            .sorted { lhs, rhs in
                if abs(lhs.offset - rhs.offset) > pixelTolerance {
                    return lhs.offset < rhs.offset
                }
                return lhs.kind.sortOrder < rhs.kind.sortOrder
            }
            .reduce(into: [SnapPoint]()) { result, point in
                guard let last = result.last else {
                    result.append(point)
                    return
                }
                if abs(last.offset - point.offset) > pixelTolerance {
                    result.append(point)
                }
            }
    }
}

enum ColumnVisibility: Equatable {
    case fullyVisible
    case clipped(AxisHideEdge)
    case parked(AxisHideEdge)
}

struct ViewportSnapContext {
    let columns: [NiriContainer]
    let gap: CGFloat
    let viewportWidth: CGFloat
    let snapPoints: [SnapPoint]

    func currentViewStart(in state: ViewportState) -> CGFloat {
        state.targetViewPosPixels(columns: columns, gap: gap)
    }

    func closest(to offset: CGFloat) -> SnapPoint? {
        snapPoints.closest(to: offset)
    }

    func next(after offset: CGFloat, direction: Direction) -> SnapPoint? {
        snapPoints.next(after: offset, direction: direction)
    }

    func snapPoints(for columnIndex: Int) -> [SnapPoint] {
        snapPoints.filter { $0.columnIndex == columnIndex }
    }

    func snapCandidates(for columnIndex: Int, in state: ViewportState, pixelTolerance: CGFloat = 0.5) -> [SnapPoint] {
        guard columns.indices.contains(columnIndex) else { return [] }
        let column = columns[columnIndex]
        let start = state.columnX(at: columnIndex, columns: columns, gap: gap)
        let width = max(0, column.cachedWidth)
        guard width > 0 else { return [] }

        var candidates: [SnapPoint] = [
            SnapPoint(
                offset: state.boundedViewportStart(
                    start - gap,
                    columns: columns,
                    gap: gap,
                    viewportWidth: viewportWidth
                ),
                columnIndex: columnIndex,
                kind: .leftEdge
            ),
            SnapPoint(
                offset: state.boundedViewportStart(
                    start + width + gap - viewportWidth,
                    columns: columns,
                    gap: gap,
                    viewportWidth: viewportWidth
                ),
                columnIndex: columnIndex,
                kind: .rightEdge
            )
        ]
        if width > 0.30 * viewportWidth {
            candidates.append(SnapPoint(
                offset: state.boundedViewportStart(
                    start + width / 2 - viewportWidth / 2,
                    columns: columns,
                    gap: gap,
                    viewportWidth: viewportWidth
                ),
                columnIndex: columnIndex,
                kind: .center
            ))
        }

        return candidates.sortedAndDeduped(pixelTolerance: pixelTolerance)
    }

    func fillsViewport(at viewportStart: CGFloat, in state: ViewportState, pixelTolerance: CGFloat = 0.5) -> Bool {
        let viewportEnd = viewportStart + viewportWidth
        var fullColumnIndices: [Int] = []

        for index in columns.indices {
            let start = state.columnX(at: index, columns: columns, gap: gap)
            let width = max(0, columns[index].cachedWidth)
            guard width > 0 else { continue }
            let end = start + width
            if start >= viewportStart - pixelTolerance,
               end <= viewportEnd + pixelTolerance
            {
                fullColumnIndices.append(index)
            }
        }

        guard let first = fullColumnIndices.first,
              let last = fullColumnIndices.last
        else { return false }

        for index in first ... last where !fullColumnIndices.contains(index) {
            return false
        }

        let firstStart = state.columnX(at: first, columns: columns, gap: gap)
        let lastStart = state.columnX(at: last, columns: columns, gap: gap)
        let lastEnd = lastStart + max(0, columns[last].cachedWidth)
        let coveredWidth = max(0, lastEnd - firstStart)
        let tolerance = max(pixelTolerance, 2 * gap + pixelTolerance)

        return abs(coveredWidth - viewportWidth) <= tolerance
    }

    func visibility(of columnIndex: Int, viewportOffset: CGFloat, in state: ViewportState) -> ColumnVisibility {
        state.columnVisibility(
            for: columnIndex,
            columns: columns,
            gap: gap,
            viewportOffset: viewportOffset,
            viewportWidth: viewportWidth
        )
    }

    func boundedViewportStart(_ viewportStart: CGFloat, in state: ViewportState) -> CGFloat {
        state.boundedViewportStart(
            viewportStart,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )
    }

    func targetOffset(for snapPoint: SnapPoint, in state: ViewportState) -> CGFloat {
        let activeIndex = state.activeColumnIndex.clamped(to: 0 ... max(0, columns.count - 1))
        return targetOffset(forViewportStart: snapPoint.offset, activeColumnIndex: activeIndex, in: state)
    }

    func targetOffset(forViewportStart viewportStart: CGFloat, activeColumnIndex: Int, in state: ViewportState) -> CGFloat {
        state.boundedViewOffset(
            targetViewStart: viewportStart,
            activeColumnIndex: activeColumnIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )
    }
}

struct ViewportFittingAreas {
    let working: CGRect
    let parent: CGRect
    let orientation: Monitor.Orientation
    let scale: CGFloat

    var viewSpan: CGFloat {
        span(of: parent)
    }

    func span(of rect: CGRect) -> CGFloat {
        switch orientation {
        case .horizontal:
            rect.width
        case .vertical:
            rect.height
        }
    }

    func origin(of rect: CGRect) -> CGFloat {
        switch orientation {
        case .horizontal:
            rect.minX
        case .vertical:
            rect.minY
        }
    }

    func area(for mode: SizingMode) -> CGRect {
        mode.isMaximized ? parent : working
    }
}

extension SizingMode {
    var isMaximized: Bool {
        self == .maximized
    }

    var isFullscreen: Bool {
        self == .fullscreen
    }
}

extension NiriContainer {
    var effectiveSizingMode: SizingMode {
        var anyFullscreen = false
        var anyMaximized = false
        for window in windowNodes {
            switch window.sizingMode {
            case .normal:
                continue
            case .maximized:
                anyMaximized = true
            case .fullscreen:
                anyFullscreen = true
            }
        }

        if anyFullscreen {
            return .fullscreen
        } else if anyMaximized {
            return .maximized
        } else {
            return .normal
        }
    }
}

extension ViewportState {
    func columnX(at index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        containerPosition(at: index, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
    }

    func totalWidth(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        totalSpan(containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
    }

    func containerPosition(
        at index: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        var pos: CGFloat = 0
        for i in 0 ..< index {
            guard i < containers.count else { break }
            pos += containers[i][keyPath: sizeKeyPath] + gap
        }
        return pos
    }

    func totalSpan(containers: [NiriContainer], gap: CGFloat, sizeKeyPath: KeyPath<NiriContainer, CGFloat>) -> CGFloat {
        guard !containers.isEmpty else { return 0 }
        let sizeSum = containers.reduce(0) { $0 + $1[keyPath: sizeKeyPath] }
        let gapSum = CGFloat(max(0, containers.count - 1)) * gap
        return sizeSum + gapSum
    }

    func normalizedFittingAreas(
        viewportSpan: CGFloat,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        orientation: Monitor.Orientation = .horizontal,
        scale: CGFloat = 2.0
    ) -> ViewportFittingAreas {
        let crossSpan: CGFloat = switch orientation {
        case .horizontal:
            workingArea?.height ?? viewFrame?.height ?? 0
        case .vertical:
            workingArea?.width ?? viewFrame?.width ?? 0
        }
        let fallbackParentFrame: CGRect = switch orientation {
        case .horizontal:
            CGRect(x: 0, y: 0, width: viewportSpan, height: crossSpan)
        case .vertical:
            CGRect(x: 0, y: 0, width: crossSpan, height: viewportSpan)
        }
        let parentFrame = viewFrame ?? workingArea ?? fallbackParentFrame

        let localWorking: CGRect
        if let workingArea {
            localWorking = CGRect(
                origin: .zero,
                size: workingArea.size
            )
        } else {
            localWorking = CGRect(origin: .zero, size: parentFrame.size)
        }

        let parent: CGRect
        if let workingArea {
            parent = CGRect(
                x: parentFrame.minX - workingArea.minX,
                y: parentFrame.minY - workingArea.minY,
                width: parentFrame.width,
                height: parentFrame.height
            )
        } else {
            parent = CGRect(
                origin: .zero,
                size: parentFrame.size
            )
        }

        let fallbackLocalSize = workingArea?.size ?? fallbackParentFrame.size
        let fallbackLocalFrame = CGRect(origin: .zero, size: fallbackLocalSize)
        let primarySpan: (CGRect) -> CGFloat = { rect in
            switch orientation {
            case .horizontal:
                rect.width
            case .vertical:
                rect.height
            }
        }

        return ViewportFittingAreas(
            working: primarySpan(localWorking) > 0 ? localWorking : fallbackLocalFrame,
            parent: primarySpan(parent) > 0 ? parent : fallbackLocalFrame,
            orientation: orientation,
            scale: scale
        )
    }

    func computeCenteredOffset(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        orientation: Monitor.Orientation = .horizontal,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return 0 }

        let areas = normalizedFittingAreas(
            viewportSpan: viewportSpan,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: orientation,
            scale: scale
        )
        let targetPos = containerPosition(
            at: containerIndex,
            containers: containers,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let targetSize = containers[containerIndex][keyPath: sizeKeyPath]
        let mode = containers[containerIndex].effectiveSizingMode

        return computeModeAwareCenteredOffset(
            currentViewStart: targetPos,
            targetPos: targetPos,
            targetSpan: targetSize,
            mode: mode,
            areas: areas,
            gap: gap
        )
    }

    private func computeFitOffset(
        currentViewPos: CGFloat,
        viewSpan: CGFloat,
        targetPos: CGFloat,
        targetSpan: CGFloat,
        gap: CGFloat,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)

        if viewSpan <= targetSpan + pixelEpsilon {
            return 0
        }

        let padding = ((viewSpan - targetSpan) / 2).clamped(to: 0 ... gap)
        let preferredStart = targetPos - padding
        let targetEnd = targetPos + targetSpan
        let preferredEnd = targetEnd + padding

        if currentViewPos - pixelEpsilon <= preferredStart
            && preferredEnd <= currentViewPos + viewSpan + pixelEpsilon
        {
            return currentViewPos - targetPos
        }

        let distToStart = abs(currentViewPos - preferredStart)
        let distToEnd = abs((currentViewPos + viewSpan) - preferredEnd)

        if distToStart <= distToEnd {
            return -padding
        } else {
            return -(viewSpan - padding - targetSpan)
        }
    }

    func computeModeAwareFitOffset(
        currentViewStart: CGFloat,
        targetPos: CGFloat,
        targetSpan: CGFloat,
        mode: SizingMode,
        areas: ViewportFittingAreas,
        gap: CGFloat
    ) -> CGFloat {
        if mode.isFullscreen {
            return 0
        }

        let area = areas.area(for: mode)
        let areaStart = areas.origin(of: area)
        let padding = mode.isMaximized ? 0 : gap
        let newOffset = computeFitOffset(
            currentViewPos: currentViewStart + areaStart,
            viewSpan: areas.span(of: area),
            targetPos: targetPos,
            targetSpan: targetSpan,
            gap: padding,
            scale: areas.scale
        )
        return newOffset - areaStart
    }

    func computeModeAwareCenteredOffset(
        currentViewStart: CGFloat,
        targetPos: CGFloat,
        targetSpan: CGFloat,
        mode: SizingMode,
        areas: ViewportFittingAreas,
        gap: CGFloat
    ) -> CGFloat {
        if mode.isFullscreen {
            return computeModeAwareFitOffset(
                currentViewStart: currentViewStart,
                targetPos: targetPos,
                targetSpan: targetSpan,
                mode: mode,
                areas: areas,
                gap: gap
            )
        }

        let area = areas.area(for: mode)
        let areaSpan = areas.span(of: area)
        let areaStart = areas.origin(of: area)
        if areaSpan <= targetSpan {
            return computeModeAwareFitOffset(
                currentViewStart: currentViewStart,
                targetPos: targetPos,
                targetSpan: targetSpan,
                mode: mode,
                areas: areas,
                gap: gap
            )
        }

        return -(areaSpan - targetSpan) / 2 - areaStart
    }

    func viewportStartBounds(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        edgeVisibleFraction: CGFloat = 0.05
    ) -> ClosedRange<CGFloat> {
        guard !columns.isEmpty, viewportWidth > 0 else { return 0 ... 0 }

        let fraction = edgeVisibleFraction.clamped(to: 0 ... 1)
        let firstWidth = max(0, columns.first?.cachedWidth ?? 0)
        let lastWidth = max(0, columns.last?.cachedWidth ?? 0)
        let total = totalWidth(columns: columns, gap: gap)

        // Allow intentional edge overscroll: at the farthest point only a small sliver
        // of the edge column remains visible on the opposite viewport edge. The gap
        // keeps the visible sliver inside the layout boundary instead of flush to screen.
        let lower = firstWidth * fraction + gap - viewportWidth
        let upper = total - lastWidth * fraction - gap
        return min(lower, upper) ... max(lower, upper)
    }

    func boundedViewportStart(
        _ viewportStart: CGFloat,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        viewportStart.clamped(to: viewportStartBounds(columns: columns, gap: gap, viewportWidth: viewportWidth))
    }

    func boundedViewOffset(
        targetViewStart: CGFloat,
        activeColumnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        guard columns.indices.contains(activeColumnIndex) else { return 0 }
        let activeX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        return boundedViewportStart(
            targetViewStart,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        ) - activeX
    }

    func snapContext(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        pixelTolerance: CGFloat = 0.5
    ) -> ViewportSnapContext {
        ViewportSnapContext(
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            snapPoints: computeSnapGrid(
                columns: columns,
                gap: gap,
                viewportWidth: viewportWidth,
                pixelTolerance: pixelTolerance
            )
        )
    }

    func computeSnapGrid(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        pixelTolerance: CGFloat = 0.5
    ) -> [SnapPoint] {
        guard !columns.isEmpty, viewportWidth > 0 else { return [] }

        func bounded(_ offset: CGFloat) -> CGFloat {
            boundedViewportStart(offset, columns: columns, gap: gap, viewportWidth: viewportWidth)
        }

        var points: [SnapPoint] = []
        var columnX: CGFloat = 0
        for (index, column) in columns.enumerated() {
            let width = column.cachedWidth
            guard width.isFinite, width > 0 else {
                columnX += max(0, width.isFinite ? width : 0) + gap
                continue
            }

            points.append(SnapPoint(offset: bounded(columnX - gap), columnIndex: index, kind: .leftEdge))
            points.append(SnapPoint(offset: bounded(columnX + width + gap - viewportWidth), columnIndex: index, kind: .rightEdge))
            if width > 0.30 * viewportWidth {
                points.append(SnapPoint(
                    offset: bounded(columnX + width / 2 - viewportWidth / 2),
                    columnIndex: index,
                    kind: .center
                ))
            }

            columnX += width + gap
        }

        let bounds = viewportStartBounds(columns: columns, gap: gap, viewportWidth: viewportWidth)
        points.append(SnapPoint(offset: bounds.lowerBound, columnIndex: 0, kind: .rightEdge))
        points.append(SnapPoint(offset: bounds.upperBound, columnIndex: columns.count - 1, kind: .leftEdge))

        return points.sortedAndDeduped(pixelTolerance: pixelTolerance)
    }

    func columnVisibility(
        for index: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportOffset: CGFloat,
        viewportWidth: CGFloat,
        preParkMargin: CGFloat = niriViewportPreParkMargin,
        pixelTolerance: CGFloat = 0.5
    ) -> ColumnVisibility {
        guard columns.indices.contains(index), viewportWidth > 0 else { return .parked(.minimum) }

        let columnStart = columnX(at: index, columns: columns, gap: gap)
        let columnEnd = columnStart + columns[index].cachedWidth
        let viewportStart = viewportOffset
        let viewportEnd = viewportOffset + viewportWidth

        if columnEnd <= viewportStart + preParkMargin {
            return .parked(.minimum)
        }
        if columnStart >= viewportEnd - preParkMargin {
            return .parked(.maximum)
        }
        if columnStart >= viewportStart - pixelTolerance,
           columnEnd <= viewportEnd + pixelTolerance
        {
            return .fullyVisible
        }
        return .clipped(columnStart < viewportStart ? .minimum : .maximum)
    }


    func computeCenteredOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        let targetOffset = computeCenteredOffset(
            containerIndex: columnIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: .horizontal,
            scale: scale
        )
        return boundedViewOffset(
            targetViewStart: columnX(at: columnIndex, columns: columns, gap: gap) + targetOffset,
            activeColumnIndex: columnIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )
    }


}
