// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import ApplicationServices
import CoreGraphics
import Foundation
@testable import Nehir
import Testing

/// Regression coverage for preserving a deliberately parked / edge-snapped
/// multi-column viewport across a config/settings relayout. A pure relayout
/// (app rules, workspace/layout config, monitor settings, gaps) must not spring
/// the viewport back to centered when nothing about the selection or column set
/// changed — even when the parked column is deliberately clipped at an edge.
@MainActor
struct ParkedViewportRelayoutTests {
    private struct ParkedColumnsFixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let engine: NiriLayoutEngine
        let nodes: [NiriWindow]
        let gap: CGFloat
        let workingFrame: CGRect
    }

    /// Builds a workspace with one window per column, each column pinned to a
    /// fixed width so the geometry is stable across relayouts (which re-resolve
    /// constraints). `widthFactors` are multiples of the working-frame width.
    private func makeParkedColumnsFixture(widthFactors: [CGFloat]) async -> ParkedColumnsFixture? {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for parked-columns fixture")
            return nil
        }

        controller.enableNiriLayout()
        controller.updateNiriConfig(balancedColumnCount: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine for parked-columns fixture")
            return nil
        }

        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gap = controller.gapSize(for: monitor)

        let pid: pid_t = 7_700
        var nodes: [NiriWindow] = []
        var previousNodeId: NodeId?
        for index in widthFactors.indices {
            let windowId = 7_701 + index
            let token = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            let node = engine.addWindow(
                token: token,
                to: workspaceId,
                afterSelection: previousNodeId,
                focusedToken: token
            )
            nodes.append(node)
            previousNodeId = node.id
        }

        let columns = engine.columns(in: workspaceId)
        guard columns.count == widthFactors.count else {
            Issue.record("Expected \(widthFactors.count) columns, got \(columns.count)")
            return nil
        }
        for (column, factor) in zip(columns, widthFactors) {
            let width = (workingFrame.width * factor).rounded()
            column.width = .fixed(width)
            column.cachedWidth = width
            column.cachedHeight = workingFrame.height
        }

        _ = controller.workspaceManager.setManagedFocus(nodes[0].token, in: workspaceId, onMonitor: monitor.id)

        return ParkedColumnsFixture(
            controller: controller,
            workspaceId: workspaceId,
            monitor: monitor,
            engine: engine,
            nodes: nodes,
            gap: gap,
            workingFrame: workingFrame
        )
    }

    private func snapContext(_ fx: ParkedColumnsFixture) -> ViewportSnapContext {
        let state = fx.controller.workspaceManager.niriViewportState(for: fx.workspaceId)
        return fx.engine.makeViewportSnapContext(
            columns: fx.engine.columns(in: fx.workspaceId),
            state: state,
            workingFrame: fx.workingFrame,
            gaps: fx.gap
        )
    }

    /// Parks the viewport so `activeColumn` sits at `viewStart`, then returns the
    /// resolved current view start for precondition checks.
    private func park(_ fx: ParkedColumnsFixture, activeColumn: Int, viewStart: CGFloat) -> CGFloat {
        fx.controller.workspaceManager.withNiriViewportState(for: fx.workspaceId) { state in
            let columns = fx.engine.columns(in: fx.workspaceId)
            state.selectedNodeId = fx.nodes[activeColumn].id
            state.activeColumnIndex = activeColumn
            let activeX = state.columnX(at: activeColumn, columns: columns, gap: fx.gap)
            state.viewOffsetPixels = .static(viewStart - activeX)
        }
        let state = fx.controller.workspaceManager.niriViewportState(for: fx.workspaceId)
        return snapContext(fx).currentViewStart(in: state)
    }

    private func relayoutViewportState(_ fx: ParkedColumnsFixture) async throws -> ViewportState? {
        let plans = try await fx.controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [fx.workspaceId]
        )
        return plans.first?.sessionPatch.viewportState
    }

    // MARK: - Core regression: a clipped edge-park survives a no-op relayout (Block 1)

    @Test func parkedClippedEdgeSnapSurvivesConfigRelayout() async throws {
        guard let fx = await makeParkedColumnsFixture(widthFactors: [0.9, 0.9, 0.9]) else { return }

        // Deliberately scroll column 0 far to the right so it is clipped (only a
        // sliver visible) — exactly the shape a naive "is it fully visible?"
        // reveal used to spring back to centered.
        let vw = fx.workingFrame.width
        let parkStart = -(fx.engine.columns(in: fx.workspaceId)[0].cachedWidth - vw * 0.1)
        let resolvedStart = park(fx, activeColumn: 0, viewStart: parkStart)
        #expect(abs(resolvedStart - parkStart) < 0.5)

        // Preconditions: the selected column is clipped (not fully visible), so
        // the pre-fix code would reveal/recenter it.
        let preCtx = snapContext(fx)
        let preState = fx.controller.workspaceManager.niriViewportState(for: fx.workspaceId)
        guard case .clipped = preCtx.visibility(of: 0, viewportOffset: resolvedStart, in: preState) else {
            Issue.record("Expected the parked selected column to be clipped")
            return
        }

        guard let result = try await relayoutViewportState(fx) else {
            Issue.record("Missing relayout viewport state")
            return
        }

        // The deliberate park must survive untouched.
        #expect(result.activeColumnIndex == 0)
        #expect(result.selectedNodeId == fx.nodes[0].id)
        #expect(abs(result.viewOffsetPixels.target() - parkStart) < 0.5)
    }

    // MARK: - A filling edge-park survives a no-op relayout (Block 2)

    /// Two columns sized so together they fill the viewport with a small slack
    /// (`2·width + gap ≈ viewportWidth - 2·gap`), the regime where the
    /// centered-viewport correction runs.
    private func filledColumnWidth(_ fx: ParkedColumnsFixture) -> CGFloat {
        ((fx.workingFrame.width - 2 * fx.gap) / 2).rounded()
    }

    private func setColumnWidths(_ fx: ParkedColumnsFixture, _ width: CGFloat) {
        for column in fx.engine.columns(in: fx.workspaceId) {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
    }

    /// Finds a snap where the columns fill the viewport but the start is not
    /// already centered, so the centered-viewport correction *would* move it —
    /// i.e. a genuine off-center edge-park, not a vacuous one. When `columnIndex`
    /// is given, only that column's snaps are considered (useful to pick a snap
    /// anchored to a column whose position a width change will move).
    private func fillingOffCenterSnap(
        _ fx: ParkedColumnsFixture,
        pixel: CGFloat,
        columnIndex: Int? = nil
    ) -> (start: CGFloat, centered: CGFloat)? {
        let state = fx.controller.workspaceManager.niriViewportState(for: fx.workspaceId)
        let ctx = snapContext(fx)
        var best: (start: CGFloat, centered: CGFloat)?
        for snap in ctx.snapPoints {
            if let columnIndex, snap.columnIndex != columnIndex { continue }
            guard let centered = ctx.centeredFillingViewportStart(at: snap.offset, in: state, pixelTolerance: pixel),
                  abs(centered - snap.offset) > pixel
            else { continue }
            if best == nil || abs(snap.offset - centered) > abs(best!.start - best!.centered) {
                best = (snap.offset, centered)
            }
        }
        return best
    }

    @Test func filledEdgeParkedViewportSurvivesConfigRelayout() async throws {
        guard let fx = await makeParkedColumnsFixture(widthFactors: [0.5, 0.5]) else { return }
        setColumnWidths(fx, filledColumnWidth(fx))
        let pixel = 1.0 / max(fx.engine.displayScale(in: fx.workspaceId), 1.0)

        // Precondition: a filling, off-center edge-park exists (the centered
        // correction would otherwise nudge it).
        guard let candidate = fillingOffCenterSnap(fx, pixel: pixel) else {
            Issue.record("Expected a filling, off-center snap to park on")
            return
        }
        let parkStart = park(fx, activeColumn: 0, viewStart: candidate.start)
        #expect(abs(parkStart - candidate.start) < 0.5)

        guard let result = try await relayoutViewportState(fx) else {
            Issue.record("Missing relayout viewport state")
            return
        }

        #expect(result.activeColumnIndex == 0)
        #expect(abs(result.viewOffsetPixels.target() - parkStart) < 0.5)
    }

    // MARK: - Control: a real width change that invalidates the park still recenters

    @Test func widthChangeInvalidatingParkStillRecenters() async throws {
        guard let fx = await makeParkedColumnsFixture(widthFactors: [0.5, 0.5]) else { return }
        let width = filledColumnWidth(fx)
        setColumnWidths(fx, width)
        let pixel = 1.0 / max(fx.engine.displayScale(in: fx.workspaceId), 1.0)
        let columns = fx.engine.columns(in: fx.workspaceId)

        // Park on a filling snap anchored to the trailing column, whose position
        // (and therefore this snap) will move when the leading column's width
        // changes.
        guard let candidate = fillingOffCenterSnap(fx, pixel: pixel, columnIndex: columns.count - 1) else {
            Issue.record("Expected a filling, off-center snap on the trailing column")
            return
        }
        let parkStart = park(fx, activeColumn: 0, viewStart: candidate.start)

        // A real width change: narrow the leading column a little. The trailing
        // column shifts left, so the parked snap is no longer reachable, while the
        // layout still fills — exactly the case the centered correction fixes.
        columns[0].width = .fixed(width - fx.gap / 2)
        columns[0].cachedWidth = width - fx.gap / 2

        let postState = fx.controller.workspaceManager.niriViewportState(for: fx.workspaceId)
        let newCtx = snapContext(fx)
        let stillReachable = newCtx.snapPoints.contains { abs($0.offset - parkStart) <= pixel }
        #expect(!stillReachable)
        // The narrowed layout must still fill at the parked start, so the centered
        // correction is the mechanism under test (not a bounds clamp).
        guard newCtx.centeredFillingViewportStart(at: parkStart, in: postState, pixelTolerance: pixel) != nil else {
            Issue.record("Expected the narrowed layout to still fill at the parked start")
            return
        }

        guard let result = try await relayoutViewportState(fx) else {
            Issue.record("Missing relayout viewport state")
            return
        }

        // The now-invalid parked offset should be corrected.
        #expect(abs(result.viewOffsetPixels.target() - parkStart) > pixel)
    }
}
