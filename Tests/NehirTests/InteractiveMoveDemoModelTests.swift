@testable import Nehir
import Testing

@MainActor
@Suite struct InteractiveMoveDemoModelTests {
    @Test func initialDemoSnapshotPreservesVisibleColumnAndWindowOrder() {
        let model = MoveDemoModel()

        #expect(model.currentWorkspace.columns.map(\.id) == [0, 1, 2, 3, 4, 5, 6])
        #expect(model.currentWorkspace.columns[1].windows.map(\.id) == [1, 2])
        #expect(model.focusedColumnId == 0)
        #expect(model.focusedWindowId == 0)
    }

    @Test func focusingStackedWindowUsesVisualIndexAtStorageBoundary() {
        let model = MoveDemoModel()

        model.focusWindow(columnId: 1, index: 0)
        #expect(model.focusedWindowId == 1)

        model.focusDown()
        #expect(model.focusedWindowId == 2)
    }

    @Test func verticalMoveKeepsPreExtractionVisibleOrderBehavior() {
        let model = MoveDemoModel()
        model.focusWindow(columnId: 1, index: 0)

        model.moveFocusedWindowVertical(direction: 1)
        #expect(model.currentWorkspace.columns[1].windows.map(\.id) == [2, 1])
        #expect(model.focusedWindowId == 1)

        model.moveFocusedWindowVertical(direction: -1)
        #expect(model.currentWorkspace.columns[1].windows.map(\.id) == [1, 2])
        #expect(model.focusedWindowId == 1)
    }

    @Test func consumeIntoStackedNeighborPlacesConsumedWindowAtVisibleBottom() {
        let model = MoveDemoModel()

        model.moveFocusedWindow(direction: 1)

        #expect(model.currentWorkspace.columns.map(\.id).prefix(1) == [1])
        #expect(model.currentWorkspace.columns[0].windows.map(\.id) == [1, 2, 0])
        #expect(model.focusedColumnId == 1)
        #expect(model.focusedWindowId == 0)
    }

    @Test func workspaceSwitchResetsScrollAndSelectsFirstVisibleTile() {
        let model = MoveDemoModel()
        model.scrollX = 42

        model.switchWorkspace(by: 1)

        #expect(model.currentWorkspaceIndex == 1)
        #expect(model.scrollX == 0)
        #expect(model.focusedColumnId == 100)
        #expect(model.focusedWindowId == 100)
    }
}
