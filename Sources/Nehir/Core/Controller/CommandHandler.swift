// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

@MainActor
final class CommandHandler {
    weak var controller: WMController?
    var nativeFullscreenStateProvider: ((AXWindowRef) -> Bool)?
    var nativeFullscreenSetter: ((AXWindowRef, Bool) -> Bool)?
    var frontmostAppPidProvider: (() -> pid_t?)?
    var frontmostFocusedWindowTokenProvider: (() -> WindowToken?)?

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func handleHotkeyCommand(_ command: HotkeyCommand) -> ExternalCommandResult {
        guard let controller else { return .notFound }
        guard controller.isEnabled else { return .ignoredDisabled }
        if case let .focus(direction) = command,
           controller.navigateOverviewSelection(direction)
        {
            return .executed
        }
        return performCommand(command)
    }

    @discardableResult
    func handleCommand(_ command: HotkeyCommand) -> ExternalCommandResult {
        performCommand(command)
    }

    @discardableResult
    func performRestartClearingRuntimeState(enableTracing: Bool = false) -> ExternalCommandResult {
        guard let controller else { return .notFound }
        controller.diagnostics.restartAppClearingRuntimeState(enableTracing: enableTracing)
        return .executed
    }

    @discardableResult
    func performCommand(_ command: HotkeyCommand) -> ExternalCommandResult {
        guard let controller else { return .notFound }
        guard controller.isEnabled else { return .ignoredDisabled }
        guard !Self.shouldIgnoreCommand(command, isOverviewOpen: controller.isOverviewOpen()) else {
            return .ignoredOverview
        }

        switch command {
        case let .focus(direction):
            controller.layoutCoordinator.focusNeighbor(direction: direction)
        case .focusPrevious:
            controller.layoutCoordinator.focusPrevious()
        case let .move(direction):
            controller.layoutCoordinator.moveWindow(direction: direction)
        case .moveWindowDown:
            controller.layoutCoordinator.moveWindow(direction: .down)
        case .moveWindowUp:
            controller.layoutCoordinator.moveWindow(direction: .up)
        case .moveWindowDownOrToWorkspaceDown:
            controller.layoutCoordinator.moveWindowOrToAdjacentWorkspace(direction: .down)
        case .moveWindowUpOrToWorkspaceUp:
            controller.layoutCoordinator.moveWindowOrToAdjacentWorkspace(direction: .up)
        case .consumeOrExpelWindowLeft:
            controller.layoutCoordinator.consumeOrExpelWindow(direction: .left)
        case .consumeOrExpelWindowRight:
            controller.layoutCoordinator.consumeOrExpelWindow(direction: .right)
        case .consumeWindowIntoColumn:
            controller.layoutCoordinator.consumeWindowIntoColumn()
        case .expelWindowFromColumn:
            controller.layoutCoordinator.expelWindowFromColumn()
        case let .moveToWorkspace(index):
            controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: index)
        case .moveWindowToWorkspaceUp:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .up)
        case .moveWindowToWorkspaceDown:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .down)
        case let .moveColumnToWorkspace(index):
            controller.workspaceNavigationHandler.moveColumnToWorkspaceByIndex(index: index)
        case .moveColumnToWorkspaceUp:
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .up)
        case .moveColumnToWorkspaceDown:
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .down)
        case let .switchWorkspace(index):
            controller.workspaceNavigationHandler.switchWorkspace(index: index)
        case .switchWorkspaceNext:
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        case .switchWorkspacePrevious:
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: false)
        case .focusMonitorPrevious:
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: true)
        case .focusMonitorNext:
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: false)
        case .focusMonitorLast:
            controller.workspaceNavigationHandler.focusLastMonitor()
        case .toggleFullscreen:
            controller.layoutCoordinator.toggleFullscreen()
        case .toggleNativeFullscreen:
            toggleNativeFullscreenForFocused()
        case let .moveColumn(direction):
            controller.layoutCoordinator.moveColumn(direction: direction)
        case .moveColumnToFirst:
            controller.layoutCoordinator.moveColumnToFirst()
        case .moveColumnToLast:
            controller.layoutCoordinator.moveColumnToLast()
        case let .moveColumnToIndex(index):
            controller.layoutCoordinator.moveColumnToIndex(index: index)
        case .toggleColumnTabbed:
            controller.layoutCoordinator.toggleColumnTabbed()
        case .focusDownOrLeft:
            controller.layoutCoordinator.focusDownOrLeft()
        case .focusUpOrRight:
            controller.layoutCoordinator.focusUpOrRight()
        case let .focusWindowInColumn(index):
            controller.layoutCoordinator.focusWindowInColumn(index: index)
        case .focusWindowTop:
            controller.layoutCoordinator.focusWindowTop()
        case .focusWindowBottom:
            controller.layoutCoordinator.focusWindowBottom()
        case .focusWindowDownOrTop:
            controller.layoutCoordinator.focusWindowDownOrTop()
        case .focusWindowUpOrBottom:
            controller.layoutCoordinator.focusWindowUpOrBottom()
        case .focusWindowOrWorkspaceDown:
            controller.layoutCoordinator.focusWindowOrWorkspace(direction: .down)
        case .focusWindowOrWorkspaceUp:
            controller.layoutCoordinator.focusWindowOrWorkspace(direction: .up)
        case .focusColumnFirst:
            controller.layoutCoordinator.focusColumnFirst()
        case .focusColumnLast:
            controller.layoutCoordinator.focusColumnLast()
        case let .focusColumn(index):
            controller.layoutCoordinator.focusColumn(index: index)
        case .scrollViewportLeft:
            controller.layoutCoordinator.scrollViewport(direction: .left)
        case .scrollViewportRight:
            controller.layoutCoordinator.scrollViewport(direction: .right)
        case .cycleColumnWidthForward:
            controller.layoutCoordinator.cycleSize(forward: true)
        case .cycleColumnWidthBackward:
            controller.layoutCoordinator.cycleSize(forward: false)
        case .cycleWindowWidthForward:
            controller.layoutCoordinator.cycleWindowWidth(forward: true)
        case .cycleWindowWidthBackward:
            controller.layoutCoordinator.cycleWindowWidth(forward: false)
        case .cycleWindowHeightForward:
            controller.layoutCoordinator.cycleWindowHeight(forward: true)
        case .cycleWindowHeightBackward:
            controller.layoutCoordinator.cycleWindowHeight(forward: false)
        case .toggleColumnFullWidth:
            controller.layoutCoordinator.toggleColumnFullWidth()
        case .expandColumnToAvailableWidth:
            controller.layoutCoordinator.expandColumnToAvailableWidth()
        case .resetWindowHeight:
            controller.layoutCoordinator.resetWindowHeight()
        case let .setColumnWidth(change):
            controller.layoutCoordinator.setColumnWidth(change)
        case let .setWindowWidth(change):
            controller.layoutCoordinator.setWindowWidth(change)
        case let .setWindowHeight(change):
            controller.layoutCoordinator.setWindowHeight(change)
        case let .swapWorkspaceWithMonitor(direction):
            controller.workspaceNavigationHandler.swapCurrentWorkspaceWithMonitor(direction: direction)
        case .balanceSizes:
            controller.layoutCoordinator.balanceSizes()
        case .workspaceBackAndForth:
            controller.workspaceNavigationHandler.workspaceBackAndForth()
        case let .focusWorkspaceAnywhere(index):
            controller.workspaceNavigationHandler.focusWorkspaceAnywhere(index: index)
        case let .moveWindowToWorkspaceOnMonitor(wsIdx, monDir):
            controller.workspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(
                workspaceIndex: wsIdx,
                monitorDirection: monDir
            )
        case .openCommandPalette:
            controller.openCommandPalette()
        case .raiseAllFloatingWindows:
            controller.raiseAllFloatingWindows()
        case .rescueOffscreenWindows:
            _ = controller.rescueOffscreenWindows()
        case .toggleFocusedWindowFloating:
            return controller.toggleFocusedWindowFloating()
        case .toggleFocusedWindowSticky:
            return controller.toggleFocusedWindowSticky()
        case .assignFocusedWindowToScratchpad:
            return controller.assignFocusedWindowToScratchpad()
        case .toggleScratchpadWindow:
            return controller.toggleScratchpadWindow()
        case .openMenuAnywhere:
            controller.openMenuAnywhere()
        case .openSettings:
            SettingsWindowController.shared.show(settings: controller.settings, controller: controller)
        case .createAppRuleForFocusedWindow:
            let snapshot = controller.diagnostics.focusedWindowDecisionDebugSnapshot()
            guard let draft = snapshot.flatMap(AppRuleDraft.guided(from:)) else {
                return .notFound
            }
            SettingsWindowController.shared.show(
                settings: controller.settings,
                controller: controller,
                section: .appRules,
                pendingAppRuleDraft: draft
            )
        case .debugDumpRuntimeState:
            controller.diagnostics.dumpRuntimeState()
        case .debugResetRuntimeState:
            controller.diagnostics.resetRuntimeState()
        case .debugRestartClearingRuntimeState:
            controller.diagnostics.restartAppClearingRuntimeState()
        case .debugToggleTraceCapture:
            return controller.diagnostics.toggleRuntimeTraceCapture()
        case .toggleWorkspaceBarVisibility:
            controller.toggleWorkspaceBarVisibility()
        case .toggleOverview:
            controller.toggleOverview()
        case .toggleFocusFollowsMouse:
            let newValue = !controller.settings.focusFollowsMouse
            controller.settings.focusFollowsMouse = newValue
            controller.setFocusFollowsMouse(newValue)
        case .toggleFocusFollowsWindowToMonitor:
            controller.settings.focusFollowsWindowToMonitor.toggle()
        case .toggleMoveMouseToFocused:
            let newValue = !controller.settings.moveMouseToFocusedWindow
            controller.settings.moveMouseToFocusedWindow = newValue
            controller.setMoveMouseToFocusedWindow(newValue)
        case .toggleBordersEnabled:
            let newValue = !controller.settings.bordersEnabled
            controller.settings.bordersEnabled = newValue
            controller.setBordersEnabled(newValue)
        case .togglePreventSleepEnabled:
            let newValue = !controller.settings.preventSleepEnabled
            controller.settings.preventSleepEnabled = newValue
            controller.setPreventSleepEnabled(newValue)
        case .toggleIPCEnabled:
            controller.settings.ipcEnabled.toggle()
        }

        return .executed
    }

    static func shouldIgnoreCommand(_ command: HotkeyCommand, isOverviewOpen: Bool) -> Bool {
        isOverviewOpen
            && command != .toggleOverview
            && command != .debugDumpRuntimeState
            && command != .debugResetRuntimeState
            && command != .debugRestartClearingRuntimeState
            && command != .debugToggleTraceCapture
    }

    private func toggleNativeFullscreenForFocused() {
        guard let controller else { return }
        let setFullscreen = nativeFullscreenSetter ?? { axRef, fullscreen in
            AXWindowService.setNativeFullscreen(axRef, fullscreen: fullscreen)
        }
        let isFullscreen = nativeFullscreenStateProvider ?? { axRef in
            AXWindowService.isFullscreen(axRef)
        }

        if let token = controller.managedCommandTargetToken(),
           let entry = controller.workspaceManager.entry(for: token)
        {
            let currentState = isFullscreen(entry.axRef)
            if currentState {
                _ = controller.workspaceManager.requestNativeFullscreenExit(token, initiatedByCommand: true)
                guard setFullscreen(entry.axRef, false) else {
                    _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
                    return
                }
                return
            }

            _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: entry.workspaceId)
            guard setFullscreen(entry.axRef, true) else {
                _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
                return
            }
            return
        }

        guard controller.workspaceManager.isAppFullscreenActive
            || controller.workspaceManager.hasPendingNativeFullscreenTransition
        else {
            return
        }

        // Honor an injected provider's nil rather than falling through to live
        // state; fall back to AppKit/AX only when no provider is wired in.
        let frontmostPid: pid_t?
        if let frontmostAppPidProvider {
            frontmostPid = frontmostAppPidProvider()
        } else {
            frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        let frontmostToken: WindowToken?
        if let frontmostFocusedWindowTokenProvider {
            frontmostToken = frontmostFocusedWindowTokenProvider()
        } else {
            frontmostToken = frontmostPid.flatMap { controller.axEventHandler.focusedWindowToken(for: $0) }
        }
        guard let token = controller.workspaceManager.nativeFullscreenCommandTarget(frontmostToken: frontmostToken),
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return
        }

        _ = controller.workspaceManager.requestNativeFullscreenExit(token, initiatedByCommand: true)
        guard setFullscreen(entry.axRef, false) else {
            _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
            return
        }
    }
}
