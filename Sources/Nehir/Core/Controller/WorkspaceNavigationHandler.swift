// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation
import NehirIPC

@MainActor
final class WorkspaceNavigationHandler {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    private struct WindowTransferResult {
        let succeeded: Bool
        let sourceWorkspaceId: WorkspaceDescriptor.ID?
        let newSourceFocusToken: WindowToken?
    }

    private func applySessionPatch(
        workspaceId: WorkspaceDescriptor.ID,
        viewportState: ViewportState? = nil,
        rememberedFocusToken: WindowToken? = nil
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: viewportState,
                rememberedFocusToken: rememberedFocusToken
            )
        )
    }

    private func applySessionTransfer(
        sourceWorkspaceId: WorkspaceDescriptor.ID?,
        sourceState: ViewportState?,
        sourceFocusedToken: WindowToken?,
        targetWorkspaceId: WorkspaceDescriptor.ID?,
        targetState: ViewportState?,
        targetFocusedToken: WindowToken?
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionTransfer(
            .init(
                sourcePatch: sourceWorkspaceId.map {
                    .init(
                        workspaceId: $0,
                        viewportState: sourceState,
                        rememberedFocusToken: sourceFocusedToken
                    )
                },
                targetPatch: targetWorkspaceId.map {
                    .init(
                        workspaceId: $0,
                        viewportState: targetState,
                        rememberedFocusToken: targetFocusedToken
                    )
                }
            )
        )
    }

    private func commitWorkspaceSelection(
        nodeId: NodeId?,
        focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: nodeId,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: monitorId
        )
    }

    private func interactionMonitorId(for controller: WMController) -> Monitor.ID? {
        controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
    }

    private func affectedWorkspaceIds(
        sourceWorkspaceId: WorkspaceDescriptor.ID?,
        targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> Set<WorkspaceDescriptor.ID> {
        var ids: Set<WorkspaceDescriptor.ID> = [targetWorkspaceId]
        if let sourceWorkspaceId {
            ids.insert(sourceWorkspaceId)
        }
        return ids
    }

    private func prepareMovedWindowTargetViewport(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        reveal: Bool = true
    ) {
        guard let controller else { return }

        var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let engine = controller.niriEngine,
           let movedNode = engine.findNode(for: token),
           engine.findColumn(containing: movedNode, in: workspaceId) != nil
        {
            targetState.selectedNodeId = movedNode.id

            if reveal,
               let monitor = controller.workspaceManager.monitor(for: workspaceId)
            {
                let gap = controller.gapSize(for: monitor)
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                engine.ensureSelectionVisible(
                    node: movedNode,
                    in: workspaceId,
                    motion: controller.motionPolicy.snapshot(),
                    state: &targetState,
                    workingFrame: workingFrame,
                    gaps: gap
                )
            }
        }

        applySessionPatch(
            workspaceId: workspaceId,
            viewportState: targetState,
            rememberedFocusToken: token
        )
    }

    private struct WorkspaceTransitionFocusHandoff {
        let focusToken: WindowToken?
        let shouldClearManagedFocus: Bool
    }

    private func resolveWorkspaceTransitionFocusHandoff(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> WorkspaceTransitionFocusHandoff {
        guard let controller else {
            return WorkspaceTransitionFocusHandoff(
                focusToken: nil,
                shouldClearManagedFocus: false
            )
        }
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: workspaceId)
        let shouldClearManagedFocus = focusToken == nil && controller.workspaceManager.entries(in: workspaceId).isEmpty
        return WorkspaceTransitionFocusHandoff(
            focusToken: focusToken,
            shouldClearManagedFocus: shouldClearManagedFocus
        )
    }

    private func clearManagedFocusAfterEmptyWorkspaceSwitch(to monitor: Monitor?) {
        guard let controller else { return }
        let canceledRequest = controller.focusBridge.cancelManagedRequest()
        if let canceledRequest {
            controller.focusBridge.discardPendingFocus(canceledRequest.token)
        }
        controller.clearKeyboardFocusTarget()
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
        controller.focusBorderController.clear()
        if controller.moveMouseToFocusedWindowEnabled, let monitor {
            controller.moveMouseToMonitor(monitor)
        }
    }

    private func commitWorkspaceTransitionFocusHandoff(
        targetWorkspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor?,
        startScrollAnimation: Bool
    ) {
        guard let controller else { return }
        let handoff = resolveWorkspaceTransitionFocusHandoff(for: targetWorkspaceId)
        let focusedTokenNeedsRevealRelayout = handoff.focusToken.flatMap {
            controller.workspaceManager.hiddenState(for: $0)
        }?.workspaceInactive == true
        if let monitor {
            controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            reason: .workspaceTransition
        ) { [weak self, weak controller] in
            guard let controller else { return }
            if let focusToken = handoff.focusToken {
                controller.focusWindow(focusToken, reason: .workspaceTransitionHandoff)
                if focusedTokenNeedsRevealRelayout {
                    controller.axManager.forceApplyNextFrame(for: focusToken.windowId)
                    controller.layoutRefreshController.requestRefresh(
                        reason: .workspaceTransition,
                        affectedWorkspaceIds: [targetWorkspaceId]
                    )
                }
            } else if handoff.shouldClearManagedFocus {
                self?.clearManagedFocusAfterEmptyWorkspaceSwitch(to: monitor)
            }
            if startScrollAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: targetWorkspaceId)
            }
        }
    }

    func focusMonitorCyclic(previous: Bool) {
        guard let controller else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        let targetMonitor: Monitor? = if previous {
            controller.workspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            controller.workspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let target = targetMonitor else { return }
        switchToMonitor(target.id, fromMonitor: currentMonitorId)
    }

    func focusLastMonitor() {
        guard let controller else { return }
        guard let previousId = controller.workspaceManager.previousInteractionMonitorId else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        guard controller.workspaceManager.monitors.contains(where: { $0.id == previousId }) else { return }

        switchToMonitor(previousId, fromMonitor: currentMonitorId)
    }

    private func switchToMonitor(_ targetMonitorId: Monitor.ID, fromMonitor currentMonitorId: Monitor.ID) {
        guard let controller else { return }

        guard let target = controller.workspaceManager.monitor(byId: targetMonitorId),
              let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: targetMonitorId)
        else {
            return
        }

        _ = controller.workspaceManager.setInteractionMonitor(targetMonitorId)
        let handoff = resolveWorkspaceTransitionFocusHandoff(for: targetWorkspace.id)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [targetWorkspace.id],
            reason: .workspaceTransition
        ) { [weak self, weak controller] in
            guard let controller else { return }
            if let focusToken = handoff.focusToken {
                controller.focusWindow(focusToken, reason: .workspaceTransitionHandoff)
            } else if handoff.shouldClearManagedFocus {
                self?.clearManagedFocusAfterEmptyWorkspaceSwitch(to: target)
            }
        }
    }

    func swapCurrentWorkspaceWithMonitor(direction: Direction) {
        guard let controller else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }
        guard let currentWsId = controller.interactionWorkspace()?.id else { return }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return }

        guard let targetWsId = controller.workspaceManager.activeWorkspace(on: targetMonitor.id)?.id
        else { return }

        saveNiriViewportState(for: currentWsId)
        if let engine = controller.niriEngine {
            if let targetToken = controller.workspaceManager.rememberedTiledFocusToken(in: targetWsId),
               let targetNode = engine.findNode(for: targetToken)
            {
                commitWorkspaceSelection(
                    nodeId: targetNode.id,
                    focusedToken: targetToken,
                    in: targetWsId
                )
            }
        }

        guard controller.workspaceManager.swapWorkspaces(
            currentWsId, on: currentMonitorId,
            with: targetWsId, on: targetMonitor.id
        ) else { return }

        controller.syncMonitorsToNiriEngine()

        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: targetWsId)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [currentWsId, targetWsId],
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken, reason: .workspaceTransitionHandoff)
            }
        }
    }

    func switchWorkspace(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        switchWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func switchWorkspace(rawWorkspaceID: String) {
        guard let controller else { return }
        let currentWorkspace = controller.interactionWorkspace()
        if let currentWorkspace,
           currentWorkspace.name == rawWorkspaceID
        {
            return
        }

        controller.focusBorderController.hide()

        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(
            for: rawWorkspaceID,
            createIfMissing: false
        ),
            controller.workspaceManager.monitorForWorkspace(targetWorkspaceId) != nil
        else {
            return
        }

        guard let result = controller.workspaceManager.focusWorkspace(named: rawWorkspaceID) else { return }

        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: result.workspace.id,
            monitor: result.monitor,
            startScrollAnimation: false
        )
    }

    func switchWorkspaceRelative(isNext: Bool, wrapAround: Bool = true) {
        guard let controller else { return }
        controller.focusBorderController.hide()

        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }
        guard let currentWorkspace = controller.interactionWorkspace() else { return }

        let targetWorkspace: WorkspaceDescriptor? = if isNext {
            controller.workspaceManager.nextWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        } else {
            controller.workspaceManager.previousWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        }

        guard let targetWorkspace else { return }

        saveNiriViewportState(for: currentWorkspace.id)
        guard controller.workspaceManager.setActiveWorkspace(targetWorkspace.id, on: currentMonitorId) else {
            return
        }

        let monitor = controller.workspaceManager.monitor(for: targetWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: targetWorkspace.id,
            monitor: monitor,
            startScrollAnimation: false
        )
    }

    func saveNiriViewportState(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }

        if let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
           controller.workspaceManager.workspace(for: focusedToken) == workspaceId,
           let focusedNode = engine.findNode(for: focusedToken)
        {
            commitWorkspaceSelection(
                nodeId: focusedNode.id,
                focusedToken: focusedToken,
                in: workspaceId
            )
        }
    }

    func focusWorkspaceAnywhere(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        focusWorkspaceAnywhere(rawWorkspaceID: rawWorkspaceID)
    }

    func focusWorkspaceAnywhere(rawWorkspaceID: String) {
        guard let controller else { return }
        controller.focusBorderController.hide()

        let currentWorkspace = controller.interactionWorkspace()

        guard let targetWsId = controller.workspaceManager.workspaceId(named: rawWorkspaceID) else { return }
        guard let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWsId) else { return }

        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let currentMonitorId = interactionMonitorId(for: controller)

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            if let currentTargetWs = controller.workspaceManager.activeWorkspace(on: targetMonitor.id) {
                saveNiriViewportState(for: currentTargetWs.id)
            }
        }

        guard controller.workspaceManager.setActiveWorkspace(targetWsId, on: targetMonitor.id) else { return }

        controller.syncMonitorsToNiriEngine()

        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: targetWsId,
            monitor: targetMonitor,
            startScrollAnimation: false
        )
    }

    func workspaceBackAndForth() {
        guard let controller else { return }
        controller.focusBorderController.hide()

        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        guard let prevWorkspace = controller.workspaceManager.previousWorkspace(on: currentMonitorId) else {
            return
        }

        let currentWorkspace = controller.interactionWorkspace()
        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard controller.workspaceManager.setActiveWorkspace(prevWorkspace.id, on: currentMonitorId) else {
            return
        }

        let monitor = controller.workspaceManager.monitor(for: prevWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: prevWorkspace.id,
            monitor: monitor,
            startScrollAnimation: false
        )
    }

    /// Activates `targetWorkspaceId` on whichever monitor it belongs to and
    /// focuses `targetToken` there, moving the interaction monitor with it.
    ///
    /// This is the cross-workspace path for "Focus Previous Window": when the
    /// globally most-recently-focused window lives on another workspace, switch
    /// to that workspace and activate the window in its own workspace — instead
    /// of re-activating it under the current workspace id (which would be
    /// incoherent, since the node does not belong to the current workspace).
    /// Mirrors the remembered-window restore path used by the other workspace
    /// switches (`switchWorkspace`, `workspaceBackAndForth`,
    /// `swapCurrentWorkspaceWithMonitor`).
    func activateWorkspace(
        _ targetWorkspaceId: WorkspaceDescriptor.ID,
        focusing targetToken: WindowToken
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine,
              let targetNode = engine.findNode(for: targetToken)
        else { return }
        guard let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWorkspaceId) else {
            return
        }
        guard engine.workspaceId(containing: targetNode.id) == targetWorkspaceId else {
            return
        }

        controller.focusBorderController.hide()

        if let currentWorkspace = controller.interactionWorkspace() {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        // Pin the target window as the workspace's focus so the post-switch
        // handoff activates exactly this window, rather than the workspace's
        // generic remembered/first candidate.
        commitWorkspaceSelection(
            nodeId: targetNode.id,
            focusedToken: targetToken,
            in: targetWorkspaceId
        )

        guard controller.workspaceManager.setActiveWorkspace(targetWorkspaceId, on: targetMonitor.id) else {
            return
        }
        controller.syncMonitorsToNiriEngine()

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [targetWorkspaceId],
            reason: .workspaceTransition
        ) { [weak controller] in
            controller?.focusWindow(targetToken, reason: .activateWorkspace)
        }
    }

    private func resolveOrCreateAdjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        on monitorId: Monitor.ID
    ) -> WorkspaceDescriptor? {
        guard let controller else { return nil }
        let wm = controller.workspaceManager

        let existing: WorkspaceDescriptor? = if direction == .down {
            wm.nextWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        } else {
            wm.previousWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        }
        if let existing { return existing }

        guard let currentName = wm.descriptor(for: workspaceId)?.name,
              let currentNumber = Int(currentName)
        else { return nil }

        let candidateNumber = direction == .down ? currentNumber + 1 : currentNumber - 1
        guard candidateNumber > 0 else { return nil }

        let candidateName = String(candidateNumber)
        guard wm.workspaceId(named: candidateName) == nil else { return nil }

        guard let targetId = wm.workspaceId(for: candidateName, createIfMissing: false) else { return nil }
        wm.assignWorkspaceToMonitor(targetId, monitorId: monitorId)
        return wm.descriptor(for: targetId)
    }

    private func transferWindowFromSourceEngine(
        token: WindowToken,
        from sourceWsId: WorkspaceDescriptor.ID?,
        to targetWsId: WorkspaceDescriptor.ID
    ) -> WindowTransferResult {
        guard let controller else {
            return WindowTransferResult(succeeded: false, sourceWorkspaceId: sourceWsId, newSourceFocusToken: nil)
        }
        var actualSourceWsId = sourceWsId
        var newSourceFocusToken: WindowToken?
        var movedWithNiri = false

        if let sourceWsId,
           let engine = controller.niriEngine,
           let windowNode = engine.findNode(for: token)
        {
            let engineSourceWsId = niriWorkspaceContaining(windowNode, preferredWorkspaceId: sourceWsId)
            actualSourceWsId = engineSourceWsId
            var sourceState = controller.workspaceManager.niriViewportState(for: engineSourceWsId)
            var targetState = controller.workspaceManager.niriViewportState(for: targetWsId)
            if let result = engine.moveWindowToWorkspace(
                windowNode,
                from: engineSourceWsId,
                to: targetWsId,
                sourceState: &sourceState,
                targetState: &targetState
            ) {
                if let newFocusId = result.newFocusNodeId,
                   let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
                {
                    newSourceFocusToken = newFocusNode.token
                }
                applySessionTransfer(
                    sourceWorkspaceId: engineSourceWsId,
                    sourceState: sourceState,
                    sourceFocusedToken: newSourceFocusToken,
                    targetWorkspaceId: targetWsId,
                    targetState: targetState,
                    targetFocusedToken: nil
                )
                if engineSourceWsId != sourceWsId {
                    controller.diagnostics.recordRuntimeViewportTrace(
                        workspaceId: sourceWsId,
                        reason: "window_transfer_source_repaired",
                        details: [
                            "token=\(token)",
                            "engineSource=\(engineSourceWsId.uuidString)",
                            "modelSource=\(sourceWsId.uuidString)",
                            "target=\(targetWsId.uuidString)"
                        ]
                    )
                }
                movedWithNiri = true
            } else {
                controller.diagnostics.recordRuntimeViewportTrace(
                    workspaceId: sourceWsId,
                    reason: "window_transfer_niri_move_failed",
                    details: [
                        "token=\(token)",
                        "engineSource=\(engineSourceWsId.uuidString)",
                        "target=\(targetWsId.uuidString)"
                    ]
                )
            }
        }

        if !movedWithNiri,
           let sourceWsId,
           let engine = controller.niriEngine
        {
            var sourceState = controller.workspaceManager.niriViewportState(for: sourceWsId)
            if let currentNode = engine.findNode(for: token),
               sourceState.selectedNodeId == currentNode.id
            {
                sourceState.selectedNodeId = engine.fallbackSelectionOnRemoval(
                    removing: currentNode.id,
                    in: sourceWsId
                )
            }

            if let selectedId = sourceState.selectedNodeId,
               engine.findNode(by: selectedId) == nil
            {
                sourceState.selectedNodeId = engine.validateSelection(selectedId, in: sourceWsId)
            }

            if let selectedId = sourceState.selectedNodeId,
               let selectedNode = engine.findNode(by: selectedId) as? NiriWindow
            {
                newSourceFocusToken = selectedNode.token
            }

            applySessionTransfer(
                sourceWorkspaceId: sourceWsId,
                sourceState: sourceState,
                sourceFocusedToken: newSourceFocusToken,
                targetWorkspaceId: nil,
                targetState: nil,
                targetFocusedToken: nil
            )
        }

        let succeeded: Bool
        if movedWithNiri {
            succeeded = true
        } else if sourceWsId == nil {
            succeeded = true
        } else {
            succeeded = false
        }

        if !succeeded, let sourceWsId {
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: sourceWsId,
                reason: "window_transfer_rejected",
                details: [
                    "token=\(token)",
                    "target=\(targetWsId.uuidString)",
                    "movedWithNiri=\(movedWithNiri)"
                ]
            )
        }

        return WindowTransferResult(
            succeeded: succeeded,
            sourceWorkspaceId: actualSourceWsId,
            newSourceFocusToken: newSourceFocusToken
        )
    }

    private func niriWorkspaceContaining(
        _ window: NiriWindow,
        preferredWorkspaceId: WorkspaceDescriptor.ID
    ) -> WorkspaceDescriptor.ID {
        guard let controller,
              let engine = controller.niriEngine
        else { return preferredWorkspaceId }

        if engine.findColumn(containing: window, in: preferredWorkspaceId) != nil {
            return preferredWorkspaceId
        }

        return controller.workspaceManager.workspaces.first { workspace in
            engine.findColumn(containing: window, in: workspace.id) != nil
        }?.id ?? preferredWorkspaceId
    }

    func moveWindowToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let token = controller.managedCommandTargetToken() else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }
        guard let wsId = controller.interactionWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        let transferResult = transferWindowFromSourceEngine(token: token, from: wsId, to: targetWorkspace.id)
        guard transferResult.succeeded else { return }

        controller.reassignManagedWindow(token, to: targetWorkspace.id)
        prepareMovedWindowTargetViewport(token: token, workspaceId: targetWorkspace.id)

        let actualSourceWsId = transferResult.sourceWorkspaceId ?? wsId
        let sourceState = controller.workspaceManager.niriViewportState(for: actualSourceWsId)
        controller.recoverSourceFocusAfterMove(in: actualSourceWsId, preferredNodeId: sourceState.selectedNodeId)
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: actualSourceWsId)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: affectedWorkspaceIds(
                sourceWorkspaceId: actualSourceWsId,
                targetWorkspaceId: targetWorkspace.id
            ),
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken, reason: .workspaceTransitionHandoff)
            }
        }
    }

    func moveColumnToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let token = controller.managedLayoutCommandTargetToken() else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }
        guard let wsId = controller.interactionWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        var sourceState = controller.workspaceManager.niriViewportState(for: wsId)
        var targetState = controller.workspaceManager.niriViewportState(for: targetWorkspace.id)

        guard let windowNode = engine.findNode(for: token),
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWorkspace.id,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        applySessionTransfer(
            sourceWorkspaceId: wsId,
            sourceState: sourceState,
            sourceFocusedToken: nil,
            targetWorkspaceId: targetWorkspace.id,
            targetState: targetState,
            targetFocusedToken: nil
        )

        for window in column.windowNodes {
            controller.reassignManagedWindow(window.token, to: targetWorkspace.id)
        }

        applySessionPatch(workspaceId: targetWorkspace.id, rememberedFocusToken: token)

        controller.recoverSourceFocusAfterMove(in: wsId, preferredNodeId: result.newFocusNodeId)
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: wsId)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: affectedWorkspaceIds(
                sourceWorkspaceId: wsId,
                targetWorkspaceId: targetWorkspace.id
            ),
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken, reason: .workspaceTransitionHandoff)
            }
        }
    }

    func moveColumnToWorkspaceByIndex(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveColumnToWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func moveColumnToWorkspace(rawWorkspaceID: String) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let token = controller.managedLayoutCommandTargetToken() else { return }
        guard let wsId = controller.interactionWorkspace()?.id else { return }

        guard let targetWsId = controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
        else { return }

        guard targetWsId != wsId else { return }

        saveNiriViewportState(for: wsId)

        var sourceState = controller.workspaceManager.niriViewportState(for: wsId)
        var targetState = controller.workspaceManager.niriViewportState(for: targetWsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWsId,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        applySessionTransfer(
            sourceWorkspaceId: wsId,
            sourceState: sourceState,
            sourceFocusedToken: nil,
            targetWorkspaceId: targetWsId,
            targetState: targetState,
            targetFocusedToken: nil
        )

        for window in column.windowNodes {
            controller.reassignManagedWindow(window.token, to: targetWsId)
        }

        applySessionPatch(workspaceId: targetWsId, rememberedFocusToken: token)

        controller.recoverSourceFocusAfterMove(in: wsId, preferredNodeId: result.newFocusNodeId)
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: wsId)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: affectedWorkspaceIds(
                sourceWorkspaceId: wsId,
                targetWorkspaceId: targetWsId
            ),
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken, reason: .workspaceTransitionHandoff)
            }
        }
    }

    func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID)
    }

    func moveFocusedWindow(toRawWorkspaceID rawWorkspaceID: String) {
        guard let controller else { return }
        guard let token = controller.managedCommandTargetToken() else { return }
        guard let targetId = controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false),
              let target = controller.workspaceManager.descriptor(for: targetId)
        else {
            return
        }
        let currentWorkspaceId = controller.workspaceManager.workspace(for: token)
        let transferResult = transferWindowFromSourceEngine(token: token, from: currentWorkspaceId, to: target.id)
        guard transferResult.succeeded else { return }

        controller.reassignManagedWindow(token, to: target.id)
        let actualSourceWsId = transferResult.sourceWorkspaceId ?? currentWorkspaceId

        let shouldFollowFocus = controller.settings.focusFollowsWindowToMonitor
        if shouldFollowFocus {
            controller.isTransferringWindow = true
            defer { controller.isTransferringWindow = false }

            let targetMonitor = controller.workspaceManager.monitorForWorkspace(target.id)
            if let targetMonitor {
                _ = controller.workspaceManager.setActiveWorkspace(target.id, on: targetMonitor.id)
            }

            if let actualSourceWsId,
               let sourceMonitor = controller.workspaceManager.monitor(for: actualSourceWsId)
            {
                controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
            }
            prepareMovedWindowTargetViewport(token: token, workspaceId: target.id)
            controller.layoutRefreshController.commitWorkspaceTransition(
                affectedWorkspaces: affectedWorkspaceIds(
                    sourceWorkspaceId: actualSourceWsId,
                    targetWorkspaceId: target.id
                ),
                reason: .workspaceTransition
            ) { [weak controller] in
                controller?.focusWindow(token, reason: .moveWindowToWorkspace)
            }
        } else {
            commitNonFollowingWindowMove(
                token: token,
                actualSourceWsId: actualSourceWsId,
                targetWorkspaceId: target.id
            )
        }
    }

    @discardableResult
    func moveWindow(handle: WindowHandle, toWorkspaceId targetWsId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }
        let token = handle.id

        let currentWorkspaceId = controller.workspaceManager.workspace(for: token)
        let transferResult = transferWindowFromSourceEngine(
            token: token,
            from: currentWorkspaceId,
            to: targetWsId
        )
        guard transferResult.succeeded else { return false }

        controller.reassignManagedWindow(token, to: targetWsId)
        prepareMovedWindowTargetViewport(token: token, workspaceId: targetWsId)

        let actualSourceWsId = transferResult.sourceWorkspaceId ?? currentWorkspaceId
        if let actualSourceWsId {
            let sourceState = controller.workspaceManager.niriViewportState(for: actualSourceWsId)
            controller.recoverSourceFocusAfterMove(in: actualSourceWsId, preferredNodeId: sourceState.selectedNodeId)
        }

        return true
    }

    /// Moves a window to another workspace via the engine, updates the model
    /// assignment, and commits the workspace transition so both workspaces are
    /// re-laid-out. This is the explicit-token, non-focus-following move used by
    /// workspace-bar interactions (right-click "Move to Workspace"). Unlike
    /// `moveWindow(handle:toWorkspaceId:)` — a refresh-free primitive shared with
    /// summon-right and overview drag, which own their own refresh — this always
    /// drives the hide/show/frame refresh itself, so the moved window does not
    /// remain physically resting on the source workspace until an unrelated
    /// refresh applies the assignment.
    @discardableResult
    func moveWindowFromBar(handle: WindowHandle, toWorkspaceId targetWsId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }
        let token = handle.id

        let currentWorkspaceId = controller.workspaceManager.workspace(for: token)
        let transferResult = transferWindowFromSourceEngine(
            token: token,
            from: currentWorkspaceId,
            to: targetWsId
        )
        guard transferResult.succeeded else { return false }

        controller.reassignManagedWindow(token, to: targetWsId)

        let actualSourceWsId = transferResult.sourceWorkspaceId ?? currentWorkspaceId
        commitNonFollowingWindowMove(
            token: token,
            actualSourceWsId: actualSourceWsId,
            targetWorkspaceId: targetWsId
        )
        return true
    }

    /// Shared commit tail for a non-focus-following window move: recovers source
    /// focus, stops any in-flight scroll on the source monitor, prepares the
    /// target viewport, and schedules the workspace-transition refresh that
    /// actually re-lays-out both workspaces. Used by the hotkey move (when not
    /// following focus to the target monitor) and the bar right-click move.
    private func commitNonFollowingWindowMove(
        token: WindowToken,
        actualSourceWsId: WorkspaceDescriptor.ID?,
        targetWorkspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }

        if let actualSourceWsId {
            let sourceState = controller.workspaceManager.niriViewportState(for: actualSourceWsId)
            controller.recoverSourceFocusAfterMove(
                in: actualSourceWsId,
                preferredNodeId: sourceState.selectedNodeId
            )
        }
        let focusToken = actualSourceWsId.flatMap { controller.resolveAndSetWorkspaceFocusToken(for: $0) }

        if let actualSourceWsId,
           let sourceMonitor = controller.workspaceManager.monitor(for: actualSourceWsId)
        {
            controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
        }
        prepareMovedWindowTargetViewport(token: token, workspaceId: targetWorkspaceId)
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: affectedWorkspaceIds(
                sourceWorkspaceId: actualSourceWsId,
                targetWorkspaceId: targetWorkspaceId
            ),
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken, reason: .workspaceTransitionHandoff)
            }
        }
    }

    func moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, workspaceIndex) + 1) else { return }
        moveWindowToWorkspaceOnMonitor(rawWorkspaceID: rawWorkspaceID, monitorDirection: monitorDirection)
    }

    func moveWindowToWorkspaceOnMonitor(rawWorkspaceID: String, monitorDirection: Direction) {
        guard let controller else { return }
        guard let token = controller.managedCommandTargetToken() else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }
        guard let currentWorkspaceId = controller.workspaceManager.workspace(for: token) else { return }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: monitorDirection
        ) else { return }

        guard let targetWsId = controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
        else { return }
        let assignedTargetMonitorId = controller.workspaceManager.monitorId(for: targetWsId)
        guard assignedTargetMonitorId == targetMonitor.id else {
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: currentWorkspaceId,
                reason: "window_transfer_rejected_workspace_monitor_mismatch",
                details: [
                    "token=\(token)",
                    "targetWorkspace=\(targetWsId.uuidString)",
                    "requestedMonitor=\(targetMonitor.id)",
                    "assignedMonitor=\(String(describing: assignedTargetMonitorId))"
                ]
            )
            return
        }

        let transferResult = transferWindowFromSourceEngine(
            token: token, from: currentWorkspaceId, to: targetWsId
        )
        guard transferResult.succeeded else { return }

        controller.reassignManagedWindow(token, to: targetWsId)
        let actualSourceWsId = transferResult.sourceWorkspaceId ?? currentWorkspaceId

        let shouldFollowFocus = controller.settings.focusFollowsWindowToMonitor

        if shouldFollowFocus {
            if let monitor = controller.workspaceManager.monitorForWorkspace(targetWsId) {
                _ = controller.workspaceManager.setActiveWorkspace(targetWsId, on: monitor.id)
            }

            prepareMovedWindowTargetViewport(token: token, workspaceId: targetWsId)

            controller.layoutRefreshController.commitWorkspaceTransition(
                affectedWorkspaces: affectedWorkspaceIds(
                    sourceWorkspaceId: actualSourceWsId,
                    targetWorkspaceId: targetWsId
                ),
                reason: .workspaceTransition
            ) { [weak controller] in
                controller?.focusWindow(token, reason: .moveWindowToWorkspace)
            }
        } else {
            let sourceState = controller.workspaceManager.niriViewportState(for: actualSourceWsId)
            controller.recoverSourceFocusAfterMove(in: actualSourceWsId, preferredNodeId: sourceState.selectedNodeId)
            let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: actualSourceWsId)

            prepareMovedWindowTargetViewport(token: token, workspaceId: targetWsId)
            controller.layoutRefreshController.commitWorkspaceTransition(
                affectedWorkspaces: affectedWorkspaceIds(
                    sourceWorkspaceId: actualSourceWsId,
                    targetWorkspaceId: targetWsId
                ),
                reason: .workspaceTransition
            ) { [weak controller] in
                if let focusToken {
                    controller?.focusWindow(focusToken, reason: .workspaceTransitionHandoff)
                }
            }
        }
    }
}
