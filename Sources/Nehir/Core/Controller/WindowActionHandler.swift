// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

/// Lightweight provenance for direct viewport navigation, used only by runtime
/// diagnostics so a bar/window-click capture can classify what initiated a
/// spring without inferring it from `animateToOffset.spring` alone.
enum NavigationSource: String {
    case workspaceBarWindow
    case workspaceBarWorkspace
    case hotkey
    case command
    case overview
    case focusConfirm
    case unknown
}

@MainActor
final class WindowActionHandler {
    private enum RaisableSurfaceBatchKey: Hashable {
        case application(pid_t)
        case ownedApplication
    }

    @MainActor
    private enum RaisableSurface {
        case managed(WindowModel.Entry)
        case external(pid: pid_t, windowId: Int, axRef: AXWindowRef)
        case owned(NSWindow)

        var windowId: Int {
            switch self {
            case let .managed(entry):
                entry.windowId
            case let .external(_, windowId, _):
                windowId
            case let .owned(window):
                window.windowNumber
            }
        }

        var sortPid: pid_t {
            switch self {
            case let .managed(entry):
                entry.pid
            case let .external(pid, _, _):
                pid
            case .owned:
                getpid()
            }
        }

        var batchKey: RaisableSurfaceBatchKey {
            switch self {
            case let .managed(entry):
                .application(entry.pid)
            case let .external(pid, _, _):
                .application(pid)
            case .owned:
                .ownedApplication
            }
        }
    }

    private struct FloatingWindowRaisePlan {
        let batches: [[RaisableSurface]]
    }

    weak var controller: WMController?
    private let orderWindow: (UInt32) -> Void
    private let visibleWindowInfoProvider: () -> [WindowServerInfo]
    private let axWindowRefProvider: (UInt32, pid_t) -> AXWindowRef?
    private let visibleOwnedWindowsProvider: () -> [NSWindow]
    private let frontOwnedWindow: (NSWindow) -> Void

    @ObservationIgnored
    private lazy var overviewController: OverviewController = {
        guard let controller else { fatalError("WindowActionHandler requires controller") }
        let oc = OverviewController(wmController: controller)
        oc.onActivateWindow = { [weak self] handle, workspaceId in
            self?.activateWindowFromOverview(handle: handle, workspaceId: workspaceId)
        }
        oc.onCloseWindow = { [weak self] handle in
            self?.closeWindow(handle: handle)
        }
        return oc
    }()

    init(
        controller: WMController,
        orderWindow: @escaping (UInt32) -> Void = {
            SkyLight.shared.orderWindow($0, relativeTo: 0, order: .above)
        },
        visibleWindowInfoProvider: @escaping () -> [WindowServerInfo] = {
            SkyLight.shared.queryAllVisibleWindows()
        },
        axWindowRefProvider: @escaping (UInt32, pid_t) -> AXWindowRef? = { windowId, pid in
            AXWindowService.axWindowRef(for: windowId, pid: pid)
        },
        visibleOwnedWindowsProvider: @escaping () -> [NSWindow] = {
            OwnedWindowRegistry.shared.visibleWindows(kind: .utility)
        },
        frontOwnedWindow: @escaping (NSWindow) -> Void = { window in
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    ) {
        self.controller = controller
        self.orderWindow = orderWindow
        self.visibleWindowInfoProvider = visibleWindowInfoProvider
        self.axWindowRefProvider = axWindowRefProvider
        self.visibleOwnedWindowsProvider = visibleOwnedWindowsProvider
        self.frontOwnedWindow = frontOwnedWindow
    }

    func openMenuAnywhere() {
        guard controller != nil else { return }
        MenuAnywhereController.shared.showNativeMenu()
    }

    func toggleOverview() {
        overviewController.toggle()
    }

    func navigateOverviewSelection(_ direction: Direction) -> Bool {
        guard overviewController.isOpen else { return false }
        overviewController.navigateSelection(direction)
        return true
    }

    func isOverviewOpen() -> Bool {
        overviewController.isOpen
    }

    func isPointInOverview(_ point: CGPoint) -> Bool {
        overviewController.isPointInside(point)
    }

    func selectedOverviewWindowForTests() -> WindowHandle? {
        overviewController.selectedWindowHandleForTests()
    }

    private func activateWindowFromOverview(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.entry(for: handle) != nil else { return }
        navigateToWindowInternal(token: handle.id, workspaceId: workspaceId, source: .overview)
    }

    var closeWindowForTests: ((WindowHandle) -> Void)?

    /// Closes a managed window by pressing its AX close button. Shared by the
    /// Overview and the workspace bar's right-click *Close* item so both paths
    /// use identical AX-close semantics.
    func closeWindow(handle: WindowHandle) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return }

