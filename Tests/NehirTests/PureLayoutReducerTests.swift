import Testing
@testable import Nehir

@Suite struct PureLayoutReducerTests {
    typealias World = CoreWorld<Int, String>

    @Test func focusHorizontalMovesBetweenColumnsWithoutChangingStructure() {
        let world = makeWorld(columns: [column(0, ["A"]), column(1, ["B1", "B2"], active: 1), column(2, ["C"])])
        let moved = assertValid(PureLayoutReducer.focus(.right, in: world))

        #expect(moved.workspaces[0].activeColumnIndex == 1)
        #expect(moved.workspaces[0].focusedWindowID == "B2")
        #expect(snapshot(moved) == [["A"], ["B1", "B2"], ["C"]])
    }

    @Test func focusHorizontalDoesNotWrapByDefaultAtEdges() {
        let world = makeWorld(columns: [column(0, ["A"]), column(1, ["B"])])
        let moved = assertValid(PureLayoutReducer.focus(.left, in: world))

        #expect(moved == world)
    }

    @Test func focusHorizontalWrapsWhenInfiniteLoopEnabled() {
        var world = makeWorld(columns: [column(0, ["A"]), column(1, ["B"])])
        world.config.infiniteLoop = true

        let moved = assertValid(PureLayoutReducer.focus(.left, in: world))

        #expect(moved.workspaces[0].activeColumnIndex == 1)
        #expect(moved.workspaces[0].focusedWindowID == "B")
    }

    @Test func focusVerticalUsesStorageBottomConvention() {
        let world = makeWorld(columns: [column(0, ["bottom", "middle", "top"], active: 0)])

        let up = assertValid(PureLayoutReducer.focus(.up, in: world))
        let downFromUp = assertValid(PureLayoutReducer.focus(.down, in: up))
        let downAtBottom = assertValid(PureLayoutReducer.focus(.down, in: world))

        #expect(up.workspaces[0].focusedWindowID == "middle")
        #expect(downFromUp.workspaces[0].focusedWindowID == "bottom")
        #expect(downAtBottom == world)
    }

    @Test func moveVerticalSwapsWithStorageUpAndDown() {
        let world = makeWorld(columns: [column(0, ["bottom", "middle", "top"], active: 1)])

        let movedUp = assertValid(PureLayoutReducer.moveFocusedWindow(.up, in: world))
        #expect(snapshot(movedUp) == [["bottom", "top", "middle"]])
        #expect(movedUp.workspaces[0].focusedWindowID == "middle")
        #expect(movedUp.workspaces[0].activeColumn?.activeWindowIndex == 2)

        let movedDown = assertValid(PureLayoutReducer.moveFocusedWindow(.down, in: movedUp))
        #expect(movedDown == world)
    }

    @Test func moveHorizontalExpelsStackedWindowIntoNewColumnOnDirectionSide() {
        let world = makeWorld(columns: [column(0, ["A1", "A2"], active: 1), column(1, ["B"])], nextColumnID: 10)

        let right = assertValid(PureLayoutReducer.moveFocusedWindow(.right, in: world))
        #expect(snapshot(right) == [["A1"], ["A2"], ["B"]])
        #expect(right.workspaces[0].columns.map(\.id.rawValue) == [0, 10, 1])
        #expect(right.workspaces[0].activeColumnIndex == 1)
        #expect(right.workspaces[0].focusedWindowID == "A2")
        #expect(right.nextColumnID == 11)

        let left = assertValid(PureLayoutReducer.moveFocusedWindow(.left, in: world))
        #expect(snapshot(left) == [["A2"], ["A1"], ["B"]])
        #expect(left.workspaces[0].columns.map(\.id.rawValue) == [10, 0, 1])
        #expect(left.workspaces[0].activeColumnIndex == 0)
    }

    @Test func moveHorizontalConsumesSoloWindowIntoNeighborVisualBottom() {
        let world = makeWorld(columns: [column(0, ["A"]), column(1, ["B-bottom", "B-top"], active: 1)])

        let moved = assertValid(PureLayoutReducer.moveFocusedWindow(.right, in: world))

        #expect(snapshot(moved) == [["A", "B-bottom", "B-top"]])
        #expect(moved.workspaces[0].columns[0].id.rawValue == 1)
        #expect(moved.workspaces[0].activeColumnIndex == 0)
        #expect(moved.workspaces[0].columns[0].activeWindowIndex == 0)
        #expect(moved.workspaces[0].focusedWindowID == "A")
    }

