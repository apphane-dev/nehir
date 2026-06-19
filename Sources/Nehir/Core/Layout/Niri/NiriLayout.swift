import AppKit
import Foundation

extension CGFloat {
    func roundedToPhysicalPixel(scale: CGFloat) -> CGFloat {
        (self * scale).rounded() / scale
    }
}

extension CGPoint {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGPoint {
        CGPoint(
            x: x.roundedToPhysicalPixel(scale: scale),
            y: y.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGSize {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGSize {
        CGSize(
            width: width.roundedToPhysicalPixel(scale: scale),
            height: height.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGRect {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGRect {
        CGRect(
            origin: origin.roundedToPhysicalPixels(scale: scale),
            size: size.roundedToPhysicalPixels(scale: scale)
        )
    }
}

struct LayoutResult {
    let frames: [WindowToken: CGRect]
    let hiddenHandles: [WindowToken: HideSide]
}

struct SingleWindowViewportGeometry {
    static let centeredOffsetEpsilon: CGFloat = 0.001

    let rect: CGRect
    let centerOffset: CGFloat

    func effectiveViewOffset(_ offset: CGFloat) -> CGFloat {
        // Render at the raw viewport offset so the lone window is responsive to scroll
        // gestures exactly like a regular single column. Where it settles is governed by
        // the snap grid / viewportStartBounds (shared with regular columns), not by a
        // render-time clamp. A separate clamp here would desync render from gesture state
        // (making gestures feel ignored) and leave stale offsets.
        offset
    }

    func renderedRect(
        viewOffset: CGFloat,
        workspaceOffset: CGFloat = 0,
        renderOffset: CGPoint = .zero,
        scale: CGFloat
    ) -> CGRect {
        rect
            .offsetBy(
                dx: workspaceOffset - effectiveViewOffset(viewOffset) + renderOffset.x,
                dy: renderOffset.y
            )
            .roundedToPhysicalPixels(scale: scale)
    }
}

private enum ContainerVisibilityState {
    case visible
    case hidden(AxisHideEdge)
}

private struct ContainerOverflowRegion {
    let edge: AxisHideEdge
    let rect: CGRect
}

extension NiriLayoutEngine {
    func calculateLayout(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal
    ) -> [WindowToken: CGRect] {
        calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation
        ).frames
    }

    func calculateLayoutWithVisibility(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = []
    ) -> LayoutResult {
        var frames: [WindowToken: CGRect] = [:]
        var hiddenHandles: [WindowToken: HideSide] = [:]
        calculateLayoutInto(
            frames: &frames,
            hiddenHandles: &hiddenHandles,
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation,
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        )
        return LayoutResult(frames: frames, hiddenHandles: hiddenHandles)
    }

    func calculateLayoutInto(
        frames: inout [WindowToken: CGRect],
        hiddenHandles: inout [WindowToken: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = []
    ) {
        let containers = columns(in: workspaceId)
        guard !containers.isEmpty else { return }

        let workingFrame = workingArea?.workingFrame ?? monitorFrame
        let viewFrame = workingArea?.viewFrame ?? screenFrame ?? monitorFrame
        let effectiveScale = workingArea?.scale ?? scale

        let primaryGap: CGFloat
        let secondaryGap: CGFloat
        switch orientation {
        case .horizontal:
            primaryGap = gaps.horizontal
            secondaryGap = gaps.vertical
        case .vertical:
            primaryGap = gaps.vertical
            secondaryGap = gaps.horizontal
        }

        let time = animationTime ?? CACurrentMediaTime()
        let workspaceOffset: CGFloat = 0
        let canonicalFullscreenRect = workingFrame.roundedToPhysicalPixels(scale: effectiveScale)
        let renderedFullscreenRect = canonicalFullscreenRect
            .offsetBy(dx: workspaceOffset, dy: 0)
            .roundedToPhysicalPixels(scale: effectiveScale)

        if let singleWindowContext = singleWindowLayoutContext(in: workspaceId) {
            for container in containers {
                container.usesOverflowTabbedMode = false
            }
            layoutSingleWindowWorkspace(
                singleWindowContext,
                state: state,
                workingFrame: workingFrame,
                containingFrame: viewFrame,
                fullscreenRect: canonicalFullscreenRect,
                renderedFullscreenRect: renderedFullscreenRect,
                workspaceOffset: workspaceOffset,
                scale: effectiveScale,
                gaps: gaps.horizontal,
                time: time,
                result: &frames,
                orientation: orientation
            )
            return
        }

        for container in containers {
            container.clearLoneWindowLayoutWidthOverride()
            switch orientation {
            case .horizontal:
                if container.cachedWidth <= 0 {
                    container.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: primaryGap)
                }
            case .vertical:
                if container.cachedHeight <= 0 {
                    container.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: primaryGap)
                }
            }
        }

        let availableStackSpan: CGFloat = switch orientation {
        case .horizontal: workingFrame.height
        case .vertical: workingFrame.width
        }
        for container in containers {
            container.usesOverflowTabbedMode = shouldUseStackOverflowTabbedMode(
                container: container,
                availableSpan: availableStackSpan,
                secondaryGap: secondaryGap,
                orientation: orientation
            )
        }

        let containerSpans: [CGFloat] = switch orientation {
        case .horizontal: containers.map { $0.cachedWidth }
        case .vertical: containers.map { $0.cachedHeight }
        }
        let containerRenderOffsets = containers.map { $0.renderOffset(at: time) }
        let containerWindowNodes = containers.map { $0.windowNodes }

        var containerPositions = [CGFloat]()
        containerPositions.reserveCapacity(containers.count)
        var runningPos: CGFloat = 0
        for i in 0 ..< containers.count {
            containerPositions.append(runningPos)
            let span = containerSpans[i]
            runningPos += span + primaryGap
        }

        let viewOffset = state.viewOffsetPixels.value(at: time)
        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, containers.count - 1))
        let activePos = containers.isEmpty ? 0 : containerPositions[activeIdx]
        let viewPos = activePos + viewOffset

        for idx in 0 ..< containers.count {
            let containerPos = containerPositions[idx]
            let containerSpan = containerSpans[idx]
            let renderOffset = containerRenderOffsets[idx]
            let canonicalContainerRect = canonicalContainerRect(
                position: containerPos,
                span: containerSpan,
                workingFrame: workingFrame,
                scale: effectiveScale,
                orientation: orientation
            )
            let visibilityRect = visibleRenderedContainerRect(
                canonicalRect: canonicalContainerRect,
                viewPosition: viewPos,
                workspaceOffset: workspaceOffset,
                renderOffset: renderOffset,
                scale: effectiveScale,
                orientation: orientation
            )
            let renderedContainerRect: CGRect
            switch containerVisibilityState(
                for: visibilityRect,
                viewportFrame: workingFrame,
                fallback: idx == 0 ? .minimum : .maximum,
                orientation: orientation,
                hiddenPlacementMonitor: hiddenPlacementMonitor,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            ) {
            case .visible:
                renderedContainerRect = visibilityRect
            case let .hidden(hiddenEdge):
                for window in containerWindowNodes[idx] {
                    hiddenHandles[window.token] = hiddenEdge.encodedHideSide
                }
                renderedContainerRect = hiddenRenderedContainerRect(
                    canonicalRect: canonicalContainerRect,
                    edge: hiddenEdge,
                    viewFrame: viewFrame,
                    scale: effectiveScale,
                    orientation: orientation,
                    hiddenPlacementMonitor: hiddenPlacementMonitor,
                    hiddenPlacementMonitors: hiddenPlacementMonitors
                )
            }

            layoutContainer(
                container: containers[idx],
                canonicalContainerRect: canonicalContainerRect,
                renderedContainerRect: renderedContainerRect,
                fullscreenRect: canonicalFullscreenRect,
                renderedFullscreenRect: renderedFullscreenRect,
                secondaryGap: secondaryGap,
                scale: effectiveScale,
                animationTime: time,
                result: &frames,
                orientation: orientation
            )
        }
    }

    private func canonicalContainerRect(
        position: CGFloat,
        span: CGFloat,
        workingFrame: CGRect,
        scale: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            let width = span.roundedToPhysicalPixel(scale: scale)
            return CGRect(
                x: workingFrame.origin.x + position,
                y: workingFrame.origin.y,
                width: width,
                height: workingFrame.height
            ).roundedToPhysicalPixels(scale: scale)
        case .vertical:
            let height = span.roundedToPhysicalPixel(scale: scale)
            return CGRect(
                x: workingFrame.origin.x,
                y: workingFrame.origin.y + position,
                width: workingFrame.width,
                height: height
            ).roundedToPhysicalPixels(scale: scale)
        }
    }