        if let closeWindowForTests {
            closeWindowForTests(entry.handle)
            return
        }

        let element = entry.axRef.element
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        var closeButton: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
           let closeButton,
           CFGetTypeID(closeButton) == AXUIElementGetTypeID()
        {
            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Token-based convenience resolving the handle the same way
    /// `focusWindowFromBar(token:)` does, then delegating to `closeWindow(handle:)`.
    @discardableResult
    func closeWindow(token: WindowToken) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return false
        }
        closeWindow(handle: entry.handle)
        return true
    }

    func raiseAllFloatingWindows() {
        guard let controller else { return }
        guard !controller.isLockScreenActive else { return }
        if controller.hasStartedServices {
            guard !controller.isFrontmostAppLockScreen() else { return }
        }

        controller.restoreVisibleWorkspaceInactiveFloatingWindows()
        guard let plan = makeRaiseAllFloatingPlan() else { return }

        for batch in plan.batches {
            for surface in batch {
                orderWindow(UInt32(surface.windowId))
            }
            guard let anchor = batch.last else { continue }
            front(surface: anchor)
        }
    }

    func hasRaisableFloatingWindows() -> Bool {
        makeRaiseAllFloatingPlan() != nil || controller?.hasVisibleWorkspaceInactiveFloatingWindows() == true
    }

    @discardableResult
    func raiseFloatingWindow(_ token: WindowToken) -> Bool {
        guard let controller,
              !controller.isLockScreenActive
        else {
            return false
        }
        if controller.hasStartedServices {
            guard !controller.isFrontmostAppLockScreen() else { return false }
        }

        guard let entry = controller.workspaceManager.entry(for: token),
              entry.mode == .floating,
              entry.layoutReason == .standard,
              !controller.workspaceManager.isHiddenInCorner(token),
              controller.workspaceManager.visibleWorkspaceIds().contains(entry.workspaceId)
        else {
            return false
        }

        orderWindow(UInt32(entry.windowId))
        controller.focusWindow(token)
        return true
    }

    private func makeRaiseAllFloatingPlan() -> FloatingWindowRaisePlan? {
        guard let controller else { return nil }

        let managedSurfaces = controller.workspaceManager.visibleWorkspaceIds()
            .flatMap { workspaceId in
                controller.workspaceManager.floatingEntries(in: workspaceId)
            }
            .filter { entry in
                entry.layoutReason == .standard && !controller.workspaceManager.isHiddenInCorner(entry.token)
            }
            .map(RaisableSurface.managed)
        let ownedSurfaces = visibleOwnedWindowsProvider()
            .filter { $0.windowNumber > 0 }
            .map(RaisableSurface.owned)
        var excludedWindowIds = Set(managedSurfaces.map(\.windowId))
        excludedWindowIds.formUnion(ownedSurfaces.map(\.windowId))
        let externalSurfaces = visibleExternalFloatingSurfaces(excludingWindowIds: excludedWindowIds)
        let surfaces = managedSurfaces + ownedSurfaces + externalSurfaces
        guard !surfaces.isEmpty else { return nil }

        let preferredWindowId = preferredWindowId(in: surfaces)
        let orderedSurfaces = surfaces.sorted { lhs, rhs in
            switch (lhs.windowId == preferredWindowId, rhs.windowId == preferredWindowId) {
            case (true, false):
                return false
            case (false, true):
                return true
            default:
                if lhs.sortPid != rhs.sortPid {
                    return lhs.sortPid < rhs.sortPid
                }
                return lhs.windowId < rhs.windowId
            }
        }

        var surfacesByBatchKey: [RaisableSurfaceBatchKey: [RaisableSurface]] = [:]
        var batchOrder: [RaisableSurfaceBatchKey] = []

        for surface in orderedSurfaces {
            if surfacesByBatchKey[surface.batchKey] == nil {
                batchOrder.append(surface.batchKey)
                surfacesByBatchKey[surface.batchKey] = []
            }
            surfacesByBatchKey[surface.batchKey, default: []].append(surface)
        }

        if let preferredBatchKey = orderedSurfaces.last?.batchKey,
           let focusIndex = batchOrder.firstIndex(of: preferredBatchKey)
        {
            let preferredBatchKey = batchOrder.remove(at: focusIndex)
            batchOrder.append(preferredBatchKey)
        }

        let batches = batchOrder.compactMap { surfacesByBatchKey[$0] }
        return FloatingWindowRaisePlan(batches: batches)
    }

    private func visibleExternalFloatingSurfaces(excludingWindowIds: Set<Int>) -> [RaisableSurface] {
        guard let controller else { return [] }

        var seenWindowIds = excludingWindowIds
        return visibleWindowInfoProvider().compactMap { windowInfo in
            let windowId = Int(windowInfo.id)
            guard seenWindowIds.insert(windowId).inserted else { return nil }
            guard !controller.isOwnedWindow(windowNumber: windowId) else { return nil }

            let pid = pid_t(windowInfo.pid)
            guard controller.workspaceManager.entry(forPid: pid, windowId: windowId) == nil else { return nil }
            guard let axRef = axWindowRefProvider(windowInfo.id, pid) else { return nil }

            let evaluation = controller.evaluateWindowDisposition(
                axRef: axRef,
                pid: pid,
                windowInfo: windowInfo
            )
            guard evaluation.decision.trackedMode == .floating || isWindowServerModalFloating(windowInfo) else {
                return nil
            }

            return .external(pid: pid, windowId: windowId, axRef: axRef)
        }
    }

    private func preferredWindowId(in surfaces: [RaisableSurface]) -> Int? {
        guard let controller else { return nil }

        let candidateWindowIds = Set(surfaces.map(\.windowId))
        let preferredOwnedWindowId = (NSApp?.orderedWindows ?? [])
            .map(\.windowNumber)
            .first(where: candidateWindowIds.contains)
            ?? [NSApp?.keyWindow, NSApp?.mainWindow]
            .compactMap { $0?.windowNumber }
            .first(where: candidateWindowIds.contains)
        if let preferredOwnedWindowId {
            return preferredOwnedWindowId
        }

        if let focusedToken = controller.focusedOrFrontmostWindowTokenForAutomation(
            preferFrontmostWhenNonManagedFocusActive: true
        ),
            candidateWindowIds.contains(focusedToken.windowId)
        {
            return focusedToken.windowId
        }

        guard let interactionWorkspaceId = controller.interactionWorkspace()?.id else { return nil }
        let lastFloatingFocusedToken = controller.workspaceManager.lastFloatingFocusedToken(
            in: interactionWorkspaceId
        )
        guard let lastFloatingFocusedToken,
              candidateWindowIds.contains(lastFloatingFocusedToken.windowId)
        else {
            return nil
        }
        return lastFloatingFocusedToken.windowId
    }

    private func isWindowServerModalFloating(_ windowInfo: WindowServerInfo) -> Bool {
        let isFloating = (windowInfo.tags & 0x2) != 0
        let isModal = (windowInfo.tags & 0x8000_0000) != 0
        return isFloating && isModal
    }

    private func front(surface: RaisableSurface) {
        guard let controller else { return }

        switch surface {
        case let .managed(entry):
            controller.performWindowFronting(
                pid: entry.pid,
                windowId: entry.windowId,
                axRef: entry.axRef
            )
        case let .external(pid, windowId, axRef):
            controller.performWindowFronting(
                pid: pid,
                windowId: windowId,
                axRef: axRef
            )
        case let .owned(window):
            frontOwnedWindow(window)
        }
    }

    @discardableResult
    func navigateToWindow(handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return false }
        return navigateToWindowInternal(token: handle.id, workspaceId: entry.workspaceId, source: .command)
    }

    @discardableResult
    func summonWindowRight(handle: WindowHandle) -> Bool {
        guard let controller,
              let currentWorkspace = controller.interactionWorkspace(),
              let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              focusedEntry.workspaceId == currentWorkspace.id
        else {
            return false
        }

        return summonWindowRight(
            handle: handle,
            anchorToken: focusedToken,
            anchorWorkspaceId: currentWorkspace.id
        )
    }

    @discardableResult
    func summonWindowRight(
        handle: WindowHandle,
        anchorToken: WindowToken?,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller else { return false }
        traceSummonRight(
            controller,
            "request handle=\(handle.id) anchorToken=\(SummonTraceFormatting.describe(anchorToken)) "
                + "anchorWorkspace=\(anchorWorkspaceId.uuidString) "
                + "interactionWorkspace=\(SummonTraceFormatting.describe(controller.interactionWorkspace()?.id))"
        )

        guard let targetEntry = controller.workspaceManager.entry(for: handle) else {
            traceSummonRight(controller, "reject handle=\(handle.id) reason=missingTargetEntry")
            return false
        }

        if let anchorToken {
            guard let anchorEntry = controller.workspaceManager.entry(for: anchorToken) else {
                traceSummonRight(
                    controller,
                    "reject handle=\(handle.id) reason=missingAnchorEntry anchor=\(anchorToken)"
                )
                return false
            }
            guard anchorEntry.workspaceId == anchorWorkspaceId else {
                traceSummonRight(
                    controller,
                    "reject handle=\(handle.id) reason=anchorWorkspaceMismatch "
                        + "anchorEntryWorkspace=\(anchorEntry.workspaceId.uuidString) "
                        + "anchorWorkspace=\(anchorWorkspaceId.uuidString)"
                )
                return false
            }
        }

        let token = handle.id
        guard token != anchorToken else {
            traceSummonRight(controller, "reject handle=\(handle.id) reason=targetIsAnchor")
            return false
        }

        let targetWorkspaceId = anchorWorkspaceId
        traceSummonRight(
            controller,
            "dispatch handle=\(handle.id) sourceWorkspace=\(targetEntry.workspaceId.uuidString) "
                + "targetWorkspace=\(targetWorkspaceId.uuidString) focusedToken=\(SummonTraceFormatting.describe(anchorToken))"
        )
        return summonWindowRightInNiri(
            token: token,
            sourceWorkspaceId: targetEntry.workspaceId,
            targetWorkspaceId: targetWorkspaceId,
            focusedToken: anchorToken
        )
    }

    @discardableResult
    func navigateToWindowInternal(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        source: NavigationSource = .unknown
    ) -> Bool {
        guard let controller else { return false }
        guard let engine = controller.niriEngine else { return false }

        let currentWsId = controller.interactionWorkspace()?.id

        if workspaceId != currentWsId {
            let wsName = controller.workspaceManager.descriptor(for: workspaceId)?.name ?? ""
            if let result = controller.workspaceManager.focusWorkspace(named: wsName) {
                _ = controller.workspaceManager.setInteractionMonitor(result.monitor.id)
                controller.syncMonitorsToNiriEngine()
            }
        }

        var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)
        let fromActiveColumnIndex = targetState.activeColumnIndex
        var targetColumnIndex: Int?
        if let niriWindow = engine.findNode(for: token) {
            targetState.selectedNodeId = niriWindow.id

            if let column = engine.findColumn(containing: niriWindow, in: workspaceId),
               let monitor = controller.workspaceManager.monitor(for: workspaceId)
            {
                targetColumnIndex = engine.columnIndex(of: column, in: workspaceId)
                engine.activateWindow(niriWindow.id)

                let gap = controller.gapSize(for: monitor)
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                engine.ensureSelectionVisible(
                    node: niriWindow,
                    in: workspaceId,
                    motion: .enabled,
                    state: &targetState,
                    workingFrame: workingFrame,
                    gaps: gap,
                    revealTrigger: .explicitNavigation
                )
                targetState.selectionProgress = 0
            }
        }

        // Diagnostic: record the navigation source and motion policy before applying
        // the patch, so a bar/window-click capture self-classifies. `.enabled` is the
        // motion requested by the `ensureSelectionVisible` call above.
        recordNavigationDiagnostic(
            reason: "navigate.window",
            workspaceId: workspaceId,
            source: source,
            targetToken: token,
            fromColumn: fromActiveColumnIndex,
            targetColumn: targetColumnIndex,
            requestedMotion: "enabled",
            directSelection: true
        )

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: targetState,
                rememberedFocusToken: token
            )
        )
        controller.layoutRefreshController
            .commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
                controller?.focusWindow(token)
            }
        return true
    }

    @discardableResult
    private func summonWindowRightInNiri(
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken?
    ) -> Bool {
        guard let controller else { return false }
        guard let engine = controller.niriEngine else {
            traceSummonRight(controller, "reject token=\(token) reason=niriDisabled")
            return false
        }

        let insertIndex: Int
        let targetColumnsBefore = engine.columns(in: targetWorkspaceId).count
        if let focusedToken {
            guard let focusedNode = engine.findNode(for: focusedToken) else {
                traceSummonRight(
                    controller,
                    "reject token=\(token) reason=missingFocusedNode focusedToken=\(focusedToken)"
                )
                return false
            }
            guard let focusedColumn = engine.findColumn(containing: focusedNode, in: targetWorkspaceId) else {
                traceSummonRight(
                    controller,
                    "reject token=\(token) reason=focusedColumnNotInTarget focusedToken=\(focusedToken) "
                        + "targetWorkspace=\(targetWorkspaceId.uuidString)"
                )
                return false
            }
            guard let focusedColumnIndex = engine.columnIndex(of: focusedColumn, in: targetWorkspaceId) else {
                traceSummonRight(
                    controller,
                    "reject token=\(token) reason=missingFocusedColumnIndex focusedToken=\(focusedToken) "
                        + "targetWorkspace=\(targetWorkspaceId.uuidString)"
                )
                return false
            }
            insertIndex = focusedColumnIndex + 1
            traceSummonRight(
                controller,
                "insertPlan token=\(token) mode=anchored focusedToken=\(focusedToken) "
                    + "focusedColumnIndex=\(focusedColumnIndex) insertIndex=\(insertIndex) "
                    + "targetColumnsBefore=\(targetColumnsBefore)"
            )
        } else {
            insertIndex = targetColumnsBefore
            traceSummonRight(
                controller,
                "insertPlan token=\(token) mode=append targetColumnsBefore=\(targetColumnsBefore) "
                    + "insertIndex=\(insertIndex) targetWorkspace=\(targetWorkspaceId.uuidString)"
            )
        }

        if sourceWorkspaceId == targetWorkspaceId {
            guard controller.niriLayoutHandler.insertWindowInNewColumn(
                handle: WindowHandle(id: token),
                insertIndex: insertIndex,
                in: targetWorkspaceId
            ) else {
                traceSummonRight(
                    controller,
                    "reject token=\(token) reason=sameWorkspaceInsertFailed insertIndex=\(insertIndex) "
                        + "targetWorkspace=\(targetWorkspaceId.uuidString)"
                )
                return false
            }
            traceSummonRight(
                controller,
                "commit token=\(token) path=sameWorkspace targetWorkspace=\(targetWorkspaceId.uuidString)"
            )
            commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId, startNiriScrollAnimation: true)
            return true
        }

        guard controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ) else {
            traceSummonRight(
                controller,
                "reject token=\(token) reason=moveWindowFailed sourceWorkspace=\(sourceWorkspaceId.uuidString) "
                    + "targetWorkspace=\(targetWorkspaceId.uuidString)"
            )
            return false
        }

        traceSummonRight(
            controller,
            "moved token=\(token) sourceWorkspace=\(sourceWorkspaceId.uuidString) "
                + "targetWorkspace=\(targetWorkspaceId.uuidString) columnsAfterMove=\(engine.columns(in: targetWorkspaceId).count)"
        )

        guard controller.niriLayoutHandler.insertWindowInNewColumn(
            handle: WindowHandle(id: token),
            insertIndex: insertIndex,
            in: targetWorkspaceId
        ) else {
            traceSummonRight(
                controller,
                "reject token=\(token) reason=crossWorkspaceInsertFailed insertIndex=\(insertIndex) "
                    + "targetWorkspace=\(targetWorkspaceId.uuidString)"
            )
            return false
        }
        // `moveWindow` already transferred the engine node, reassigned the workspace, and
        // prepared the destination viewport/session patch for the summoned token. Avoid
        // applying another session patch here (for example via `commitSummonedWindowFocus`)
        // because it would schedule an additional relayout/viewport target. Mirror
        // `commitNonFollowingWindowMove`, only swapping source-focus recovery for focusing
        // the summoned token.
        traceSummonRight(
            controller,
            "commit token=\(token) path=crossWorkspace targetWorkspace=\(targetWorkspaceId.uuidString)"
        )
        if let sourceMonitor = controller.workspaceManager.monitor(for: sourceWorkspaceId) {
            controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [sourceWorkspaceId, targetWorkspaceId],
            reason: .workspaceTransition
        ) { [weak controller] in
            controller?.focusWindow(token)
        }
        controller.layoutRefreshController.startScrollAnimation(for: targetWorkspaceId)
        return true
    }

    private func traceSummonRight(_ controller: WMController, _ message: String) {
        controller.diagnostics.recordRuntimeInsertionTrace("summonRight.\(message)")
    }

    private func commitSummonedWindowFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        rememberedFocusToken: WindowToken? = nil,
        startNiriScrollAnimation: Bool = false
    ) {
        guard let controller else { return }

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: rememberedFocusToken ?? token
            )
        )
        controller.layoutRefreshController.requestRefresh(reason: .layoutCommand) { [weak controller] in
            controller?.focusWindow(token)
        }
        if startNiriScrollAnimation {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    @discardableResult
    func focusWorkspaceFromBar(named name: String, suppressMouseWarp: Bool = false) -> Bool {
        guard let controller else { return false }
        if let currentWorkspace = controller.interactionWorkspace() {
            controller.workspaceNavigationHandler.saveNiriViewportState(for: currentWorkspace.id)
        }
        guard let result = controller.workspaceManager.focusWorkspace(named: name) else { return false }
        return focusWorkspaceFromBar(result: result, suppressMouseWarp: suppressMouseWarp)
    }

    @discardableResult
    func focusWorkspaceFromBar(id workspaceId: WorkspaceDescriptor.ID, suppressMouseWarp: Bool = false) -> Bool {
        guard let controller else { return false }
        if let currentWorkspace = controller.interactionWorkspace() {
            controller.workspaceNavigationHandler.saveNiriViewportState(for: currentWorkspace.id)
        }
        guard let result = controller.workspaceManager.focusWorkspace(id: workspaceId) else { return false }
        return focusWorkspaceFromBar(result: result, suppressMouseWarp: suppressMouseWarp)
    }

    @discardableResult
    private func focusWorkspaceFromBar(
        result: (workspace: WorkspaceDescriptor, monitor: Monitor),
        suppressMouseWarp: Bool
    ) -> Bool {
        guard let controller else { return false }

        let focusedToken = controller.resolveAndSetWorkspaceFocusToken(for: result.workspace.id)
        recordNavigationDiagnostic(
            reason: "navigate.workspace",
            workspaceId: result.workspace.id,
            source: .workspaceBarWorkspace,
            targetToken: focusedToken,
            fromColumn: nil,
            targetColumn: nil,
            requestedMotion: "policy",
            directSelection: true
        )
        if suppressMouseWarp, let focusedToken {
            controller.suppressMouseMoveToFocusedWindow(for: focusedToken)
        }
        controller.layoutRefreshController
            .commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
                if let focusedToken {
                    controller?.focusWindow(focusedToken)
                }
            }
        return true
    }

    @discardableResult
    func focusWindowFromBar(token: WindowToken, suppressMouseWarp: Bool = false) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: token) else { return false }
        if suppressMouseWarp {
            controller.suppressMouseMoveToFocusedWindow(for: token)
        }
        return navigateToWindowInternal(
            token: token,
            workspaceId: entry.workspaceId,
            source: .workspaceBarWindow
        )
    }

    // Emits a compact `navigate.*` diagnostic before a direct navigation applies its
    // viewport patch, so a capture can distinguish workspace-bar clicks from
    // command/hotkey navigation and see the motion policy that will drive the spring.
    private func recordNavigationDiagnostic(
        reason: String,
        workspaceId: WorkspaceDescriptor.ID,
        source: NavigationSource,
        targetToken: WindowToken?,
        fromColumn: Int?,
        targetColumn: Int?,
        requestedMotion: String,
        directSelection: Bool
    ) {
        guard let controller, controller.diagnostics.isRuntimeTraceCaptureActive else { return }
        let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name
            ?? workspaceId.uuidString
        let columnDelta = (fromColumn != nil && targetColumn != nil)
            ? String(targetColumn! - fromColumn!)
            : "nil"
        var details = [
            "source=\(source.rawValue)",
            "targetWorkspace=\(workspaceName)",
            "fromColumn=\(fromColumn.map(String.init) ?? "nil")",
            "targetColumn=\(targetColumn.map(String.init) ?? "nil")",
            "columnDelta=\(columnDelta)",
            "motionAnimationsEnabled=\(controller.motionPolicy.snapshot().animationsEnabled)",
            "requestedMotion=\(requestedMotion)",
            "directSelection=\(directSelection)"
        ]
        if let targetToken {
            details.insert("target=\(String(describing: targetToken))", at: 1)
        }
        controller.diagnostics.recordRuntimeViewportTrace(
            workspaceId: workspaceId,
            reason: reason,
            details: details
        )
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        guard let controller else { return [] }
        var appInfoMap: [String: RunningAppInfo] = [:]

        for entry in controller.workspaceManager.allEntries() {
            guard entry.layoutReason == .standard else { continue }

            let cachedInfo = controller.appInfoCache.info(for: entry.handle.pid)
            guard let bundleId = cachedInfo?.bundleId else { continue }

            if appInfoMap[bundleId] != nil { continue }

            let frame = (AXWindowService.framePreferFast(entry.axRef)) ?? .zero

            appInfoMap[bundleId] = RunningAppInfo(
                id: bundleId,
                bundleId: bundleId,
                appName: cachedInfo?.name ?? "Unknown",
                icon: cachedInfo?.icon,
                windowSize: frame.size
            )
        }

        return appInfoMap.values.sorted { $0.appName < $1.appName }
    }
}