    @Test func moveHorizontalDoesNotConsumePastEdgeByDefault() {
        let world = makeWorld(columns: [column(0, ["A"]), column(1, ["B"])])
        let moved = assertValid(PureLayoutReducer.moveFocusedWindow(.left, in: world))

        #expect(moved == world)
    }

    @Test func moveHorizontalWrapsAtEdgeWhenInfiniteLoopEnabled() {
        var world = makeWorld(columns: [column(0, ["A"]), column(1, ["B1", "B2"], active: 1)])
        world.config.infiniteLoop = true

        let moved = assertValid(PureLayoutReducer.moveFocusedWindow(.left, in: world))

        #expect(snapshot(moved) == [["A", "B1", "B2"]])
        #expect(moved.workspaces[0].columns[0].id.rawValue == 1)
        #expect(moved.workspaces[0].focusedWindowID == "A")
    }

    @Test func switchWorkspaceSelectsDestinationFirstVisibleTile() {
        let workspace0 = CoreWorkspace(id: 0, columns: [column(0, ["A"])], activeColumnIndex: 0)
        let workspace1 = CoreWorkspace(id: 1, columns: [column(10, ["B-bottom", "B-top"], active: 0)], activeColumnIndex: 0)
        let world = World(workspaces: [workspace0, workspace1], activeWorkspaceIndex: 0, nextColumnID: 11, config: .init())

        let moved = assertValid(PureLayoutReducer.switchWorkspace(by: 1, in: world))

        #expect(moved.activeWorkspaceIndex == 1)
        #expect(moved.workspaces[1].activeColumnIndex == 0)
        #expect(moved.workspaces[1].focusedWindowID == "B-top")
    }

    @Test func invariantsRejectEmptyColumnsDuplicateWindowIDsAndInvalidFocus() {
        let invalid = World(
            workspaces: [
                CoreWorkspace(
                    id: 0,
                    columns: [
                        CoreColumn(id: .init(rawValue: 0), windows: [], activeWindowIndex: 0),
                        CoreColumn(id: .init(rawValue: 0), windows: [CoreWindow(id: "dup")], activeWindowIndex: 3),
                        CoreColumn(id: .init(rawValue: 2), windows: [CoreWindow(id: "dup")], activeWindowIndex: 0)
                    ],
                    activeColumnIndex: 9
                )
            ],
            activeWorkspaceIndex: 3,
            nextColumnID: 2,
            config: .init()
        )

        let violations = PureLayoutInvariants.validate(invalid).map(\.message)

        #expect(violations.contains { $0.contains("activeWorkspaceIndex") })
        #expect(violations.contains { $0.contains("invalid activeColumnIndex") })
        #expect(violations.contains { $0.contains("empty column") })
        #expect(violations.contains { $0.contains("duplicate column id") })
        #expect(violations.contains { $0.contains("invalid activeWindowIndex") })
        #expect(violations.contains { $0.contains("duplicate window id") })
        #expect(violations.contains { $0.contains("nextColumnID") })
    }

    private func column(_ id: Int, _ windows: [String], active: Int = 0) -> CoreColumn<String> {
        CoreColumn(id: .init(rawValue: id), windows: windows.map { CoreWindow(id: $0) }, activeWindowIndex: active)
    }

    private func makeWorld(columns: [CoreColumn<String>], nextColumnID: Int = 100) -> World {
        World(
            workspaces: [CoreWorkspace(id: 0, columns: columns, activeColumnIndex: columns.isEmpty ? nil : 0)],
            activeWorkspaceIndex: 0,
            nextColumnID: nextColumnID,
            config: .init()
        )
    }

    private func snapshot(_ world: World) -> [[String]] {
        world.workspaces[world.activeWorkspaceIndex].columns.map { $0.windows.map(\.id) }
    }

    @discardableResult
    private func assertValid(_ world: World) -> World {
        #expect(PureLayoutInvariants.validate(world).isEmpty)
        return world
    }
}
