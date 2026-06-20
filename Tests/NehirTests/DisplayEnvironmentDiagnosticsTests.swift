// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir
import Testing

@Suite struct DisplayEnvironmentDiagnosticsTests {
    @Test func detectsFixedDockInsetsExceptMenuBarTopInset() {
        let monitor = makeMonitor(
            name: "Built-in Display",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1640, height: 1080)
        )

        let diagnostics = DisplayEnvironmentDiagnostics.evaluate(monitors: [monitor])

        #expect(diagnostics.issues.contains { issue in
            if case let .fixedDock(_, monitorName, edge, inset) = issue.kind {
                return monitorName == "Built-in Display" && edge == .right && abs(inset - 88) < 0.001
            }
            return false
        })
        #expect(diagnostics.issues.count == 1)
    }

    @Test func detectsSideBySideDisplayArrangement() {
        let primary = makeMonitor(
            name: "Primary",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let secondary = makeMonitor(
            name: "Secondary",
            frame: CGRect(x: 1440, y: 100, width: 1440, height: 900)
        )

        let diagnostics = DisplayEnvironmentDiagnostics.evaluate(monitors: [primary, secondary])

        #expect(diagnostics.issues.contains { issue in
            if case let .horizontalDisplayArrangement(_, firstMonitorName, _, secondMonitorName) = issue.kind {
                return firstMonitorName == "Primary" && secondMonitorName == "Secondary"
            }
            return false
        })
    }

    @Test func acceptsVerticalDisplayArrangementWithoutDockInsets() {
        let primary = makeMonitor(
            name: "Primary",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860)
        )
        let secondary = makeMonitor(
            name: "Secondary",
            frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 900)
        )

        let diagnostics = DisplayEnvironmentDiagnostics.evaluate(monitors: [primary, secondary])

        #expect(!diagnostics.hasWarnings)
    }

    @Test func mirroredDisplaysAreNotReportedAsSideBySide() {
        let primary = makeMonitor(
            name: "Primary",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let mirror = makeMonitor(
            name: "Mirror",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        let diagnostics = DisplayEnvironmentDiagnostics.evaluate(monitors: [primary, mirror])

        #expect(!diagnostics.hasWarnings)
    }

    @Test func issueIdsUseDisplayIdsWhenMonitorNamesCollide() {
        let first = makeMonitor(
            name: "Display",
            displayId: 101,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 940, height: 800)
        )
        let second = makeMonitor(
            name: "Display",
            displayId: 202,
            frame: CGRect(x: 0, y: 1000, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 1000, width: 940, height: 800)
        )

        let diagnostics = DisplayEnvironmentDiagnostics.evaluate(monitors: [first, second])
        let ids = diagnostics.issues.map(\.id)

        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    private func makeMonitor(
        name: String,
        displayId: CGDirectDisplayID? = nil,
        frame: CGRect,
        visibleFrame: CGRect? = nil
    ) -> Monitor {
        let resolvedDisplayId = displayId ?? CGDirectDisplayID(abs(name.hashValue % 10_000) + 1)
        return Monitor(
            id: Monitor.ID(displayId: resolvedDisplayId),
            displayId: resolvedDisplayId,
            frame: frame,
            visibleFrame: visibleFrame ?? frame,
            hasNotch: false,
            name: name
        )
    }
}
