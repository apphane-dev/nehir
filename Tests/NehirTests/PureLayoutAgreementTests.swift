// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import Nehir
import Testing

@Suite struct PureLayoutAgreementTests {
    private struct AgreementSnapshot: Equatable {
        var columns: [[WindowToken]]
        var activeColumnIndex: Int?
        var focusedWindowID: WindowToken?
    }

    private struct Fixture {
        var pure: CoreWorld<UUID, WindowToken>
        var engine: NiriLayoutEngine
        var workspaceId: WorkspaceDescriptor.ID
        var state: ViewportState
        var selectedToken: WindowToken
    }

    @Test func focusLeftRightAgreesInThreeColumnWorld() {
        var fixture = makeFixture(columns: [[1], [2], [3]], activeColumnIndex: 1, activeWindowIndex: 0)
        assertAgreement(afterFocus: .right, fixture: &fixture)

        fixture = makeFixture(columns: [[1], [2], [3]], activeColumnIndex: 1, activeWindowIndex: 0)
        assertAgreement(afterFocus: .left, fixture: &fixture)
    }

    @Test func focusUpDownAgreesInStackedColumn() {
        var fixture = makeFixture(columns: [[1, 2, 3]], activeColumnIndex: 0, activeWindowIndex: 1)
        assertAgreement(afterFocus: .up, fixture: &fixture)

        fixture = makeFixture(columns: [[1, 2, 3]], activeColumnIndex: 0, activeWindowIndex: 1)
        assertAgreement(afterFocus: .down, fixture: &fixture)
    }

    @Test func moveUpDownAgreesInStackedColumn() {
        var fixture = makeFixture(columns: [[1, 2, 3]], activeColumnIndex: 0, activeWindowIndex: 1)
        assertAgreement(afterMove: .up, fixture: &fixture)

        fixture = makeFixture(columns: [[1, 2, 3]], activeColumnIndex: 0, activeWindowIndex: 1)
        assertAgreement(afterMove: .down, fixture: &fixture)
    }

    @Test func expelLeftRightFromStackedColumnAgrees() {
        var fixture = makeFixture(columns: [[1, 2], [3]], activeColumnIndex: 0, activeWindowIndex: 1)
        assertAgreement(afterMove: .right, fixture: &fixture)

        fixture = makeFixture(columns: [[1], [2, 3]], activeColumnIndex: 1, activeWindowIndex: 0)
        assertAgreement(afterMove: .left, fixture: &fixture)
    }

    @Test func consumeLeftRightFromSoloColumnAgrees() {
        var fixture = makeFixture(columns: [[1], [2, 3]], activeColumnIndex: 0, activeWindowIndex: 0)
        assertAgreement(afterMove: .right, fixture: &fixture)

        fixture = makeFixture(columns: [[1, 2], [3]], activeColumnIndex: 1, activeWindowIndex: 0)
        assertAgreement(afterMove: .left, fixture: &fixture)
    }

    @Test func noWrapEdgeConsumeAndFocusAgreeWhenInfiniteLoopDisabled() {
        var fixture = makeFixture(columns: [[1], [2]], activeColumnIndex: 0, activeWindowIndex: 0, infiniteLoop: false)
        assertAgreement(afterFocus: .left, fixture: &fixture)

        fixture = makeFixture(columns: [[1], [2]], activeColumnIndex: 0, activeWindowIndex: 0, infiniteLoop: false)
        assertAgreement(afterMove: .left, fixture: &fixture)
    }

    @Test func wrapEdgeConsumeAndFocusAgreeWhenInfiniteLoopEnabled() {
        var fixture = makeFixture(columns: [[1], [2]], activeColumnIndex: 0, activeWindowIndex: 0, infiniteLoop: true)
        assertAgreement(afterFocus: .left, fixture: &fixture)

        fixture = makeFixture(columns: [[1], [2]], activeColumnIndex: 0, activeWindowIndex: 0, infiniteLoop: true)
        assertAgreement(afterMove: .left, fixture: &fixture)
    }

    private func assertAgreement(afterFocus direction: PureDirection, fixture: inout Fixture) {
        fixture.pure = PureLayoutReducer.focus(direction, in: fixture.pure)

        let selected = fixture.engine.findNode(for: fixture.selectedToken)
        if let selected,
           let target = fixture.engine.focusTarget(
               direction: niriDirection(for: direction),
               currentSelection: selected,
               in: fixture.workspaceId,
               motion: .disabled,
               state: &fixture.state,
               workingFrame: workingFrame,
               gaps: gap
           ) as? NiriWindow
        {
            fixture.selectedToken = target.token
            fixture.state.selectedNodeId = target.id
        }

        #expect(pureSnapshot(fixture.pure) == realSnapshot(fixture))
    }

