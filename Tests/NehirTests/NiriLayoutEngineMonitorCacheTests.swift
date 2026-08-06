// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir
import Testing

/// Cached column spans must not survive a change to the monitor configuration:
/// `NiriLayout` only re-resolves a column's stored proportion when `cachedWidth <= 0`,
/// so a span left over from another display silently becomes the laid-out width.
@Suite struct NiriLayoutEngineMonitorCacheTests {
    private func makeEngineWithProportionalColumn() -> (engine: NiriLayoutEngine, column: NiriContainer) {
        let engine = NiriLayoutEngine()
        let workspaceId = UUID()
        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root

        let column = NiriContainer()
        column.width = .proportion(0.5)
        root.appendChild(column)

        return (engine, column)
    }

    /// Swapping the connected display (dock/undock) must drop cached column spans.
    /// `Monitor.ID` is the CGDirectDisplayID, so an external monitor and the built-in
    /// panel are never the same key: the per-monitor size-change check in
    /// `updateMonitors` sees no surviving monitor resize and would otherwise leave every
    /// column holding pixel widths resolved against the display that went away.
    @Test func swappingMonitorsInvalidatesCachedColumnSpans() {
        let (engine, column) = makeEngineWithProportionalColumn()

        let external = makeLayoutPlanTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(1),
            name: "External",
            width: 2_360,
            height: 1_440
        )
        let builtIn = makeLayoutPlanTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(2),
            name: "Built-in",
            width: 1_512,
            height: 982
        )

        _ = engine.ensureMonitor(for: external.id, monitor: external)
        column.resolveAndCacheWidth(workingAreaWidth: external.visibleFrame.width, gaps: 0)
        #expect(column.cachedWidth > 0)

        // Undock: the external display is replaced by the built-in panel.
        engine.updateMonitors([builtIn])

        #expect(column.cachedWidth == 0)
    }

    /// The pre-existing behaviour this must not regress: a monitor that stays connected
    /// but changes working area (e.g. the Dock reservation appearing) still invalidates
    /// cached spans.
    @Test func resizingWorkingAreaOfSameMonitorInvalidatesCachedColumnSpans() {
        let (engine, column) = makeEngineWithProportionalColumn()

        let full = makeLayoutPlanTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(3),
            name: "Display",
            width: 2_360,
            height: 1_440
        )
        _ = engine.ensureMonitor(for: full.id, monitor: full)
        column.resolveAndCacheWidth(workingAreaWidth: full.visibleFrame.width, gaps: 0)
        #expect(column.cachedWidth > 0)

        let reserved = Monitor(
            id: full.id,
            displayId: full.displayId,
            frame: full.frame,
            visibleFrame: full.frame.insetBy(dx: 0, dy: 40),
            hasNotch: false,
            name: full.name
        )
        engine.updateMonitors([reserved])

        #expect(column.cachedWidth == 0)
    }

    /// A no-op reconfiguration must not thrash the cache: display notifications arrive in
    /// bursts, and an unchanged monitor set has to leave resolved spans alone.
    @Test func unchangedMonitorSetKeepsCachedColumnSpans() {
        let (engine, column) = makeEngineWithProportionalColumn()

        let monitor = makeLayoutPlanTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(4),
            name: "Display",
            width: 2_360,
            height: 1_440
        )
        _ = engine.ensureMonitor(for: monitor.id, monitor: monitor)
        column.resolveAndCacheWidth(workingAreaWidth: monitor.visibleFrame.width, gaps: 0)
        let resolved = column.cachedWidth
        #expect(resolved > 0)

        engine.updateMonitors([monitor])

        #expect(column.cachedWidth == resolved)
    }
}