    private func visibleRenderedContainerRect(
        canonicalRect: CGRect,
        viewPosition: CGFloat,
        workspaceOffset: CGFloat,
        renderOffset: CGPoint,
        scale: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect {
        let translation: CGPoint = switch orientation {
        case .horizontal:
            CGPoint(
                x: -viewPosition + workspaceOffset + renderOffset.x,
                y: renderOffset.y
            )
        case .vertical:
            CGPoint(
                x: workspaceOffset + renderOffset.x,
                y: -viewPosition + renderOffset.y
            )
        }
        return canonicalRect.offsetBy(dx: translation.x, dy: translation.y)
            .roundedToPhysicalPixels(scale: scale)
    }

    private func containerVisibilityState(
        for renderedRect: CGRect,
        viewportFrame: CGRect,
        fallback: AxisHideEdge,
        orientation: Monitor.Orientation,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> ContainerVisibilityState {
        let defaultHideEdge = hiddenEdge(
            for: renderedRect,
            viewportFrame: viewportFrame,
            fallback: fallback,
            orientation: orientation
        )
        guard containerIntersectsViewport(
            renderedRect,
            viewportFrame: viewportFrame,
            orientation: orientation
        ) else {
            return .hidden(defaultHideEdge)
        }
        if let overflowEdge = overflowEdgeIntersectingNeighboringMonitor(
            renderedRect,
            viewportFrame: viewportFrame,
            orientation: orientation,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) {
            return .hidden(overflowEdge)
        }
        return .visible
    }

    private func containerIntersectsViewport(
        _ containerRect: CGRect,
        viewportFrame: CGRect,
        orientation: Monitor.Orientation
    ) -> Bool {
        let preParkMargin = niriViewportPreParkMargin
        switch orientation {
        case .horizontal:
            return containerRect.maxX > viewportFrame.minX + preParkMargin
                && containerRect.minX < viewportFrame.maxX - preParkMargin
        case .vertical:
            return containerRect.maxY > viewportFrame.minY + preParkMargin
                && containerRect.minY < viewportFrame.maxY - preParkMargin
        }
    }

    private func overflowEdgeIntersectingNeighboringMonitor(
        _ renderedRect: CGRect,
        viewportFrame: CGRect,
        orientation: Monitor.Orientation,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> AxisHideEdge? {
        let overflowRegions = containerOverflowRegions(
            for: renderedRect,
            viewportFrame: viewportFrame,
            orientation: orientation
        )
        guard !overflowRegions.isEmpty else { return nil }

        for overflowRegion in overflowRegions {
            for otherMonitor in hiddenPlacementMonitors where !ownsViewport(
                otherMonitor,
                hiddenPlacementMonitor: hiddenPlacementMonitor,
                viewportFrame: viewportFrame
            ) {
                if overflowRegion.rect.intersects(otherMonitor.frame) {
                    return overflowRegion.edge
                }
            }
        }

        return nil
    }

    private func containerOverflowRegions(
        for renderedRect: CGRect,
        viewportFrame: CGRect,
        orientation: Monitor.Orientation
    ) -> [ContainerOverflowRegion] {
        var overflowRegions: [ContainerOverflowRegion] = []
        overflowRegions.reserveCapacity(2)

        switch orientation {
        case .horizontal:
            if renderedRect.minX < viewportFrame.minX {
                let overflowMaxX = min(renderedRect.maxX, viewportFrame.minX)
                if overflowMaxX > renderedRect.minX {
                    overflowRegions.append(
                        ContainerOverflowRegion(
                            edge: .minimum,
                            rect: CGRect(
                                x: renderedRect.minX,
                                y: renderedRect.minY,
                                width: overflowMaxX - renderedRect.minX,
                                height: renderedRect.height
                            )
                        )
                    )
                }
            }
            if renderedRect.maxX > viewportFrame.maxX {
                let overflowMinX = max(renderedRect.minX, viewportFrame.maxX)
                if renderedRect.maxX > overflowMinX {
                    overflowRegions.append(
                        ContainerOverflowRegion(
                            edge: .maximum,
                            rect: CGRect(
                                x: overflowMinX,
                                y: renderedRect.minY,
                                width: renderedRect.maxX - overflowMinX,
                                height: renderedRect.height
                            )
                        )
                    )
                }
            }
        case .vertical:
            if renderedRect.minY < viewportFrame.minY {
                let overflowMaxY = min(renderedRect.maxY, viewportFrame.minY)
                if overflowMaxY > renderedRect.minY {
                    overflowRegions.append(
                        ContainerOverflowRegion(
                            edge: .minimum,
                            rect: CGRect(
                                x: renderedRect.minX,
                                y: renderedRect.minY,
                                width: renderedRect.width,
                                height: overflowMaxY - renderedRect.minY
                            )
                        )
                    )
                }
            }
            if renderedRect.maxY > viewportFrame.maxY {
                let overflowMinY = max(renderedRect.minY, viewportFrame.maxY)
                if renderedRect.maxY > overflowMinY {
                    overflowRegions.append(
                        ContainerOverflowRegion(
                            edge: .maximum,
                            rect: CGRect(
                                x: renderedRect.minX,
                                y: overflowMinY,
                                width: renderedRect.width,
                                height: renderedRect.maxY - overflowMinY
                            )
                        )
                    )
                }
            }
        }

        return overflowRegions
    }

    private func ownsViewport(
        _ candidateMonitor: HiddenPlacementMonitorContext,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        viewportFrame: CGRect
    ) -> Bool {
        if let hiddenPlacementMonitor {
            return candidateMonitor.id == hiddenPlacementMonitor.id
        }

        return candidateMonitor.frame.intersects(viewportFrame)
            || candidateMonitor.visibleFrame.intersects(viewportFrame)
    }

    private func hiddenEdge(
        for renderedRect: CGRect,
        viewportFrame: CGRect,
        fallback: AxisHideEdge,
        orientation: Monitor.Orientation
    ) -> AxisHideEdge {
        switch orientation {
        case .horizontal:
            let leftOverflow = viewportFrame.minX - renderedRect.minX
            let rightOverflow = renderedRect.maxX - viewportFrame.maxX
            if leftOverflow > rightOverflow, leftOverflow > 0 {
                return .minimum
            }
            if rightOverflow > leftOverflow, rightOverflow > 0 {
                return .maximum
            }
        case .vertical:
            let topOverflow = viewportFrame.minY - renderedRect.minY
            let bottomOverflow = renderedRect.maxY - viewportFrame.maxY
            if topOverflow > bottomOverflow, topOverflow > 0 {
                return .minimum
            }
            if bottomOverflow > topOverflow, bottomOverflow > 0 {
                return .maximum
            }
        }
        return fallback
    }

    private func hiddenRenderedContainerRect(
        canonicalRect: CGRect,
        edge: AxisHideEdge,
        viewFrame: CGRect,
        scale: CGFloat,
        orientation: Monitor.Orientation,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            if let hiddenPlacementMonitor {
                return HiddenWindowPlacementResolver.placement(
                    for: canonicalRect.size,
                    requestedEdge: edge,
                    orthogonalOrigin: canonicalRect.minY,
                    baseReveal: 1.0,
                    scale: scale,
                    orientation: .horizontal,
                    monitor: hiddenPlacementMonitor,
                    monitors: hiddenPlacementMonitors
                )
                .frame(for: canonicalRect.size)
                .roundedToPhysicalPixels(scale: scale)
            }

            return hiddenColumnRect(
                edge: edge,
                width: canonicalRect.width,
                height: canonicalRect.height,
                screenY: canonicalRect.minY,
                edgeFrame: viewFrame,
                scale: scale
            ).roundedToPhysicalPixels(scale: scale)
        case .vertical:
            if let hiddenPlacementMonitor {
                return HiddenWindowPlacementResolver.placement(
                    for: canonicalRect.size,
                    requestedEdge: edge,
                    orthogonalOrigin: canonicalRect.minX,
                    baseReveal: 1.0,
                    scale: scale,
                    orientation: .vertical,
                    monitor: hiddenPlacementMonitor,
                    monitors: hiddenPlacementMonitors
                )
                .frame(for: canonicalRect.size)
                .roundedToPhysicalPixels(scale: scale)
            }

            return hiddenRowRect(
                edge: edge,
                width: canonicalRect.width,
                height: canonicalRect.height,
                screenX: canonicalRect.minX,
                edgeFrame: viewFrame,
                scale: scale
            ).roundedToPhysicalPixels(scale: scale)
        }
    }

    func centeredLoneWindowRect(
        maxWidthFraction: Double,
        workingFrame: CGRect,
        scale: CGFloat
    ) -> CGRect {
        guard workingFrame.width > 0,
              workingFrame.height > 0
        else {
            return workingFrame.roundedToPhysicalPixels(scale: scale)
        }

        let width = workingFrame.width * CGFloat(maxWidthFraction.clamped(to: 0.0 ... 1.0))
        return centeredLoneWindowRect(
            in: workingFrame,
            containingFrame: workingFrame,
            width: width,
            constraints: .unconstrained,
            scale: scale
        )
    }

    private func centeredLoneWindowRect(
        in workingFrame: CGRect,
        containingFrame: CGRect,
        width: CGFloat,
        constraints: WindowSizeConstraints,
        scale: CGFloat
    ) -> CGRect {
        let size = resolvedSingleWindowSize(
            width: width,
            workingFrame: workingFrame,
            constraints: constraints
        )
        let unclamped = CGRect(
            x: workingFrame.midX - size.width / 2,
            y: workingFrame.minY,
            width: size.width,
            height: size.height
        )
        return clampRect(unclamped, to: containingFrame).roundedToPhysicalPixels(scale: scale)
    }

    private func resolvedSingleWindowSize(
        width: CGFloat,
        workingFrame: CGRect,
        constraints: WindowSizeConstraints
    ) -> CGSize {
        CGSize(
            width: constraints.clampWidth(width),
            height: constraints.clampHeight(workingFrame.height)
        )
    }

    private func clampRect(_ rect: CGRect, to containingFrame: CGRect) -> CGRect {
        guard containingFrame.width > 0,
              containingFrame.height > 0
        else { return rect }

        let clampedX: CGFloat
        let maxX = containingFrame.maxX - rect.width
        if maxX >= containingFrame.minX {
            clampedX = min(max(rect.minX, containingFrame.minX), maxX)
        } else {
            clampedX = containingFrame.minX
        }

        let clampedY: CGFloat
        let maxY = containingFrame.maxY - rect.height
        if maxY >= containingFrame.minY {
            clampedY = min(max(rect.minY, containingFrame.minY), maxY)
        } else {
            clampedY = containingFrame.minY
        }

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: rect.width,
            height: rect.height
        )
    }

    private func resolvedSingleWindowWidth(
        for context: SingleWindowLayoutContext,
        in workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        if context.container.cachedWidth <= 0 {
            context.container.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
        }

        guard context.container.hasManualSingleWindowWidthOverride else {
            return workingFrame.width * CGFloat(context.maxWidthFraction.clamped(to: 0.0 ... 1.0))
        }

        return max(0, context.container.cachedWidth)
    }

    func resolvedSingleWindowRect(
        for context: SingleWindowLayoutContext,
        in workingFrame: CGRect,
        containingFrame: CGRect? = nil,
        scale: CGFloat,
        gaps: CGFloat
    ) -> CGRect {
        let containingFrame = containingFrame ?? workingFrame
        let resolvedWidth = resolvedSingleWindowWidth(for: context, in: workingFrame, gaps: gaps)
        guard resolvedWidth > 0 else {
            return workingFrame.roundedToPhysicalPixels(scale: scale)
        }

        return centeredLoneWindowRect(
            in: workingFrame,
            containingFrame: containingFrame,
            width: resolvedWidth,
            constraints: context.window.constraints,
            scale: scale
        )
    }

    func singleWindowViewportGeometry(
        for context: SingleWindowLayoutContext,
        in workingFrame: CGRect,
        containingFrame: CGRect? = nil,
        scale: CGFloat,
        gaps: CGFloat
    ) -> SingleWindowViewportGeometry {
        let containingFrame = containingFrame ?? workingFrame
        let resolvedWidth = resolvedSingleWindowWidth(for: context, in: workingFrame, gaps: gaps)
        guard resolvedWidth > 0 else {
            let rect = workingFrame.roundedToPhysicalPixels(scale: scale)
            return SingleWindowViewportGeometry(rect: rect, centerOffset: 0)
        }

        let size = resolvedSingleWindowSize(
            width: resolvedWidth,
            workingFrame: workingFrame,
            constraints: context.window.constraints
        )
        let unclampedYRect = CGRect(
            x: workingFrame.minX,
            y: workingFrame.minY,
            width: size.width,
            height: size.height
        )
        let yClampedRect = clampRect(
            CGRect(
                x: containingFrame.minX,
                y: unclampedYRect.minY,
                width: min(size.width, containingFrame.width),
                height: size.height
            ),
            to: containingFrame
        )
        // For over-constrained lone windows (min size exceeds the working frame), clamp
        // the rect to the containing (visible) frame so it does not leak offscreen. For
        // normal fill/centered windows, keep the working-frame origin and desired size.
        let overConstrained = size.width > workingFrame.width || size.height > workingFrame.height
        let rect: CGRect
        if overConstrained {
            rect = yClampedRect.roundedToPhysicalPixels(scale: scale)
        } else {
            rect = CGRect(
                x: workingFrame.minX,
                y: yClampedRect.minY,
                width: size.width,
                height: size.height
            ).roundedToPhysicalPixels(scale: scale)
        }
        return SingleWindowViewportGeometry(
            rect: rect,
            centerOffset: (rect.width - workingFrame.width) / 2
        )
    }

    func resolvedSingleWindowViewportRect(
        for context: SingleWindowLayoutContext,
        in workingFrame: CGRect,
        containingFrame: CGRect? = nil,
        scale: CGFloat,
        gaps: CGFloat
    ) -> CGRect {
        singleWindowViewportGeometry(
            for: context,
            in: workingFrame,
            containingFrame: containingFrame,
            scale: scale,
            gaps: gaps
        ).rect
    }

    @discardableResult
    func prepareSingleWindowViewport(
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        containingFrame: CGRect? = nil,
        scale: CGFloat = 2.0,
        gaps: CGFloat
    ) -> SingleWindowViewportGeometry? {
        guard let context = singleWindowLayoutContext(in: workspaceId) else { return nil }
        let geometry = singleWindowViewportGeometry(
            for: context,
            in: workingFrame,
            containingFrame: containingFrame,
            scale: scale,
            gaps: gaps
        )
        if context.container.hasManualSingleWindowWidthOverride {
            context.container.clearLoneWindowLayoutWidthOverride()
        } else {
            context.container.loneWindowLayoutWidthOverride = geometry.rect.width
        }
        return geometry
    }

    func seedSingleWindowCenterOffsetIfNeeded(
        _ geometry: SingleWindowViewportGeometry?,
        state: inout ViewportState
    ) {
        // Only seed the centered offset from a genuine initial (zero) viewport state.
        // Never overwrite an explicit side-snap or in-flight gesture offset — those are
        // valid positions within the scrollable range and should survive relayouts.
        guard let geometry,
              !state.viewOffsetPixels.isGesture,
              abs(state.viewOffsetPixels.current()) < SingleWindowViewportGeometry.centeredOffsetEpsilon
        else { return }
        state.viewOffsetPixels = .static(geometry.centerOffset)
    }

    @discardableResult
    func prepareAndSeedSingleWindowViewport(
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        containingFrame: CGRect? = nil,
        scale: CGFloat = 2.0,
        gaps: CGFloat,
        state: inout ViewportState
    ) -> SingleWindowViewportGeometry? {
        let geometry = prepareSingleWindowViewport(
            in: workspaceId,
            workingFrame: workingFrame,
            containingFrame: containingFrame,
            scale: scale,
            gaps: gaps
        )
        seedSingleWindowCenterOffsetIfNeeded(geometry, state: &state)
        return geometry
    }

    private func layoutSingleWindowWorkspace(
        _ context: SingleWindowLayoutContext,
        state: ViewportState,
        workingFrame: CGRect,
        containingFrame: CGRect,
        fullscreenRect: CGRect,
        renderedFullscreenRect: CGRect,
        workspaceOffset: CGFloat,
        scale: CGFloat,
        gaps: CGFloat,
        time: TimeInterval,
        result: inout [WindowToken: CGRect],
        orientation: Monitor.Orientation
    ) {
        let geometry = singleWindowViewportGeometry(
            for: context,
            in: workingFrame,
            containingFrame: containingFrame,
            scale: scale,
            gaps: gaps
        )
        let canonicalRect = geometry.rect
        if context.container.hasManualSingleWindowWidthOverride {
            context.container.clearLoneWindowLayoutWidthOverride()
        } else {
            context.container.loneWindowLayoutWidthOverride = canonicalRect.width
        }
        let renderOffset = context.container.renderOffset(at: time)
        let renderedRect = geometry.renderedRect(
            viewOffset: state.viewOffsetPixels.value(at: time),
            workspaceOffset: workspaceOffset,
            renderOffset: renderOffset,
            scale: scale
        )

        layoutContainer(
            container: context.container,
            canonicalContainerRect: canonicalRect,
            renderedContainerRect: renderedRect,
            fullscreenRect: fullscreenRect,
            renderedFullscreenRect: renderedFullscreenRect,
            secondaryGap: 0,
            scale: scale,
            animationTime: time,
            result: &result,
            orientation: orientation
        )
    }

    private func shouldUseStackOverflowTabbedMode(
        container: NiriContainer,
        availableSpan: CGFloat,
        secondaryGap: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        guard !container.isTabbed else { return false }

        let windows = container.windowNodes
        guard windows.count > 1,
              windows.allSatisfy({ $0.sizingMode == .normal })
        else {
            return false
        }

        let overflow = stackOverflowMetrics(
            windows: windows,
            availableSpan: availableSpan,
            gaps: secondaryGap,
            orientation: orientation
        )

        if overflow.overflows, LayoutTrace.isEnabled {
            LayoutTrace.log(
                "stackOverflow.tabbed column=\(container.id.uuid.uuidString) "
                    + "windows=\(windows.count) "
                    + "required=\(String(format: "%.1f", overflow.requiredSpan)) "
                    + "available=\(String(format: "%.1f", availableSpan)) "
                    + "orientation=\(orientation) "
                    + "active=\(container.activeWindow?.token.windowId.description ?? "nil")"
            )
        }

        return overflow.overflows
    }

    private func layoutContainer(
        container: NiriContainer,
        canonicalContainerRect: CGRect,
        renderedContainerRect: CGRect,
        fullscreenRect: CGRect,
        renderedFullscreenRect: CGRect,
        secondaryGap: CGFloat,
        scale: CGFloat,
        animationTime: TimeInterval? = nil,
        result: inout [WindowToken: CGRect],
        orientation: Monitor.Orientation
    ) {
        container.frame = canonicalContainerRect
        container.renderedFrame = renderedContainerRect

        let isEffectivelyTabbed = container.isEffectivelyTabbed

        let tabOffset = isEffectivelyTabbed ? renderStyle.tabIndicatorWidth : 0
        let contentRect = CGRect(
            x: canonicalContainerRect.origin.x + tabOffset,
            y: canonicalContainerRect.origin.y,
            width: max(0, canonicalContainerRect.width - tabOffset),
            height: canonicalContainerRect.height
        )

        let windows = container.windowNodes
        guard !windows.isEmpty else { return }

        let isTabbed = isEffectivelyTabbed
        let activeTileIdx = windows.isEmpty ? 0 : container.activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        for (idx, window) in windows.enumerated() {
            window.isHiddenInTabbedMode = isTabbed && idx != activeTileIdx
        }

        let time = animationTime ?? CACurrentMediaTime()

        let availableSpace: CGFloat = switch orientation {
        case .horizontal: contentRect.height
        case .vertical: contentRect.width
        }

        let resolvedSpans = resolveWindowSpans(
            windows: windows,
            availableSpace: availableSpace,
            gap: secondaryGap,
            isTabbed: isTabbed,
            orientation: orientation
        )

        let sizingModes = windows.map { $0.sizingMode }
        let windowRenderOffsets = windows.map { $0.renderOffset(at: time) }
        let windowTokens = windows.map { $0.token }

        var pos: CGFloat = switch orientation {
        case .horizontal: contentRect.origin.y
        case .vertical: contentRect.origin.x
        }

        for i in 0 ..< windows.count {
            let span = resolvedSpans[i]
            let sizingMode = sizingModes[i]

            let frame: CGRect
            let renderedBaseFrame: CGRect
            let resolvedSpan: CGFloat
            switch sizingMode {
            case .fullscreen,
                 .maximized:
                frame = fullscreenRect.roundedToPhysicalPixels(scale: scale)
                renderedBaseFrame = renderedFullscreenRect
                resolvedSpan = switch orientation {
                case .horizontal: frame.height
                case .vertical: frame.width
                }
            case .normal:
                switch orientation {
                case .horizontal:
                    frame = CGRect(
                        x: contentRect.origin.x,
                        y: pos,
                        width: contentRect.width,
                        height: span
                    ).roundedToPhysicalPixels(scale: scale)
                case .vertical:
                    frame = CGRect(
                        x: pos,
                        y: contentRect.origin.y,
                        width: span,
                        height: contentRect.height
                    ).roundedToPhysicalPixels(scale: scale)
                }
                renderedBaseFrame = frame.offsetBy(
                    dx: renderedContainerRect.origin.x - canonicalContainerRect.origin.x,
                    dy: renderedContainerRect.origin.y - canonicalContainerRect.origin.y
                )
                .roundedToPhysicalPixels(scale: scale)
                resolvedSpan = span
            }

            windows[i].frame = frame
            switch orientation {
            case .horizontal:
                windows[i].resolvedHeight = resolvedSpan
            case .vertical:
                windows[i].resolvedWidth = resolvedSpan
            }

            let animatedFrame: CGRect
            switch sizingMode {
            case .fullscreen,
                 .maximized:
                animatedFrame = renderedBaseFrame.roundedToPhysicalPixels(scale: scale)
            case .normal:
                let windowOffset = windowRenderOffsets[i]
                animatedFrame = renderedBaseFrame.offsetBy(dx: windowOffset.x, dy: windowOffset.y)
                    .roundedToPhysicalPixels(scale: scale)
            }
            windows[i].renderedFrame = animatedFrame
            result[windowTokens[i]] = animatedFrame

            if !isTabbed {
                pos += span
                if i < windows.count - 1 {
                    pos += secondaryGap
                }
            }
        }
    }

    private func resolveWindowSpans(
        windows: [NiriWindow],
        availableSpace: CGFloat,
        gap: CGFloat,
        isTabbed: Bool,
        orientation: Monitor.Orientation
    ) -> [CGFloat] {
        guard !windows.isEmpty else { return [] }

        let inputs: [NiriAxisSolver.Input] = windows.map { window in
            switch orientation {
            case .horizontal:
                let isFixed: Bool
                let fixedValue: CGFloat?
                switch window.height {
                case let .fixed(h):
                    isFixed = true
                    fixedValue = h
                case .auto:
                    isFixed = false
                    fixedValue = nil
                case let .preset(index):
                    isFixed = true
                    fixedValue = resolvePresetSpan(
                        presetWindowHeights,
                        index: index,
                        availableSpace: availableSpace,
                        gap: gap
                    )
                }
                return NiriAxisSolver.Input(
                    weight: max(0.1, window.heightWeight),
                    minConstraint: window.constraints.minSize.height,
                    maxConstraint: window.constraints.maxSize.height,
                    hasMaxConstraint: window.constraints.hasMaxHeight,
                    isConstraintFixed: window.constraints.isFixed,
                    hasFixedValue: isFixed,
                    fixedValue: fixedValue
                )
            case .vertical:
                let isFixed: Bool
                let fixedValue: CGFloat?
                switch window.windowWidth {
                case let .fixed(w):
                    isFixed = true
                    fixedValue = w
                case .auto:
                    isFixed = false
                    fixedValue = nil
                case let .preset(index):
                    isFixed = true
                    fixedValue = resolvePresetSpan(
                        presetWindowHeights,
                        index: index,
                        availableSpace: availableSpace,
                        gap: gap
                    )
                }
                return NiriAxisSolver.Input(
                    weight: max(0.1, window.widthWeight),
                    minConstraint: window.constraints.minSize.width,
                    maxConstraint: window.constraints.maxSize.width,
                    hasMaxConstraint: window.constraints.hasMaxWidth,
                    isConstraintFixed: window.constraints.isFixed,
                    hasFixedValue: isFixed,
                    fixedValue: fixedValue
                )
            }
        }

        let outputs = NiriAxisSolver.solve(
            windows: inputs,
            availableSpace: availableSpace,
            gapSize: gap,
            isTabbed: isTabbed
        )

        for (i, output) in outputs.enumerated() {
            switch orientation {
            case .horizontal:
                windows[i].heightFixedByConstraint = output.wasConstrained
            case .vertical:
                windows[i].widthFixedByConstraint = output.wasConstrained
            }
        }

        return outputs.map(\.value)
    }

    private func resolvePresetSpan(
        _ presets: [PresetSize],
        index: Int,
        availableSpace: CGFloat,
        gap: CGFloat
    ) -> CGFloat? {
        guard presets.indices.contains(index) else { return nil }
        switch presets[index].kind {
        case let .proportion(proportion):
            return ProportionalSize.resolveProportionalSpan(
                proportion,
                availableSpace: availableSpace,
                gaps: gap
            )
        case let .fixed(value):
            return value
        }
    }

    private func hiddenRowRect(
        edge: AxisHideEdge,
        width: CGFloat,
        height: CGFloat,
        screenX: CGFloat,
        edgeFrame: CGRect,
        scale: CGFloat
    ) -> CGRect {
        let edgeReveal = 1.0 / max(1.0, scale)
        let y: CGFloat
        switch edge {
        case .minimum:
            y = edgeFrame.minY - height + edgeReveal
        case .maximum:
            y = edgeFrame.maxY - edgeReveal
        }
        let origin = CGPoint(x: screenX, y: y)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func hiddenColumnRect(
        edge: AxisHideEdge,
        width: CGFloat,
        height: CGFloat,
        screenY: CGFloat,
        edgeFrame: CGRect,
        scale: CGFloat
    ) -> CGRect {
        let edgeReveal = 1.0 / max(1.0, scale)
        let x: CGFloat
        switch edge {
        case .minimum:
            x = edgeFrame.minX - width + edgeReveal
        case .maximum:
            x = edgeFrame.maxX - edgeReveal
        }
        let origin = CGPoint(x: x, y: screenY)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
