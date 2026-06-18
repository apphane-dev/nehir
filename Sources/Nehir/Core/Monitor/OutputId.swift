import CoreGraphics
import Foundation

struct OutputId: Codable {
    let displayId: CGDirectDisplayID

    let name: String

    /// Top-left anchor point of the monitor at the time the assignment was saved. Used as a
    /// position fallback when matching ignores monitor identity. Optional for backward
    /// compatibility with configs written before this field existed.
    let anchorPoint: CGPoint?

    init(displayId: CGDirectDisplayID, name: String, anchorPoint: CGPoint? = nil) {
        self.displayId = displayId
        self.name = name
        self.anchorPoint = anchorPoint
    }

    init(from monitor: Monitor) {
        displayId = monitor.displayId
        name = monitor.name
        anchorPoint = monitor.workspaceAnchorPoint
    }

    func resolveMonitor(in monitors: [Monitor], ignoreIdentity: Bool = false) -> Monitor? {
        if let exact = monitors.first(where: { $0.displayId == displayId }) {
            return exact
        }

        // When ignoring monitor identity, resolve by layout position so a workspace pinned to a
        // specific display reattaches to whatever monitor now occupies that position.
        if ignoreIdentity, let anchorPoint {
            return monitors.min {
                $0.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
                    < $1.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            }
        }

        let nameMatches = monitors.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard nameMatches.count == 1 else { return nil }
        return nameMatches[0]
    }
}

extension OutputId: Hashable {
    // Identity is the (displayId, name) pair; the anchor point is incidental restore metadata
    // and must not affect equality so picker selections and stored assignments keep matching.
    static func == (lhs: OutputId, rhs: OutputId) -> Bool {
        lhs.displayId == rhs.displayId && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(displayId)
        hasher.combine(name)
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