    private func assertAgreement(afterMove direction: PureDirection, fixture: inout Fixture) {
        fixture.pure = PureLayoutReducer.moveFocusedWindow(direction, in: fixture.pure)

        if let selected = fixture.engine.findNode(for: fixture.selectedToken) {
            let moved = fixture.engine.moveWindow(
                selected,
                direction: niriDirection(for: direction),
                in: fixture.workspaceId,
                motion: .disabled,
                state: &fixture.state,
                workingFrame: workingFrame,
                gaps: gap
            )
            if moved {
                fixture.selectedToken = selected.token
                fixture.state.selectedNodeId = selected.id
            }
        }

        #expect(pureSnapshot(fixture.pure) == realSnapshot(fixture))
    }

    private func makeFixture(
        columns: [[Int]],
        activeColumnIndex: Int,
        activeWindowIndex: Int,
        infiniteLoop: Bool = false
    ) -> Fixture {
        let workspaceId = UUID()
        let engine = NiriLayoutEngine(infiniteLoop: infiniteLoop)
        let root = engine.ensureRoot(for: workspaceId)
        var coreColumns: [CoreColumn<WindowToken>] = []
        var selectedToken: WindowToken?

        for (columnIndex, windowIDs) in columns.enumerated() {
            let realColumn = NiriContainer()
            realColumn.cachedWidth = 240
            root.appendChild(realColumn)

            let tokens = windowIDs.map { WindowToken(pid: 900, windowId: $0) }
            for token in tokens {
                let window = NiriWindow(token: token)
                realColumn.appendChild(window)
                engine.tokenToNode[token] = window
            }
            let columnActiveIndex = min(max(activeWindowIndex, 0), max(tokens.count - 1, 0))
            realColumn.setActiveTileIdx(columnActiveIndex)

            if columnIndex == activeColumnIndex, tokens.indices.contains(columnActiveIndex) {
                selectedToken = tokens[columnActiveIndex]
            }

            coreColumns.append(
                CoreColumn(
                    id: CoreColumnID(rawValue: columnIndex),
                    windows: tokens.map { CoreWindow(id: $0) },
                    activeWindowIndex: columnActiveIndex
                )
            )
        }

        let clampedActiveColumnIndex = min(max(activeColumnIndex, 0), max(coreColumns.count - 1, 0))
        let pure = CoreWorld(
            workspaces: [CoreWorkspace(
                id: workspaceId,
                columns: coreColumns,
                activeColumnIndex: clampedActiveColumnIndex
            )],
            activeWorkspaceIndex: 0,
            nextColumnID: 100,
            config: PureLayoutConfig(infiniteLoop: infiniteLoop)
        )
        var state = ViewportState()
        state.activeColumnIndex = clampedActiveColumnIndex
        let activeColumn = coreColumns[clampedActiveColumnIndex]
        let selected = selectedToken ?? activeColumn.windows[activeColumn.activeWindowIndex].id
        state.selectedNodeId = engine.findNode(for: selected)?.id

        return Fixture(
            pure: pure,
            engine: engine,
            workspaceId: workspaceId,
            state: state,
            selectedToken: selected
        )
    }

    private func pureSnapshot(_ world: CoreWorld<UUID, WindowToken>) -> AgreementSnapshot {
        guard let workspace = world.activeWorkspace else {
            return AgreementSnapshot(columns: [], activeColumnIndex: nil, focusedWindowID: nil)
        }
        return AgreementSnapshot(
            columns: workspace.columns.map { $0.windows.map(\.id) },
            activeColumnIndex: workspace.activeColumnIndex,
            focusedWindowID: workspace.focusedWindowID
        )
    }

    private func realSnapshot(_ fixture: Fixture) -> AgreementSnapshot {
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        return AgreementSnapshot(
            columns: columns.map { $0.windowNodes.map(\.token) },
            activeColumnIndex: columns.isEmpty ? nil : fixture.state.activeColumnIndex,
            focusedWindowID: fixture.selectedToken
        )
    }

    private func niriDirection(for direction: PureDirection) -> Direction {
        switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }

    private var workingFrame: CGRect {
        CGRect(x: 0, y: 0, width: 900, height: 600)
    }

    private var gap: CGFloat {
        10
    }
}
