import Foundation

enum PureLayoutReducer {
    static func focus<WSID: Hashable, ID: Hashable>(
        _ direction: PureDirection,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID> {
        guard let horizontalStep = direction.horizontalStep else {
            return focusVertical(direction, in: world)
        }

        var result = world
        guard let workspaceIndex = activeWorkspaceIndex(in: result),
              let activeColumnIndex = result.workspaces[workspaceIndex].activeColumnIndex
        else { return world }

        let columns = result.workspaces[workspaceIndex].columns
        guard let targetColumnIndex = resolvedIndex(
            activeColumnIndex + horizontalStep,
            count: columns.count,
            wrapping: result.config.infiniteLoop
        ) else { return world }

        result.workspaces[workspaceIndex].columns[targetColumnIndex].clampActiveWindowIndex()
        result.workspaces[workspaceIndex].activeColumnIndex = targetColumnIndex
        return validated(result)
    }

    static func moveFocusedWindow<WSID: Hashable, ID: Hashable>(
        _ direction: PureDirection,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID> {
        if direction.horizontalStep != nil {
            return moveFocusedWindowHorizontal(direction, in: world)
        }
        return moveFocusedWindowVertical(direction, in: world)
    }

    static func switchWorkspace<WSID: Hashable, ID: Hashable>(
        by delta: Int,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID> {
        guard delta != 0 else { return world }
        let targetWorkspaceIndex = world.activeWorkspaceIndex + delta
        guard world.workspaces.indices.contains(targetWorkspaceIndex) else { return world }

        var result = world
        result.activeWorkspaceIndex = targetWorkspaceIndex

        if result.workspaces[targetWorkspaceIndex].columns.isEmpty {
            result.workspaces[targetWorkspaceIndex].activeColumnIndex = nil
        } else {
            result.workspaces[targetWorkspaceIndex].activeColumnIndex = 0
            let windowCount = result.workspaces[targetWorkspaceIndex].columns[0].windows.count
            result.workspaces[targetWorkspaceIndex].columns[0].activeWindowIndex = max(0, windowCount - 1)
        }

        return validated(result)
    }

    static func focusWindow<WSID: Hashable, ID: Hashable>(
        columnIndex: Int,
        windowStorageIndex: Int,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID> {
        var result = world
        guard let workspaceIndex = activeWorkspaceIndex(in: result),
              result.workspaces[workspaceIndex].columns.indices.contains(columnIndex),
              result.workspaces[workspaceIndex].columns[columnIndex].windows.indices.contains(windowStorageIndex)
        else { return world }

        result.workspaces[workspaceIndex].activeColumnIndex = columnIndex
        result.workspaces[workspaceIndex].columns[columnIndex].activeWindowIndex = windowStorageIndex
        return validated(result)
    }

    private static func focusVertical<WSID: Hashable, ID: Hashable>(
        _ direction: PureDirection,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID> {
        guard let step = direction.verticalStorageStep else { return world }
        var result = world
        guard let workspaceIndex = activeWorkspaceIndex(in: result),
              let activeColumnIndex = result.workspaces[workspaceIndex].activeColumnIndex,
              result.workspaces[workspaceIndex].columns.indices.contains(activeColumnIndex)
        else { return world }

        let currentWindowIndex = result.workspaces[workspaceIndex].columns[activeColumnIndex].activeWindowIndex
        let targetWindowIndex = currentWindowIndex + step
        guard result.workspaces[workspaceIndex].columns[activeColumnIndex].windows.indices.contains(targetWindowIndex)
        else {
            return world
        }

        result.workspaces[workspaceIndex].columns[activeColumnIndex].activeWindowIndex = targetWindowIndex
        return validated(result)
    }

    private static func moveFocusedWindowHorizontal<WSID: Hashable, ID: Hashable>(
        _ direction: PureDirection,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID> {
        guard let step = direction.horizontalStep else { return world }
        var result = world
        guard let workspaceIndex = activeWorkspaceIndex(in: result),
              let sourceColumnIndex = result.workspaces[workspaceIndex].activeColumnIndex,
              result.workspaces[workspaceIndex].columns.indices.contains(sourceColumnIndex)
        else { return world }

        let sourceColumn = result.workspaces[workspaceIndex].columns[sourceColumnIndex]
        guard sourceColumn.windows.indices.contains(sourceColumn.activeWindowIndex) else { return world }

        if sourceColumn.windows.count > 1 {
            return expelFocusedWindow(
                direction: direction,
                in: result,
                workspaceIndex: workspaceIndex,
                sourceColumnIndex: sourceColumnIndex
            )
        }

        let columns = result.workspaces[workspaceIndex].columns
        guard let neighborIndex = resolvedIndex(
            sourceColumnIndex + step,
            count: columns.count,
            wrapping: result.config.infiniteLoop
        ), neighborIndex != sourceColumnIndex
        else { return world }

        let neighborID = columns[neighborIndex].id
        let movedWindow = sourceColumn.windows[sourceColumn.activeWindowIndex]
        result.workspaces[workspaceIndex].columns.remove(at: sourceColumnIndex)
        guard let targetIndexAfterRemoval = result.workspaces[workspaceIndex].columns
            .firstIndex(where: { $0.id == neighborID })
        else {
            return world
        }

        result.workspaces[workspaceIndex].columns[targetIndexAfterRemoval].windows.insert(movedWindow, at: 0)
        result.workspaces[workspaceIndex].columns[targetIndexAfterRemoval].activeWindowIndex = 0
        result.workspaces[workspaceIndex].activeColumnIndex = targetIndexAfterRemoval
        return validated(result)
    }

    private static func expelFocusedWindow<WSID: Hashable, ID: Hashable>(
        direction: PureDirection,
        in world: CoreWorld<WSID, ID>,
        workspaceIndex: Int,
        sourceColumnIndex: Int
    ) -> CoreWorld<WSID, ID> {
        var result = world
        guard let step = direction.horizontalStep else { return world }
        let activeWindowIndex = result.workspaces[workspaceIndex].columns[sourceColumnIndex].activeWindowIndex
        let movedWindow = result.workspaces[workspaceIndex].columns[sourceColumnIndex].windows
            .remove(at: activeWindowIndex)
        result.workspaces[workspaceIndex].columns[sourceColumnIndex].clampActiveWindowIndex()

        let newColumn = CoreColumn(
            id: CoreColumnID(rawValue: result.nextColumnID),
            windows: [movedWindow],
            activeWindowIndex: 0
        )
        result.nextColumnID += 1

        let insertionIndex = step > 0 ? sourceColumnIndex + 1 : sourceColumnIndex
        result.workspaces[workspaceIndex].columns.insert(newColumn, at: insertionIndex)
        result.workspaces[workspaceIndex].activeColumnIndex = insertionIndex
        return validated(result)
    }

    private static func moveFocusedWindowVertical<WSID: Hashable, ID: Hashable>(
        _ direction: PureDirection,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID> {
        guard let step = direction.verticalStorageStep else { return world }
        var result = world
        guard let workspaceIndex = activeWorkspaceIndex(in: result),
              let activeColumnIndex = result.workspaces[workspaceIndex].activeColumnIndex,
              result.workspaces[workspaceIndex].columns.indices.contains(activeColumnIndex)
        else { return world }

        let currentIndex = result.workspaces[workspaceIndex].columns[activeColumnIndex].activeWindowIndex
        let targetIndex = currentIndex + step
        guard result.workspaces[workspaceIndex].columns[activeColumnIndex].windows.indices.contains(targetIndex) else {
            return world
        }

        result.workspaces[workspaceIndex].columns[activeColumnIndex].windows.swapAt(currentIndex, targetIndex)
        result.workspaces[workspaceIndex].columns[activeColumnIndex].activeWindowIndex = targetIndex
        return validated(result)
    }

    private static func activeWorkspaceIndex<WSID: Hashable, ID: Hashable>(
        in world: CoreWorld<WSID, ID>
    ) -> Int? {
        guard world.workspaces.indices.contains(world.activeWorkspaceIndex) else { return nil }
        return world.activeWorkspaceIndex
    }

    private static func resolvedIndex(_ index: Int, count: Int, wrapping: Bool) -> Int? {
        guard count > 0 else { return nil }
        if wrapping {
            return ((index % count) + count) % count
        }
        return (0 ..< count).contains(index) ? index : nil
    }

    private static func validated<WSID: Hashable, ID: Hashable>(
        _ world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID> {
        assert(PureLayoutInvariants.validate(world).isEmpty)
        return world
    }
}

private extension CoreColumn {
    mutating func clampActiveWindowIndex() {
        if windows.isEmpty {
            activeWindowIndex = 0
        } else {
            activeWindowIndex = min(max(activeWindowIndex, 0), windows.count - 1)
        }
    }
}
