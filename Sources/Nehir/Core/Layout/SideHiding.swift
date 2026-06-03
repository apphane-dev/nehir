import CoreGraphics
import Foundation

enum HideSide {
    case left
    case right
}

enum AxisHideEdge {
    case minimum
    case maximum

    init(encodedHideSide: HideSide) {
        switch encodedHideSide {
        case .left:
            self = .minimum
        case .right:
            self = .maximum
        }
    }

    var encodedHideSide: HideSide {
        switch self {
        case .minimum:
            .left
        case .maximum:
            .right
        }
    }

    var opposite: AxisHideEdge {
        switch self {
        case .minimum:
            .maximum
        case .maximum:
            .minimum
        }
    }
}

struct HiddenPlacementMonitorContext {
    let id: Monitor.ID
    let frame: CGRect
    let visibleFrame: CGRect

    init(id: Monitor.ID, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    init(_ monitor: Monitor) {
        self.init(id: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame)
    }

    init(_ monitor: NiriMonitor) {
        self.init(id: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame)
    }
}

struct HiddenWindowPlacement {
    let requestedEdge: AxisHideEdge
    let resolvedEdge: AxisHideEdge
    let origin: CGPoint

    func frame(for size: CGSize) -> CGRect {
        CGRect(origin: origin, size: size)
    }
}

enum HiddenWindowPlacementResolver {
    static func physicalScreenEdgeOrigin(
        for size: CGSize,
        requestedSide: HideSide,
        targetY: CGFloat,
        baseReveal: CGFloat,
        scale: CGFloat,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> CGPoint {
        let reveal = baseReveal / max(1.0, scale)

        func origin(for side: HideSide, y: CGFloat) -> CGPoint {
            switch side {
            case .left:
                CGPoint(
                    x: monitor.frame.minX - size.width + reveal,
                    y: y
                )
            case .right:
                CGPoint(
                    x: monitor.frame.maxX - reveal,
                    y: y
                )
            }
        }

        let alternateSide: HideSide = requestedSide == .left ? .right : .left
        let sides = [requestedSide, alternateSide]
        // The live frame can still be on the source display when a window is assigned
        // directly to an inactive workspace on another display. Try nearby vertical
        // parking lanes too, otherwise preserving that source-display Y can leave a
        // large strip visible on an adjacent monitor.
        let yCandidates = verticalParkingCandidates(
            for: size,
            targetY: targetY,
            monitor: monitor,
            monitors: monitors
        )

        var bestOrigin = origin(for: requestedSide, y: targetY)
        var bestOverlap = CGFloat.greatestFiniteMagnitude
        var bestLanePenalty = Int.max
        var bestSidePenalty = Int.max
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for (sideIndex, side) in sides.enumerated() {
            for y in yCandidates {
                let candidateOrigin = origin(for: side, y: y)
                let candidateFrame = CGRect(origin: candidateOrigin, size: size)
                let overlap = overlapArea(
                    for: candidateFrame,
                    monitor: monitor,
                    monitors: monitors
                )
                let lanePenalty = verticalOverlap(candidateFrame, monitor.frame) > 0 ? 0 : 1
                let distance = abs(y - targetY)
                if lanePenalty < bestLanePenalty
                    || (lanePenalty == bestLanePenalty && overlap < bestOverlap)
                    || (lanePenalty == bestLanePenalty
                        && overlap == bestOverlap
                        && distance < bestDistance)
                    || (lanePenalty == bestLanePenalty
                        && overlap == bestOverlap
                        && distance == bestDistance
                        && sideIndex < bestSidePenalty)
                {
                    bestOrigin = candidateOrigin
                    bestOverlap = overlap
                    bestLanePenalty = lanePenalty
                    bestSidePenalty = sideIndex
                    bestDistance = distance
                }
            }
        }

        return bestOrigin
    }

    static func placement(
        for size: CGSize,
        requestedEdge: AxisHideEdge,
        orthogonalOrigin: CGFloat,
        baseReveal: CGFloat,
        scale: CGFloat,
        orientation: Monitor.Orientation,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> HiddenWindowPlacement {
        let reveal = baseReveal / max(1.0, scale)

        func origin(for edge: AxisHideEdge) -> CGPoint {
            switch orientation {
            case .horizontal:
                switch edge {
                case .minimum:
                    return CGPoint(
                        x: monitor.visibleFrame.minX - size.width + reveal,
                        y: orthogonalOrigin
                    )
                case .maximum:
                    return CGPoint(
                        x: monitor.visibleFrame.maxX - reveal,
                        y: orthogonalOrigin
                    )
                }
            case .vertical:
                switch edge {
                case .minimum:
                    return CGPoint(
                        x: orthogonalOrigin,
                        y: monitor.visibleFrame.minY - size.height + reveal
                    )
                case .maximum:
                    return CGPoint(
                        x: orthogonalOrigin,
                        y: monitor.visibleFrame.maxY - reveal
                    )
                }
            }
        }

        let primaryOrigin = origin(for: requestedEdge)
        let primaryOverlap = overlapArea(
            for: CGRect(origin: primaryOrigin, size: size),
            monitor: monitor,
            monitors: monitors
        )
        if primaryOverlap == 0 {
            return HiddenWindowPlacement(
                requestedEdge: requestedEdge,
                resolvedEdge: requestedEdge,
                origin: primaryOrigin
            )
        }

        let alternateEdge = requestedEdge.opposite
        let alternateOrigin = origin(for: alternateEdge)
        let alternateOverlap = overlapArea(
            for: CGRect(origin: alternateOrigin, size: size),
            monitor: monitor,
            monitors: monitors
        )
        if alternateOverlap < primaryOverlap {
            return HiddenWindowPlacement(
                requestedEdge: requestedEdge,
                resolvedEdge: alternateEdge,
                origin: alternateOrigin
            )
        }

        return HiddenWindowPlacement(
            requestedEdge: requestedEdge,
            resolvedEdge: requestedEdge,
            origin: primaryOrigin
        )
    }

    private static func verticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }

    private static func verticalParkingCandidates(
        for size: CGSize,
        targetY: CGFloat,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> [CGFloat] {
        var candidates: [CGFloat] = []

        func append(_ y: CGFloat) {
            guard y.isFinite else { return }
            if !candidates.contains(where: { abs($0 - y) < 0.5 }) {
                candidates.append(y)
            }
        }

        append(targetY)
        append(monitor.frame.minY)
        append(monitor.frame.maxY - size.height)

        for other in monitors where other.id != monitor.id {
            append(other.frame.minY - size.height)
            append(other.frame.maxY)
        }

        return candidates
    }

    private static func overlapArea(
        for rect: CGRect,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> CGFloat {
        var area: CGFloat = 0
        for other in monitors where other.id != monitor.id {
            let intersection = rect.intersection(other.frame)
            if intersection.isNull { continue }
            area += intersection.width * intersection.height
        }
        return area
    }
}
