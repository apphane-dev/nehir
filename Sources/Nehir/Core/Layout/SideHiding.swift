// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

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
        // Workspace-inactive / scratchpad hides park against the PHYSICAL screen edge.
        // Only the scroll-hide `placement` path parks 1px inside the visibleFrame/Dock
        // edge; this path stays physical so a hidden window rests at the true screen
        // edge regardless of Dock reservation.
        let parkingFrame = monitor.frame

        func origin(for side: HideSide, y: CGFloat) -> CGPoint {
            switch side {
            case .left:
                return CGPoint(
                    x: parkingFrame.minX - size.width + reveal,
                    y: y
                )
            case .right:
                return CGPoint(
                    x: parkingFrame.maxX - reveal,
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
        // Park 1pt inside the working (visibleFrame) edge — 1px from the Dock. The
        // window rests 1px inside the workspace with the rest under the Dock + shield;
        // this is the placement AX accepts and holds. Parking at the physical screen
        // edge (2055) is clamped to visibleFrame.maxX-40. Render and park targets both
        // come from here, so they stay in agreement.
        // Reveal is at least 1 POINT (not 1 physical pixel). A ½pt sliver on a 2× display
        // is below macOS' minimum-visible threshold, so the park gets clamped to ~40px
        // and a continuous scroll-hide reverify loop makes the parked window "dance" on a
        // non-Dock edge. Keeping ≥1pt visible holds. On a Dock edge the window still rests
        // 1pt inside the visibleFrame edge, behind the Dock + shield.
        let edgeReveal = max(1.0, baseReveal / max(1.0, scale))
        let parkingFrame = monitor.visibleFrame.isNull ? monitor.frame : monitor.visibleFrame

        func origin(for edge: AxisHideEdge, orthogonal: CGFloat) -> CGPoint {
            switch orientation {
            case .horizontal:
                switch edge {
                case .minimum:
                    return CGPoint(
                        x: parkingFrame.minX - size.width + edgeReveal,
                        y: orthogonal
                    )
                case .maximum:
                    return CGPoint(
                        x: parkingFrame.maxX - edgeReveal,
                        y: orthogonal
                    )
                }
            case .vertical:
                switch edge {
                case .minimum:
                    return CGPoint(
                        x: orthogonal,
                        y: parkingFrame.minY - size.height + edgeReveal
                    )
                case .maximum:
                    return CGPoint(
                        x: orthogonal,
                        y: parkingFrame.maxY - edgeReveal
                    )
                }
            }
        }

        let orthogonalCandidates = orthogonalParkingCandidates(
            for: size,
            target: orthogonalOrigin,
            orientation: orientation,
            monitor: monitor,
            monitors: monitors
        )
        let candidateEdges = [requestedEdge, requestedEdge.opposite]
        var bestPlacement = HiddenWindowPlacement(
            requestedEdge: requestedEdge,
            resolvedEdge: requestedEdge,
            origin: origin(for: requestedEdge, orthogonal: orthogonalOrigin)
        )
        var bestOverlap = CGFloat.greatestFiniteMagnitude
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var bestEdgePenalty = Int.max

        for (edgeIndex, edge) in candidateEdges.enumerated() {
            for orthogonal in orthogonalCandidates {
                let candidateOrigin = origin(for: edge, orthogonal: orthogonal)
                let candidateFrame = CGRect(origin: candidateOrigin, size: size)
                let overlap = overlapArea(
                    for: candidateFrame,
                    monitor: monitor,
                    monitors: monitors
                )
                let distance = abs(orthogonal - orthogonalOrigin)
                if overlap < bestOverlap
                    || (overlap == bestOverlap && distance < bestDistance)
                    || (overlap == bestOverlap && distance == bestDistance && edgeIndex < bestEdgePenalty)
                {
                    bestPlacement = HiddenWindowPlacement(
                        requestedEdge: requestedEdge,
                        resolvedEdge: edge,
                        origin: candidateOrigin
                    )
                    bestOverlap = overlap
                    bestDistance = distance
                    bestEdgePenalty = edgeIndex
                }
            }
        }

        return bestPlacement
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
        orthogonalParkingCandidates(
            for: size,
            target: targetY,
            orientation: .horizontal,
            monitor: monitor,
            monitors: monitors
        )
    }

    private static func orthogonalParkingCandidates(
        for size: CGSize,
        target: CGFloat,
        orientation: Monitor.Orientation,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> [CGFloat] {
        var candidates: [CGFloat] = []

        func append(_ value: CGFloat) {
            guard value.isFinite else { return }
            if !candidates.contains(where: { abs($0 - value) < 0.5 }) {
                candidates.append(value)
            }
        }

        append(target)
        switch orientation {
        case .horizontal:
            append(monitor.frame.minY)
            append(monitor.frame.maxY - size.height)
            for other in monitors where other.id != monitor.id {
                append(other.frame.minY - size.height)
                append(other.frame.maxY)
            }
        case .vertical:
            append(monitor.frame.minX)
            append(monitor.frame.maxX - size.width)
            for other in monitors where other.id != monitor.id {
                append(other.frame.minX - size.width)
                append(other.frame.maxX)
            }
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
