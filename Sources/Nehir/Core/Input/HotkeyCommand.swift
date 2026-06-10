import Foundation

enum HotkeyCommand: Codable, Equatable, Hashable {
    case focus(Direction)
    case focusPrevious
    case move(Direction)
    case moveToWorkspace(Int)
    case moveWindowToWorkspaceUp
    case moveWindowToWorkspaceDown
    case moveColumnToWorkspace(Int)
    case moveColumnToWorkspaceUp
    case moveColumnToWorkspaceDown
    case switchWorkspace(Int)
    case switchWorkspaceNext
    case switchWorkspacePrevious
    case focusMonitorPrevious
    case focusMonitorNext
    case focusMonitorLast
    case toggleFullscreen
    case toggleNativeFullscreen
    case moveColumn(Direction)
    case moveColumnToFirst
    case moveColumnToLast
    case moveColumnToIndex(Int)
    case moveWindowDown
    case moveWindowUp
    case moveWindowDownOrToWorkspaceDown
    case moveWindowUpOrToWorkspaceUp
    case consumeOrExpelWindowLeft
    case consumeOrExpelWindowRight
    case consumeWindowIntoColumn
    case expelWindowFromColumn
    case toggleColumnTabbed

    case focusDownOrLeft
    case focusUpOrRight
    case focusWindowInColumn(Int)
    case focusWindowTop
    case focusWindowBottom
    case focusWindowDownOrTop
    case focusWindowUpOrBottom
    case focusWindowOrWorkspaceDown
    case focusWindowOrWorkspaceUp
    case focusColumnFirst
    case focusColumnLast
    case focusColumn(Int)
    case centerColumn
    case centerVisibleColumns
    case cycleColumnWidthForward
    case cycleColumnWidthBackward
    case cycleWindowWidthForward
    case cycleWindowWidthBackward
    case cycleWindowHeightForward
    case cycleWindowHeightBackward
    case toggleColumnFullWidth
    case expandColumnToAvailableWidth
    case resetWindowHeight
    case setColumnWidth(NiriSizeChange)
    case setWindowWidth(NiriSizeChange)
    case setWindowHeight(NiriSizeChange)

    case swapWorkspaceWithMonitor(Direction)

    case balanceSizes

    case workspaceBackAndForth
    case focusWorkspaceAnywhere(Int)
    case moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction)

    case openCommandPalette

    case raiseAllFloatingWindows
    case rescueOffscreenWindows
    case toggleFocusedWindowFloating
    case assignFocusedWindowToScratchpad
    case toggleScratchpadWindow

    case openMenuAnywhere

    case debugDumpRuntimeState
    case debugResetRuntimeState
    case debugRestartClearingRuntimeState
    case debugToggleTraceCapture

    case toggleWorkspaceBarVisibility
    case toggleOverview

    case toggleFocusFollowsMouse
    case toggleFocusFollowsWindowToMonitor
    case toggleMoveMouseToFocused
    case toggleBordersEnabled
    case togglePreventSleepEnabled
    case toggleIPCEnabled

    var displayName: String {
        ActionCatalog.title(for: self) ?? String(describing: self)
    }

}
