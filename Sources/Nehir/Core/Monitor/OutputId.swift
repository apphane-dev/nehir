import CoreGraphics
import Foundation

struct OutputId: Hashable, Codable {
    let displayId: CGDirectDisplayID

    let name: String

    init(displayId: CGDirectDisplayID, name: String) {
        self.displayId = displayId
        self.name = name
    }

    init(from monitor: Monitor) {
        displayId = monitor.displayId
        name = monitor.name
    }

    func resolveMonitor(in monitors: [Monitor]) -> Monitor? {
        if let exact = monitors.first(where: { $0.displayId == displayId }) {
            return exact
        }

        let nameMatches = monitors.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard nameMatches.count == 1 else { return nil }
        return nameMatches[0]
    }
}
