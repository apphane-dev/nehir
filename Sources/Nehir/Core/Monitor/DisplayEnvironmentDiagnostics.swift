import CoreGraphics
import Foundation

struct DisplayEnvironmentDiagnostics: Equatable {
    struct Issue: Identifiable, Equatable {
        enum Kind: Equatable {
            case fixedDock(
                monitorId: Monitor.ID,
                monitorName: String,
                edge: DockEdge,
                inset: CGFloat
            )
            case horizontalDisplayArrangement(
                firstMonitorId: Monitor.ID,
                firstMonitorName: String,
                secondMonitorId: Monitor.ID,
                secondMonitorName: String
            )
        }

        let kind: Kind

        var id: String {
            switch kind {
            case let .fixedDock(monitorId, _, edge, _):
                "fixedDock:\(monitorId.displayId):\(edge.rawValue)"
            case let .horizontalDisplayArrangement(firstMonitorId, _, secondMonitorId, _):
                "horizontalDisplayArrangement:\(firstMonitorId.displayId):\(secondMonitorId.displayId)"
            }
        }

        var title: String {
            switch kind {
            case let .fixedDock(_, monitorName, _, _):
                "Fixed Dock detected on \(monitorName)"
            case .horizontalDisplayArrangement:
                "Unsupported vertical display overlap detected"
            }
        }

        var message: String {
            switch kind {
            case let .fixedDock(_, _, edge, inset):
                "The Dock appears to reserve \(Int(inset.rounded())) px on the \(edge.displayName.lowercased()) edge. Parked transient windows can be clamped to the Dock boundary and leave a visible strip."
            case let .horizontalDisplayArrangement(_, firstMonitorName, _, secondMonitorName):
                "\(firstMonitorName) and \(secondMonitorName) overlap vertically in macOS display arrangement. Horizontally parked windows can bleed onto the neighboring display."
            }
        }

        var recommendation: String {
            switch kind {
            case .fixedDock:
                "Enable Dock auto-hide in System Settings > Desktop & Dock, or move the fixed Dock away from the edge used for hidden-window parking."
            case .horizontalDisplayArrangement:
                "Arrange displays vertically or diagonally in System Settings > Displays > Arrange so display frames do not overlap vertically."
            }
        }
    }

    enum DockEdge: String, Equatable {
        case left
        case right
        case bottom

        var displayName: String {
            switch self {
            case .left: "Left"
            case .right: "Right"
            case .bottom: "Bottom"
            }
        }
    }

    let issues: [Issue]

    var hasWarnings: Bool {
        !issues.isEmpty
    }

    static func current() -> DisplayEnvironmentDiagnostics {
        evaluate(monitors: Monitor.current())
    }

    /// Evaluates the currently supported display environment. As of now Nehir supports
    /// fixed-Dock-free setups and display arrangements with no vertical overlap
    /// (vertical/diagonal layouts). Separate Spaces detection is shown as state in the
    /// UI, but it does not change or suppress the support recommendation.
    static func evaluate(monitors: [Monitor], spacesMode _: DisplaySpacesMode = .unavailable) -> DisplayEnvironmentDiagnostics {
        var issues: [Issue] = []
        issues.append(contentsOf: fixedDockIssues(monitors: monitors))
        issues.append(contentsOf: horizontalArrangementIssues(monitors: monitors))
        return DisplayEnvironmentDiagnostics(issues: issues)
    }

    private static func fixedDockIssues(monitors: [Monitor]) -> [Issue] {
        monitors.flatMap { monitor -> [Issue] in
            let frame = monitor.frame
            let visibleFrame = monitor.visibleFrame
            let threshold: CGFloat = 24
            let insets: [(DockEdge, CGFloat)] = [
                (.left, visibleFrame.minX - frame.minX),
                (.right, frame.maxX - visibleFrame.maxX),
                (.bottom, visibleFrame.minY - frame.minY),
            ]

            return insets.compactMap { edge, inset in
                guard inset >= threshold else { return nil }
                return Issue(kind: .fixedDock(monitorId: monitor.id, monitorName: monitor.name, edge: edge, inset: inset))
            }
        }
    }

    private static func horizontalArrangementIssues(monitors: [Monitor]) -> [Issue] {
        guard monitors.count > 1 else { return [] }

        var issues: [Issue] = []
        for firstIndex in monitors.indices {
            for secondIndex in monitors.indices where secondIndex > firstIndex {
                let first = monitors[firstIndex]
                let second = monitors[secondIndex]
                let verticalOverlap = overlap(
                    first.frame.minY ... first.frame.maxY,
                    second.frame.minY ... second.frame.maxY
                )
                guard verticalOverlap > 1 else { continue }
                let horizontalOverlap = overlap(
                    first.frame.minX ... first.frame.maxX,
                    second.frame.minX ... second.frame.maxX
                )
                guard horizontalOverlap < 1 else { continue }
                issues.append(
                    Issue(
                        kind: .horizontalDisplayArrangement(
                            firstMonitorId: first.id,
                            firstMonitorName: first.name,
                            secondMonitorId: second.id,
                            secondMonitorName: second.name
                        )
                    )
                )
            }
        }
        return issues
    }

    private static func overlap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }
}
