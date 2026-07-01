// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation
import NehirIPC
import os

struct RuntimeTraceCaptureStatus: Equatable {
    let isActive: Bool
    let startedAt: Date?
}

/// Owns WMController's diagnostics and trace surface: runtime-state dump and
/// reset, trace capture toggling and export, the background trace clip buffer,
/// per-category runtime trace recording, viewport-mutation audit gating, and
/// the window-decision debug snapshots consumed by the Diagnostics settings
/// tab, DebugBar, command palette, and `nehirctl` debug endpoints.
///
/// Behavior-inert by contract: everything here observes runtime state; the two
/// exceptions (`resetRuntimeState`, `restartAppClearingRuntimeState`) are the
/// explicit debug commands whose whole purpose is a clean-slate rebuild.
@MainActor
final class RuntimeDiagnosticsCoordinator {
    private static let logger = Logger(subsystem: "com.nehir", category: "runtime-debug")

    private struct RuntimeTraceCaptureSession {
        let startedAt: Date
        let startRuntimeStateDump: String
    }

    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    private var runtimeTraceCaptureSession: RuntimeTraceCaptureSession?
    private var runtimeViewportTraceRecords: [String] = []
    private var runtimeResizeTraceRecords: [String] = []
    private var runtimeInsertionTraceRecords: [String] = []
    private var runtimeMouseTraceRecords: [String] = []
    private var backgroundTraceBuffer = BackgroundTraceBuffer()
    private var backgroundTraceDrafts: [BackgroundTraceDraft.ID: BackgroundTraceDraft] = [:]
    private var backgroundTraceDraftOrder: [BackgroundTraceDraft.ID] = []

    var runtimeTraceCaptureStatus: RuntimeTraceCaptureStatus {
        RuntimeTraceCaptureStatus(
            isActive: runtimeTraceCaptureSession != nil,
            startedAt: runtimeTraceCaptureSession?.startedAt
        )
    }

    var isRuntimeTraceCaptureActive: Bool {
        runtimeTraceCaptureSession != nil
    }

    var isBackgroundTraceBufferEffectivelyEnabled: Bool {
        (controller?.settings.developerModeEnabled ?? false) && isRuntimeTraceCaptureActive
    }

    private func syncViewportMutationAuditFlag() {
        guard let controller else { return }
        // The per-mutation audit is the expensive part of the verbose path. It runs
        // only while trace capture is active AND verbosity is `.verbose`, so a
        // default (`.standard`) capture pays nothing for it.
        controller.workspaceManager.setViewportMutationAuditEnabled(
            isRuntimeTraceCaptureActive && controller.settings.viewportTraceVerbosity.includesMutationAudit
        )
    }

    /// Re-applies the viewport trace verbosity gates after the setting changes.
    /// Called from the Diagnostics picker / debug-bar cycle.
    func applyViewportTraceVerbosity() {
        syncViewportMutationAuditFlag()
        controller?.debugBarManager.update()
    }

    var backgroundTraceBufferStatus: BackgroundTraceBufferStatus {
        backgroundTraceBuffer.status(isEnabled: isBackgroundTraceBufferEffectivelyEnabled)
    }

    /// Test-only read access to captured mouse-focus traces. Trace capture must be active.
    func runtimeMouseTraceRecordsForTests() -> [String] {
        runtimeMouseTraceRecords
    }

    /// Test-only read access to captured viewport traces. Trace capture must be active.
    func runtimeViewportTraceRecordsForTests() -> [String] {
        runtimeViewportTraceRecords
    }

    func updateBackgroundTraceBufferConfiguration() {
        guard let controller else { return }
        backgroundTraceBuffer.configure(
            maxBytes: controller.settings.backgroundTraceMaxBytes,
            retentionSeconds: controller.settings.backgroundTraceRetentionSeconds
        )
        if !isRuntimeTraceCaptureActive {
            resetBackgroundTraceBuffer()
        }
        syncNiriResizeTraceSink()
        controller.debugBarManager.setup(controller: controller, settings: controller.settings)
    }

    // MARK: - Window-decision debug snapshots

    func recordWindowDecisionTrace(
        _ evaluation: WMController.WindowDecisionEvaluation,
        context: String,
        existingMode: TrackedWindowMode?
    ) {
        guard shouldTraceWindowDecision(evaluation, context: context) else { return }
        let windowServer = evaluation.facts.windowServer
        recordNiriCreateFocusTrace(
            .windowDecision(
                token: evaluation.token,
                context: context,
                existingMode: existingMode,
                disposition: String(describing: evaluation.decision.disposition),
                source: windowDecisionSourceDescription(evaluation.decision.source),
                outcome: evaluation.decision.admissionOutcome.rawValue,
                layout: evaluation.decision.layoutDecisionKind.rawValue,
                deferred: evaluation.decision.deferredReason?.rawValue,
                bundleId: evaluation.facts.ax.bundleId,
                titleLength: evaluation.facts.ax.title?.count,
                axRole: evaluation.facts.ax.role,
                axSubrole: evaluation.facts.ax.subrole,
                hasCloseButton: evaluation.facts.ax.hasCloseButton,
                hasFullscreenButton: evaluation.facts.ax.hasFullscreenButton,
                fullscreenButtonEnabled: evaluation.facts.ax.fullscreenButtonEnabled,
                hasZoomButton: evaluation.facts.ax.hasZoomButton,
                hasMinimizeButton: evaluation.facts.ax.hasMinimizeButton,
                appPolicy: evaluation.facts.ax.appPolicy,
                attributeDiagnostics: evaluation.facts.ax.attributeDiagnostics,
                windowLevel: windowServer?.level,
                windowTags: windowServer?.tags,
                windowAttributes: windowServer?.attributes,
                parentWindowId: windowServer?.parentId,
                windowFrame: windowServer?.frame
            )
        )
    }

    private func shouldTraceWindowDecision(
        _ evaluation: WMController.WindowDecisionEvaluation,
        context: String
    ) -> Bool {
        if context == "focused_admission" {
            return true
        }
        if evaluation.facts.ax.bundleId?.lowercased() == "com.mitchellh.ghostty" {
            return true
        }
        if evaluation.decision.trackedMode == nil {
            return true
        }
        if evaluation.facts.ax.subrole == (kAXDialogSubrole as String) {
            return true
        }
        if !evaluation.facts.ax.hasCloseButton,
           !evaluation.facts.ax.hasFullscreenButton,
           !evaluation.facts.ax.hasZoomButton,
           !evaluation.facts.ax.hasMinimizeButton,
           evaluation.facts.ax.subrole != (kAXStandardWindowSubrole as String)
        {
            return true
        }
        if evaluation.decision.disposition == .unmanaged {
            return true
        }
        if let level = evaluation.facts.windowServer?.level, level != 0 {
            return true
        }
        return false
    }

    private func windowDecisionSourceDescription(_ source: WindowDecisionSource) -> String {
        switch source {
        case .manualOverride:
            "manualOverride"
        case let .userRule(ruleId):
            "userRule(\(ruleId.uuidString))"
        case let .builtInRule(name):
            "builtInRule(\(name))"
        case .heuristic:
            "heuristic"
        }
    }

    func makeWindowDecisionDebugSnapshot(
        from evaluation: WMController.WindowDecisionEvaluation
    ) -> WindowDecisionDebugSnapshot {
        WindowDecisionDebugSnapshot(
            token: evaluation.token,
            appName: evaluation.facts.appName,
            bundleId: evaluation.facts.ax.bundleId,
            title: evaluation.facts.ax.title,
            axRole: evaluation.facts.ax.role,
            axSubrole: evaluation.facts.ax.subrole,
            appFullscreen: evaluation.appFullscreen,
            manualOverride: evaluation.manualOverride,
            disposition: evaluation.decision.disposition,
            source: evaluation.decision.source,
            layoutDecisionKind: evaluation.decision.layoutDecisionKind,
            deferredReason: evaluation.decision.deferredReason,
            admissionOutcome: evaluation.decision.admissionOutcome,
            workspaceName: evaluation.decision.workspaceName,
            minWidth: evaluation.decision.ruleEffects.minWidth,
            minHeight: evaluation.decision.ruleEffects.minHeight,
            matchedRuleId: evaluation.decision.ruleEffects.matchedRuleId,
            heuristicReasons: evaluation.decision.heuristicReasons,
            attributeFetchSucceeded: evaluation.facts.ax.attributeFetchSucceeded
        )
    }

    func windowDecisionDebugSnapshot(for token: WindowToken) -> WindowDecisionDebugSnapshot? {
        guard let controller else { return nil }
        let axRef = controller.workspaceManager.entry(for: token)?.axRef
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
        guard let axRef else { return nil }
        let evaluation = controller.evaluateWindowDisposition(axRef: axRef, pid: token.pid)
        return makeWindowDecisionDebugSnapshot(from: evaluation)
    }

    func focusedWindowDecisionDebugSnapshot() -> WindowDecisionDebugSnapshot? {
        guard let controller else { return nil }
        let token = controller.focusedOrFrontmostWindowTokenForAutomation()
        guard let token else { return nil }
        return windowDecisionDebugSnapshot(for: token)
    }

    func copyDebugDump(_ snapshot: WindowDecisionDebugSnapshot) {
        copyDebugTextToPasteboard(snapshot.formattedDump())
    }

    // MARK: - Runtime trace recording

    func syncNiriResizeTraceSink() {
        guard let engine = controller?.niriEngine else { return }
        if isRuntimeTraceCaptureActive {
            engine.resizeTraceSink = { [weak self] message in
                self?.recordRuntimeResizeTrace(message)
            }
        } else {
            engine.resizeTraceSink = nil
        }
    }

    func recordRuntimeResizeTrace(_ message: String) {
        let timestamp = Date()
        let line = timestamp.ISO8601Format() + " " + message
        if runtimeTraceCaptureSession != nil {
            runtimeResizeTraceRecords.append(line)
            if runtimeResizeTraceRecords.count > 400 {
                runtimeResizeTraceRecords.removeFirst(runtimeResizeTraceRecords.count - 400)
            }
        }
        appendBackgroundTrace(category: .resize, text: line, timestamp: timestamp)
    }

    func recordRuntimeMouseTrace(_ message: String) {
        let timestamp = Date()
        let line = timestamp.ISO8601Format() + " " + message
        if runtimeTraceCaptureSession != nil {
            runtimeMouseTraceRecords.append(line)
            if runtimeMouseTraceRecords.count > 400 {
                runtimeMouseTraceRecords.removeFirst(runtimeMouseTraceRecords.count - 400)
            }
        }
        appendBackgroundTrace(category: .mouse, text: line, timestamp: timestamp)
    }

    func recordRuntimeInsertionTrace(_ message: String) {
        let timestamp = Date()
        let line = timestamp.ISO8601Format() + " " + message
        if runtimeTraceCaptureSession != nil {
            runtimeInsertionTraceRecords.append(line)
            if runtimeInsertionTraceRecords.count > 400 {
                runtimeInsertionTraceRecords.removeFirst(runtimeInsertionTraceRecords.count - 400)
            }
        }
        appendBackgroundTrace(category: .insertion, text: line, timestamp: timestamp)
    }

    func recordRuntimeViewportTrace(
        workspaceId: WorkspaceDescriptor.ID,
        reason: String,
        details: [String] = []
    ) {
        guard isRuntimeTraceCaptureActive else { return }
        guard let controller, let engine = controller.niriEngine else { return }

        let gap = controller.workspaceManager.monitor(for: workspaceId).map { controller.gapSize(for: $0) }
            ?? CGFloat(controller.workspaceManager.gaps)
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name ?? workspaceId.uuidString
        let columns = engine.columns(in: workspaceId)
        let currentViewStart = columns.isEmpty ? nil : state.viewPosPixels(columns: columns, gap: gap)
        let targetViewStart = columns.isEmpty ? nil : state.targetViewPosPixels(columns: columns, gap: gap)
        let selectedNode = state.selectedNodeId.map(String.init(describing:)) ?? "nil"
        let preferredFocus = controller.workspaceManager.preferredWorkspaceFocusToken(in: workspaceId)
            .map(String.init(describing:)) ?? "nil"
        let confirmedFocus = controller.workspaceManager.confirmedManagedFocusToken
            .map(String.init(describing:)) ?? "nil"
        let currentViewStartText = currentViewStart.map { String(format: "%.1f", $0) } ?? "nil"
        let targetViewStartText = targetViewStart.map { String(format: "%.1f", $0) } ?? "nil"
        let verbosity = controller.settings.viewportTraceVerbosity
        let layoutDecisions = verbosity.includesLayoutDump
            ? niriLayoutDecisionLine(
                workspaceId: workspaceId,
                state: state,
                columns: columns,
                gap: gap
            )
            : "elided"
        let mutationAgeMs = state.lastViewportMutationTimestamp.map {
            max(0, (Date().timeIntervalSince1970 - $0) * 1000.0)
        }
        let mutationAgeText = mutationAgeMs.map { String(format: "%.1f", $0) } ?? "nil"
        let mutationBefore = state.lastViewportMutationBefore
        let mutationAfter = state.lastViewportMutationAfter
        let mutationBeforeCurrentOffsetText = mutationBefore.map { String(format: "%.1f", $0.currentOffset) } ?? "nil"
        let mutationBeforeTargetOffsetText = mutationBefore.map { String(format: "%.1f", $0.targetOffset) } ?? "nil"
        let mutationBeforeActiveColumnIndexText = mutationBefore.map { String($0.activeColumnIndex) } ?? "nil"
        let mutationAfterCurrentOffsetText = mutationAfter.map { String(format: "%.1f", $0.currentOffset) } ?? "nil"
        let mutationAfterTargetOffsetText = mutationAfter.map { String(format: "%.1f", $0.targetOffset) } ?? "nil"
        let mutationAfterActiveColumnIndexText = mutationAfter.map { String($0.activeColumnIndex) } ?? "nil"

        // The heavy `lastViewportMutation*` fields are only emitted on the
        // `.verbose` path, so a default (`.standard`) trace capture stays lean.
        let mutationTraceFields: [String] = verbosity.includesMutationAudit ? [
            "lastViewportMutation=\(state.lastViewportMutationReason ?? "nil")",
            "lastViewportMutationCaller=\(state.lastViewportMutationCaller ?? "nil")",
            "lastViewportMutationAgeMs=\(mutationAgeText)",
            "lastViewportMutationBeforeCurrentOffset=\(mutationBeforeCurrentOffsetText)",
            "lastViewportMutationBeforeTargetOffset=\(mutationBeforeTargetOffsetText)",
            "lastViewportMutationBeforeKind=\(mutationBefore?.offsetKind ?? "nil")",
            "lastViewportMutationBeforeActiveColumnIndex=\(mutationBeforeActiveColumnIndexText)",
            "lastViewportMutationAfterCurrentOffset=\(mutationAfterCurrentOffsetText)",
            "lastViewportMutationAfterTargetOffset=\(mutationAfterTargetOffsetText)",
            "lastViewportMutationAfterKind=\(mutationAfter?.offsetKind ?? "nil")",
            "lastViewportMutationAfterActiveColumnIndex=\(mutationAfterActiveColumnIndexText)"
        ] : []

        let timestamp = Date()
        let line = ([
            timestamp.ISO8601Format(),
            "workspace=\(workspaceName)",
            "id=\(workspaceId.uuidString)",
            "reason=\(reason)"
        ] + details + [
            "columns=\(columns.count)",
            "activeColumnIndex=\(state.activeColumnIndex)",
            String(format: "currentOffset=%.1f", state.viewOffsetPixels.current()),
            String(format: "targetOffset=%.1f", state.viewOffsetPixels.target()),
            "currentViewStart=\(currentViewStartText)",
            "targetViewStart=\(targetViewStartText)",
            "gesture=\(state.viewOffsetPixels.isGesture)",
            "animating=\(state.viewOffsetPixels.isAnimating)",
            "preserveUnsnapped=\(state.preservesUnsnappedGestureOffset)",
            "selectedNode=\(selectedNode)",
            "preferredFocus=\(preferredFocus)",
            "confirmedFocus=\(confirmedFocus)",
            "resizeCommandSeq=\(engine.resizeCommandGeneration)",
            "layout=\(layoutDecisions)"
        ] + mutationTraceFields)
            .joined(separator: " ")

        if runtimeTraceCaptureSession != nil {
            runtimeViewportTraceRecords.append(line)
            if runtimeViewportTraceRecords.count > 400 {
                runtimeViewportTraceRecords.removeFirst(runtimeViewportTraceRecords.count - 400)
            }
        }
        appendBackgroundTrace(category: .viewport, text: line, timestamp: timestamp)
    }

    func recordNiriCreateFocusTrace(_ kind: NiriCreateFocusTraceEvent.Kind) {
        controller?.axEventHandler.recordNiriCreateFocusTrace(.init(kind: kind))
    }

    private func appendBackgroundTrace(
        category: BackgroundTraceCategory,
        text: String,
        timestamp: Date = Date()
    ) {
        guard isBackgroundTraceBufferEffectivelyEnabled, let controller else { return }
        backgroundTraceBuffer.configure(
            maxBytes: controller.settings.backgroundTraceMaxBytes,
            retentionSeconds: controller.settings.backgroundTraceRetentionSeconds,
            now: timestamp
        )
        backgroundTraceBuffer.append(category: category, text: text, timestamp: timestamp)
    }

    func resetBackgroundTraceBuffer() {
        backgroundTraceBuffer.clear()
        backgroundTraceDrafts.removeAll(keepingCapacity: true)
        backgroundTraceDraftOrder.removeAll(keepingCapacity: true)
        controller?.debugBarManager.update()
    }

    // MARK: - Niri layout debug dumps

    private func niriLayoutDecisionLine(
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        columns: [NiriContainer],
        gap: CGFloat
    ) -> String {
        guard let controller, controller.niriEngine != nil else { return "niri-disabled" }
        guard !columns.isEmpty else { return "no-columns" }

        var currentState = state
        currentState.viewOffsetPixels = .static(state.viewOffsetPixels.current())
        let currentPlan = niriLayoutPlanSnapshot(workspaceId: workspaceId, state: currentState)

        var targetState = state
        targetState.viewOffsetPixels = .static(state.viewOffsetPixels.target())
        let targetPlan = niriLayoutPlanSnapshot(workspaceId: workspaceId, state: targetState)

        return columns.enumerated().map { colIdx, column in
            let windows = column.windowNodes.map { window -> String in
                let token = window.token
                let current = currentPlan.frames[token].map(compactRect) ?? currentPlan.hidden[token]
                    .map { "hide:\($0)" } ?? "nil"
                let target = targetPlan.frames[token].map(compactRect) ?? targetPlan.hidden[token]
                    .map { "hide:\($0)" } ?? "nil"
                let last = controller.axManager.lastAppliedFrame(for: token.windowId).map(compactRect) ?? "nil"
                let entry = controller.workspaceManager.entry(for: token)
                let live = entry.flatMap { try? AXWindowService.frame($0.axRef) }.map(compactRect) ?? "nil"
                let replacement = entry?.managedReplacementMetadata?.frame.map(compactRect) ?? "nil"
                let observed = entry?.observedState.frame.map(compactRect) ?? "nil"
                let hidden = controller.workspaceManager.hiddenState(for: token)?.offscreenSide
                    .map { "hidden:\($0)" } ?? "hidden:nil"
                let selected = state.selectedNodeId == window.id ? ":selected" : ""
                return "w\(token.windowId)\(selected){cur=\(current),target=\(target),last=\(last),live=\(live),replacement=\(replacement),observed=\(observed),\(hidden)}"
            }.joined(separator: ",")
            return "c\(colIdx)[\(niriColumnSizingDebug(column, index: colIdx, columns: columns, gap: gap))]{\(windows)}"
        }.joined(separator: "|")
    }

    private func niriLayoutPlanSnapshot(
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState
    ) -> (frames: [WindowToken: CGRect], hidden: [WindowToken: HideSide]) {
        guard let controller,
              let engine = controller.niriEngine,
              let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
              let monitor = controller.workspaceManager.monitor(byId: monitorId)
        else {
            return ([:], [:])
        }

        let gap = controller.gapSize(for: monitor)
        let gaps = LayoutGaps(
            horizontal: gap,
            vertical: gap,
            outer: controller.outerGaps(for: monitor)
        )
        let area = WorkingAreaContext(
            workingFrame: controller.insetWorkingFrame(for: monitor),
            viewFrame: monitor.frame,
            scale: NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?
                .backingScaleFactor ?? 2.0
        )
        let plan = engine.calculateCombinedLayoutUsingPools(
            in: workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area
        )
        return (frames: plan.frames, hidden: plan.hiddenHandles)
    }

    private func columnXForDebug(_ index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        guard index > 0 else { return 0 }
        return columns.prefix(index).reduce(CGFloat(0)) { $0 + $1.cachedWidth + gap }
    }

    private func niriWidthSpecDebug(_ spec: ProportionalSize) -> String {
        switch spec {
        case let .proportion(proportion):
            String(format: "prop:%.4f", proportion)
        case let .fixed(width):
            String(format: "fix:%.1f", width)
        }
    }

    private func niriColumnSizingDebug(
        _ column: NiriContainer,
        index: Int,
        columns: [NiriContainer],
        gap: CGFloat
    ) -> String {
        let now = (controller?.animationClock ?? AnimationClock()).now()
        let animationText: String
        if let animation = column.widthAnimation {
            animationText = String(
                format: "anim=%.1f->%.1f vel=%.1f",
                animation.value(at: now),
                animation.target,
                animation.velocity(at: now)
            )
        } else {
            animationText = "anim=nil"
        }
        return [
            String(format: "x=%.1f", columnXForDebug(index, columns: columns, gap: gap)),
            String(format: "cached=%.1f", column.cachedWidth),
            column.loneWindowLayoutWidthOverride.map { String(format: "override=%.1f", $0) } ?? "override=nil",
            "spec=\(niriWidthSpecDebug(column.width))",
            "target=\(column.targetWidth.map { String(format: "%.1f", $0) } ?? "nil")",
            "preset=\(column.presetWidthIdx.map(String.init) ?? "nil")",
            "full=\(column.isFullWidth)",
            "manual=\(column.hasManualSingleWindowWidthOverride)",
            animationText
        ].joined(separator: ",")
    }

    private func compactRect(_ rect: CGRect) -> String {
        String(
            format: "%.0f,%.0f,%.0f,%.0f",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
        )
    }

    private func niriLayoutDecisionDebugDump() -> String {
        guard let controller, let engine = controller.niriEngine else { return "niri disabled" }
        let workspaceIds = controller.workspaceManager.workspaceIdsForDebug()
        guard !workspaceIds.isEmpty else { return "no-workspaces" }

        return workspaceIds.map { workspaceId in
            let state = controller.workspaceManager.niriViewportState(for: workspaceId)
            let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name
                ?? workspaceId.uuidString
            let columns = engine.columns(in: workspaceId)
            let gap = controller.workspaceManager.monitor(for: workspaceId).map { controller.gapSize(for: $0) }
                ?? CGFloat(controller.workspaceManager.gaps)
            return "workspace=\(workspaceName) id=\(workspaceId.uuidString) \(niriLayoutDecisionLine(workspaceId: workspaceId, state: state, columns: columns, gap: gap))"
        }.joined(separator: "\n")
    }

    private func niriViewportDebugDump() -> String {
        guard let controller, let engine = controller.niriEngine else { return "niri disabled" }

        let workspaceIds = controller.workspaceManager.workspaceIdsForDebug()
        guard !workspaceIds.isEmpty else { return "no-workspaces" }

        return workspaceIds.map { workspaceId in
            let state = controller.workspaceManager.niriViewportState(for: workspaceId)
            let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name
                ?? workspaceId.uuidString
            let columns = engine.columns(in: workspaceId)
            let gap = controller.workspaceManager.monitor(for: workspaceId).map { controller.gapSize(for: $0) }
                ?? CGFloat(controller.workspaceManager.gaps)
            let currentViewStart = columns.isEmpty ? nil : state.viewPosPixels(columns: columns, gap: gap)
            let targetViewStart = columns.isEmpty ? nil : state.targetViewPosPixels(columns: columns, gap: gap)
            let selectedNode = state.selectedNodeId.map(String.init(describing:)) ?? "nil"
            let preferredFocus = controller.workspaceManager.preferredWorkspaceFocusToken(in: workspaceId)
                .map(String.init(describing:)) ?? "nil"
            let visible = controller.workspaceManager.visibleWorkspaceIds().contains(workspaceId)
            let currentOffset = String(format: "%.1f", state.viewOffsetPixels.current())
            let targetOffset = String(format: "%.1f", state.viewOffsetPixels.target())
            let currentViewStartText = currentViewStart.map { String(format: "%.1f", $0) } ?? "nil"
            let targetViewStartText = targetViewStart.map { String(format: "%.1f", $0) } ?? "nil"
            let restoreText = state.viewOffsetToRestore.map { String(format: "%.1f", $0) } ?? "nil"
            let activatePrevText = state.activatePrevColumnOnRemoval.map { String(format: "%.1f", $0) } ?? "nil"

            return [
                "workspace=\(workspaceName)",
                "id=\(workspaceId.uuidString)",
                "visible=\(visible)",
                "columns=\(columns.count)",
                "activeColumnIndex=\(state.activeColumnIndex)",
                "currentOffset=\(currentOffset)",
                "targetOffset=\(targetOffset)",
                "currentViewStart=\(currentViewStartText)",
                "targetViewStart=\(targetViewStartText)",
                "gesture=\(state.viewOffsetPixels.isGesture)",
                "animating=\(state.viewOffsetPixels.isAnimating)",
                "selectedNode=\(selectedNode)",
                "preferredFocus=\(preferredFocus)",
                "restore=\(restoreText)",
                "activatePrev=\(activatePrevText)"
            ]
            .joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    private func focusTargetDebugDump() -> String {
        guard let controller else { return "controller unavailable" }
        let interactionWorkspaceId = controller.interactionWorkspace()?.id
        let selectedToken: WindowToken? = if let workspaceId = interactionWorkspaceId,
                                             let engine = controller.niriEngine,
                                             let selectedNodeId = controller.workspaceManager
                                             .niriViewportState(for: workspaceId).selectedNodeId,
                                             let selectedWindow = engine.findNode(by: selectedNodeId) as? NiriWindow
        {
            selectedWindow.token
        } else {
            nil
        }
        let borderToken = controller.currentBorderTarget()?.token
        let commandTarget = controller.managedCommandTarget()
        return [
            "interactionWorkspace=\(interactionWorkspaceId.map { $0.uuidString } ?? "nil")",
            "wmCommandTarget=\(commandTarget.map { String(describing: $0.token) } ?? "nil")",
            "wmCommandTargetSource=\(commandTarget.map { String(describing: $0.source) } ?? "nil")",
            "layoutSelection=\(selectedToken.map(String.init(describing:)) ?? "nil")",
            "observedManagedFocus=\(controller.workspaceManager.confirmedManagedFocusToken.map(String.init(describing:)) ?? "nil")",
            "focusRequest=\(controller.workspaceManager.activeFocusRequestToken.map(String.init(describing:)) ?? "nil")",
            "borderTarget=\(borderToken.map(String.init(describing:)) ?? "nil")",
            "interactionMonitor=\(controller.workspaceManager.interactionMonitorId.map(String.init(describing:)) ?? "nil")",
            "nonManaged=\(controller.workspaceManager.isNonManagedFocusActive)"
        ].joined(separator: " ")
    }

    private func visibleUnmanagedWindowServerDebugDump() -> String {
        guard let controller else { return "controller unavailable" }
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return "unavailable"
        }

        let trackedWindowIds = Set(controller.workspaceManager.trackedWindowIdsForDebug())
        let visibleCandidates = windows.compactMap { info -> String? in
            let windowId = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            guard let windowId, !trackedWindowIds.contains(Int(windowId)) else { return nil }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { return nil }

            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard isOnscreen else { return nil }

            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 80,
                  height >= 80
            else { return nil }

            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? "nil"
            let title = info[kCGWindowName as String] as? String ?? "nil"
            let runningApp = NSRunningApplication(processIdentifier: pid)
            let bundleId = runningApp?.bundleIdentifier ?? "nil"
            let activationPolicy = runningApp.map { String(describing: $0.activationPolicy) } ?? "nil"
            let axSummary = visibleUnmanagedWindowAXDebugSummary(pid: pid, windowId: windowId)
            return "windowId=\(windowId) pid=\(pid) owner=\(ownerName) bundleId=\(bundleId) title=\(title) frame={{\(x), \(y)}, {\(width), \(height)}} activationPolicy=\(activationPolicy) \(axSummary)"
        }

        return visibleCandidates.isEmpty ? "none" : visibleCandidates.joined(separator: "\n")
    }

    private func visibleUnmanagedWindowAXDebugSummary(pid: pid_t, windowId: UInt32) -> String {
        let appElement = AXUIElementCreateApplication(pid)

        var attributeNames: CFArray?
        let namesResult = AXUIElementCopyAttributeNames(appElement, &attributeNames)

        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )

        let axWindowIds: [Int]
        if windowsResult == .success, let elements = windowsValue as? [AXUIElement] {
            axWindowIds = elements.compactMap { element in
                var axWindowId: CGWindowID = 0
                guard _AXUIElementGetWindow(element, &axWindowId) == .success else { return nil }
                return Int(axWindowId)
            }
        } else {
            axWindowIds = []
        }

        let axContainsWindow = axWindowIds.contains(Int(windowId))
        let axAttributeCount = (attributeNames as? [Any])?.count ?? 0
        return "axAppAttributeNamesResult=\(namesResult.rawValue) axAppAttributeCount=\(axAttributeCount) axWindowsResult=\(windowsResult.rawValue) axWindowsCount=\(axWindowIds.count) axContainsWindow=\(axContainsWindow)"
    }

    // MARK: - Runtime state dump / reset / restart

    func runtimeStateDebugDump(
        traceLimit: Int = 50,
        traceCaptureStatusOverride: RuntimeTraceCaptureStatus? = nil
    ) -> String {
        guard let controller else { return "controller unavailable" }
        let axSnapshot = controller.axManager.windowStateDebugSnapshot()
        let refreshSnapshot = controller.layoutRefreshController.refreshDebugSnapshot()
        let mouseTapSnapshot = controller.mouseEventHandler.mouseTapDebugSnapshot()
        let mouseWarpSnapshot = controller.mouseWarpHandler.mouseWarpDebugSnapshot()
        let axEventSnapshot = controller.axEventHandler.debugCounters
        let cgsSnapshot = CGSEventObserver.shared.cgsDebugSnapshot()
        let traceCaptureStatus = traceCaptureStatusOverride ?? runtimeTraceCaptureStatus
        let backgroundTraceEffectiveEnabled = controller.settings.developerModeEnabled && traceCaptureStatus.isActive

        var lines: [String] = [
            "WMController runtime state",
            "enabled=\(controller.isEnabled) desiredEnabled=\(controller.desiredEnabled) hotkeysEnabled=\(controller.hotkeysEnabled) desiredHotkeysEnabled=\(controller.desiredHotkeysEnabled)",
            "accessibilityGranted=\(controller.accessibilityPermissionGranted) lockScreenActive=\(controller.isLockScreenActive) overviewOpen=\(controller.isOverviewOpen()) startedServices=\(controller.hasStartedServices)",
            "focusFollowsMouse=\(controller.focusFollowsMouseEnabled) moveMouseToFocusedWindow=\(controller.moveMouseToFocusedWindowEnabled) mouseWarpEnabled=\(controller.settings.mouseWarpEnabled) mouseWarpPolicyEnabled=\(controller.isMouseWarpPolicyEnabled)",
            "displaySpacesMode=\(SkyLight.shared.displaySpacesMode().rawValue)",
            "isTransferringWindow=\(controller.isTransferringWindow) hiddenAppPIDs=\(controller.hiddenAppPIDs.count) workspaceBarHiddenMonitors=\(controller.hiddenWorkspaceBarMonitorIds.count)",
            "runtimeTraceCaptureActive=\(traceCaptureStatus.isActive) runtimeTraceStartedAt=\(traceCaptureStatus.startedAt?.ISO8601Format() ?? "nil") viewportTraceRecords=\(runtimeViewportTraceRecords.count) resizeTraceRecords=\(runtimeResizeTraceRecords.count) insertionTraceRecords=\(runtimeInsertionTraceRecords.count) mouseTraceRecords=\(runtimeMouseTraceRecords.count) backgroundTraceEnabled=\(backgroundTraceEffectiveEnabled) backgroundTraceEvents=\(backgroundTraceBufferStatus.eventCount) backgroundTraceBytes=\(backgroundTraceBufferStatus.estimatedBytes) backgroundTraceMaxBytes=\(backgroundTraceBufferStatus.maxBytes) backgroundTraceRetentionSeconds=\(String(format: "%.0f", backgroundTraceBufferStatus.retentionSeconds))",
            "workspaceBarRefreshDebugState requestCount=\(controller.workspaceBarRefreshDebugState.requestCount) scheduledCount=\(controller.workspaceBarRefreshDebugState.scheduledCount) executionCount=\(controller.workspaceBarRefreshDebugState.executionCount) isQueued=\(controller.workspaceBarRefreshDebugState.isQueued)",
            "-- Focus Targets --",
            focusTargetDebugDump(),
            "-- Monitor Topology --",
            controller.workspaceManager.monitorTopologyDebugDump(),
            "-- SpaceTopology --",
            controller.layoutRefreshController.spaceTopologyDebugDump(),
            "-- WorkspaceManager --",
            controller.workspaceManager.runtimeStateDebugSummary(),
            "-- AXManager --",
            "lastAppliedFrames=\(axSnapshot.lastAppliedFrameCount) pendingFrameWrites=\(axSnapshot.pendingFrameWriteCount) recentFailures=\(axSnapshot.recentFrameWriteFailureCount) retryBudget=\(axSnapshot.retryBudgetCount) forceApply=\(axSnapshot.forceApplyWindowIdCount) pendingObservers=\(axSnapshot.pendingFrameObserverCount) observerRequests=\(axSnapshot.observerRequestIdCount) rekeyedWindowIds=\(axSnapshot.rekeyedWindowIdCount) inactiveWorkspaceWindowIds=\(axSnapshot.inactiveWorkspaceWindowIdCount)",
            "-- Managed Windows --",
            controller.workspaceManager.runtimeWindowDebugDump(),
            "-- Visible Unmanaged WindowServer Windows --",
            visibleUnmanagedWindowServerDebugDump(),
            "-- AX Window State --",
            controller.axManager.windowStateDebugDump(
                windowIds: controller.workspaceManager.trackedWindowIdsForDebug()
            ),
            "-- Workspace-Inactive Visible Drift Scan --",
            controller.layoutRefreshController.workspaceInactiveVisibleDriftDebugDump(),
            "-- Niri Viewports --",
            niriViewportDebugDump(),
            "-- Niri Layout Decisions --",
            niriLayoutDecisionDebugDump(),
            "-- AXEventHandler --",
            "geometryRelayoutRequests=\(axEventSnapshot.geometryRelayoutRequests) scopedGeometryRelayoutRequests=\(axEventSnapshot.scopedGeometryRelayoutRequests) suppressedDuringGesture=\(axEventSnapshot.geometryRelayoutsSuppressedDuringGesture) suppressedForOwnFrameWrites=\(axEventSnapshot.geometryRelayoutsSuppressedForOwnFrameWrites)",
            "-- Create Placement Contexts --",
            controller.axEventHandler.createPlacementContextDebugDump(),
            "-- LayoutRefreshController --",
            "fullRescan=\(refreshSnapshot.fullRescanExecutions) relayout=\(refreshSnapshot.relayoutExecutions) immediateRelayout=\(refreshSnapshot.immediateRelayoutExecutions) visibility=\(refreshSnapshot.visibilityExecutions) windowRemoval=\(refreshSnapshot.windowRemovalExecutions)",
            "requestedByReason=\(String(describing: refreshSnapshot.requestedByReason))",
            "executedByReason=\(String(describing: refreshSnapshot.executedByReason))",
            "lastAffectedWorkspaceIdsByReason=\(String(describing: refreshSnapshot.lastAffectedWorkspaceIdsByReason))",
            "-- MouseEventHandler --",
            String(describing: mouseTapSnapshot),
            "-- MouseWarpHandler --",
            String(describing: mouseWarpSnapshot),
            "-- CGSEventObserver --",
            String(describing: cgsSnapshot),
            "-- Workspace Bar Floating Projection Trace --",
            controller.workspaceManager.floatingBarProjectionTraceDump(),
            "-- Workspace Bar Frame Trace --",
            controller.workspaceBarManager.runtimeFrameTraceDebugDump(),
            "-- Workspace Bar --",
            controller.workspaceBarManager.runtimeStateDebugDump(
                monitors: controller.workspaceManager.monitors,
                resolvedProvider: { [weak controller] monitor in
                    controller?.settings.resolvedBarSettings(for: monitor) ?? ResolvedBarSettings.defaults
                },
                visibilityProvider: { [weak controller] monitor, resolved in
                    controller?.isWorkspaceBarVisible(on: monitor, resolved: resolved) ?? false
                }
            ),
            "-- Reconcile Snapshot --",
            controller.workspaceManager.reconcileSnapshotDump()
        ]
        if traceLimit > 0 {
            lines.append(contentsOf: [
                "-- Reconcile Trace --",
                controller.workspaceManager.reconcileTraceDump(limit: traceLimit)
            ])
        }

        return lines.joined(separator: "\n")
    }

    func dumpRuntimeState(traceLimit: Int = 50) {
        let dump = runtimeStateDebugDump(traceLimit: traceLimit)
        copyDebugTextToPasteboard(dump)
        Self.logger.info("\(dump, privacy: .private)")
    }

    func resetRuntimeState() {
        guard let controller else { return }
        if runtimeTraceCaptureSession != nil {
            runtimeTraceCaptureSession = nil
            runtimeViewportTraceRecords.removeAll(keepingCapacity: true)
            runtimeResizeTraceRecords.removeAll(keepingCapacity: true)
            runtimeInsertionTraceRecords.removeAll(keepingCapacity: true)
            runtimeMouseTraceRecords.removeAll(keepingCapacity: true)
            backgroundTraceBuffer.clear()
            backgroundTraceDrafts.removeAll(keepingCapacity: true)
            backgroundTraceDraftOrder.removeAll(keepingCapacity: true)
            syncNiriResizeTraceSink()
            syncViewportMutationAuditFlag()
            controller.workspaceBarManager.update()
            controller.debugBarManager.update()
        }
        controller.mouseEventHandler.handleInputSuppressionBegan()
        controller.mouseEventHandler.resetDebugStateForTests()
        controller.mouseWarpHandler.resetDebugStateForTests()
        controller.axEventHandler.resetDebugStateForTests()
        CGSEventObserver.shared.resetDebugStateForTests()
        controller.axManager.resetRuntimeState()
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.resetDebugState()
        controller.focusBridge.reset()
        controller.resetWorkspaceBarRefreshDebugStateForTests()
        controller.tabbedOverlayManager.removeAll()
        controller.nativeFullscreenPlaceholderManager.removeAll()
        controller.focusBorderController.cleanup()
        controller.workspaceManager.resetRuntimeStateForDebug()
        controller.clearExplicitWorkspaceMoveIntents()
        controller.hiddenAppPIDs.removeAll()
        controller.isTransferringWindow = false

        if controller.niriEngine != nil {
            controller.enableNiriLayout(revealPartial: controller.settings.revealPartial)
            controller.updateNiriConfig(
                balancedColumnCount: controller.settings.niriBalancedColumnCount,
                infiniteLoop: controller.settings.niriInfiniteLoop,
                revealPartial: controller.settings.revealPartial,
                loneWindowPolicy: controller.settings.loneWindowPolicy,
                columnWidthPresets: controller.settings.niriColumnWidthPresets,
                defaultColumnWidth: controller.settings.niriDefaultColumnWidth
            )
        }

        controller.layoutRefreshController.requestRefresh(reason: .startup)
    }

    func restartAppClearingRuntimeState(enableTracing: Bool = false) {
        guard let controller else { return }
        resetRuntimeState()
        controller.workspaceManager.prepareForRestartClearingRuntimeState()

        let extraArguments = enableTracing ? [WMController.traceLaunchArgument] : []
        guard controller.relaunchCurrentApplication(extraArguments: extraArguments) else {
            Self.logger.error("Failed to schedule relaunch after runtime reset")
            return
        }

        NSApp.terminate(nil)
    }

    // MARK: - Trace capture sessions and background clips

    @discardableResult
    func toggleRuntimeTraceCapture(desiredState: IPCTraceDesiredState? = nil) -> ExternalCommandResult {
        switch desiredState {
        case .active:
            return isRuntimeTraceCaptureActive ? .executed : startRuntimeTraceCapture()
        case .inactive:
            return isRuntimeTraceCaptureActive ? stopRuntimeTraceCapture() : .executed
        case nil:
            return isRuntimeTraceCaptureActive ? stopRuntimeTraceCapture() : startRuntimeTraceCapture()
        }
    }

    @discardableResult
    func captureRecentBackgroundTrace(
        marker: Date = Date(),
        lookback: TimeInterval = 120,
        tail: TimeInterval = 0,
        note: String? = nil
    ) -> ExternalCommandResult {
        guard let draft = makeBackgroundTraceDraft(marker: marker) else {
            Self.logger.error("Capture recent trace requested with no background trace draft available")
            return controller?.settings.developerModeEnabled == true ? .invalidState : .requiresDeveloperMode
        }

        do {
            _ = try exportBackgroundTraceClip(
                draftID: draft.id,
                marker: marker,
                lookback: lookback,
                tail: tail,
                note: note
            )
            return .executed
        } catch {
            Self.logger
                .error("Failed to write background trace clip: \(error.localizedDescription, privacy: .public)")
            return .internalError
        }
    }

    func makeBackgroundTraceDraft(marker: Date = Date()) -> BackgroundTraceDraft? {
        guard isBackgroundTraceBufferEffectivelyEnabled else { return nil }
        cleanupBackgroundTraceDrafts(now: marker)
        guard let draft = backgroundTraceBuffer.makeDraft(now: marker) else { return nil }
        backgroundTraceDrafts[draft.id] = draft
        backgroundTraceDraftOrder.append(draft.id)
        cleanupBackgroundTraceDrafts(now: marker)
        return draft
    }

    @discardableResult
    func exportBackgroundTraceClip(
        draftID: BackgroundTraceDraft.ID,
        marker: Date,
        lookback: TimeInterval,
        tail: TimeInterval,
        note: String?
    ) throws -> URL {
        guard let draft = backgroundTraceDrafts[draftID] else {
            throw NSError(
                domain: "NehirBackgroundTrace",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Background trace draft is no longer available."]
            )
        }
        let endedAt = Date()
        let clip = BackgroundTraceBuffer.selectClip(from: draft, marker: marker, lookback: lookback, tail: tail)
        let fileURL = backgroundTraceClipFileURL(
            startedAt: clip.selectedStart,
            endedAt: clip.selectedEnd,
            exportedAt: endedAt
        )
        let runtimeStateDump = runtimeStateDebugDump(traceLimit: 0)
        let eventDump = clip.events.isEmpty
            ? "background trace clip empty"
            : clip.events.map { event in
                "[\(event.category.rawValue)] \(event.text)"
            }.joined(separator: "\n")
        let categoryCounts = BackgroundTraceCategory.allCases.map { category in
            "\(category.rawValue)=\(clip.categoryCounts[category] ?? 0)"
        }.joined(separator: " ")
        let noteLine = (note?.isEmpty == false) ? note! : ""
        let retainedRange = "\(draft.retainedStart?.ISO8601Format() ?? "nil")..\(draft.retainedEnd?.ISO8601Format() ?? "nil")"
        let selectedRange = "\(clip.selectedStart.ISO8601Format())..\(clip.selectedEnd.ISO8601Format())"
        let body = [
            "# Nehir runtime trace clip",
            "captureKind=background-clip",
            "backgroundBufferEnabled=\(isBackgroundTraceBufferEffectivelyEnabled)",
            "retainedRange=\(retainedRange)",
            "selectedRange=\(selectedRange)",
            "bugMarker=\(marker.ISO8601Format())",
            String(format: "requestedLookback=%.0fs", clip.requestedLookback),
            String(format: "requestedTail=%.0fs", clip.requestedTail),
            "truncatedByTimeRetention=\(clip.truncatedByTimeRetention)",
            "truncatedByByteCap=\(clip.truncatedByByteCap)",
            String(
                format: "backgroundRetentionSeconds=%.0f",
                controller?.settings.backgroundTraceRetentionSeconds ?? 0
            ),
            "backgroundMaxBytes=\(controller?.settings.backgroundTraceMaxBytes ?? 0)",
            "eventCount=\(clip.events.count)",
            "estimatedBytes=\(clip.estimatedBytes)",
            "categoryCounts=\(categoryCounts)",
            "userNote=\(noteLine)",
            "exportedAt=\(endedAt.ISO8601Format())",
            "",
            "## Runtime state at export",
            runtimeStateDump,
            "",
            "## Background trace events",
            eventDump,
            ""
        ].joined(separator: "\n")

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
        copyTraceExportToPasteboard(fileURL)
        Self.logger.info("Wrote background trace clip to \(fileURL.path, privacy: .private)")
        return fileURL
    }

    private func cleanupBackgroundTraceDrafts(now: Date = Date()) {
        let expiration: TimeInterval = 30 * 60
        backgroundTraceDraftOrder.removeAll { id in
            guard let draft = backgroundTraceDrafts[id] else { return true }
            if now.timeIntervalSince(draft.createdAt) > expiration {
                backgroundTraceDrafts[id] = nil
                return true
            }
            return false
        }
        while backgroundTraceDraftOrder.count > 2 {
            let id = backgroundTraceDraftOrder.removeFirst()
            backgroundTraceDrafts[id] = nil
        }
    }

    @discardableResult
    private func startRuntimeTraceCapture() -> ExternalCommandResult {
        guard runtimeTraceCaptureSession == nil else {
            Self.logger.error("Start runtime trace capture requested while a capture is already active")
            return .invalidState
        }
        guard let controller else { return .internalError }

        runtimeViewportTraceRecords.removeAll(keepingCapacity: true)
        runtimeResizeTraceRecords.removeAll(keepingCapacity: true)
        runtimeInsertionTraceRecords.removeAll(keepingCapacity: true)
        runtimeMouseTraceRecords.removeAll(keepingCapacity: true)
        backgroundTraceBuffer.clear()
        backgroundTraceDrafts.removeAll(keepingCapacity: true)
        backgroundTraceDraftOrder.removeAll(keepingCapacity: true)
        let startedAt = Date()
        let startRuntimeStateDump = runtimeStateDebugDump(
            traceLimit: 0,
            traceCaptureStatusOverride: RuntimeTraceCaptureStatus(isActive: true, startedAt: startedAt)
        )
        runtimeTraceCaptureSession = RuntimeTraceCaptureSession(
            startedAt: startedAt,
            startRuntimeStateDump: startRuntimeStateDump
        )
        syncNiriResizeTraceSink()
        syncViewportMutationAuditFlag()
        controller.workspaceManager.resetReconcileTraceForDebug()
        controller.workspaceManager.resetInteractionMonitorWriteTraceForDebug()
        controller.workspaceManager.resetFloatingBarProjectionTraceForDebug()
        AppAXContext.resetRawAXNotificationTraceForDebug()
        AppAXContext.resetAXWindowsQueryTraceForDebug()
        controller.workspaceBarManager.update()
        controller.debugBarManager.update()
        return .executed
    }

    @discardableResult
    private func stopRuntimeTraceCapture() -> ExternalCommandResult {
        guard let session = runtimeTraceCaptureSession else {
            Self.logger.error("Stop runtime trace capture requested without an active session")
            return .invalidState
        }
        guard let controller else { return .internalError }

        let endedAt = Date()
        let endRuntimeStateDump = runtimeStateDebugDump(
            traceLimit: 0,
            traceCaptureStatusOverride: RuntimeTraceCaptureStatus(isActive: false, startedAt: nil)
        )
        let traceDump = controller.workspaceManager.reconcileTraceDump(limit: nil)
        let duration = endedAt.timeIntervalSince(session.startedAt)
        let fileURL = runtimeTraceCaptureFileURL(startedAt: session.startedAt, endedAt: endedAt)
        let viewportTraceDump = runtimeViewportTraceRecords.isEmpty
            ? "viewport trace empty"
            : runtimeViewportTraceRecords.joined(separator: "\n")
        let resizeTraceDump = runtimeResizeTraceRecords.isEmpty
            ? "resize trace empty"
            : runtimeResizeTraceRecords.joined(separator: "\n")
        let insertionTraceDump = runtimeInsertionTraceRecords.isEmpty
            ? "insertion trace empty"
            : runtimeInsertionTraceRecords.joined(separator: "\n")
        let mouseTraceDump = runtimeMouseTraceRecords.isEmpty
            ? "mouse trace empty"
            : runtimeMouseTraceRecords.joined(separator: "\n")
        let createFocusTraceEvents = controller.axEventHandler.createFocusTraceSnapshot()
        let createFocusTraceDump = createFocusTraceEvents.isEmpty
            ? "create focus trace empty"
            : createFocusTraceEvents.map(\.description).joined(separator: "\n")
        let rawAXNotificationDump = AppAXContext.rawAXNotificationTraceDump()
        let axWindowsQueryDump = AppAXContext.axWindowsQueryTraceDump()
        let interactionMonitorWriteDump = controller.workspaceManager.interactionMonitorWriteTraceDump()
        let floatingBarProjectionDump = controller.workspaceManager.floatingBarProjectionTraceDump()
        let body = [
            "Nehir runtime trace capture",
            "startedAt=\(session.startedAt.ISO8601Format())",
            "endedAt=\(endedAt.ISO8601Format())",
            String(format: "durationSeconds=%.3f", duration),
            "",
            "## Runtime state at start",
            session.startRuntimeStateDump,
            "",
            "## Tracing logs",
            traceDump,
            "",
            "## Niri viewport trace",
            viewportTraceDump,
            "",
            "## Niri resize trace",
            resizeTraceDump,
            "",
            "## Niri insertion trace",
            insertionTraceDump,
            "",
            "## Niri create focus trace",
            createFocusTraceDump,
            "",
            "## AX notification trace",
            rawAXNotificationDump,
            "",
            "## AX windows query trace",
            axWindowsQueryDump,
            "",
            "## Interaction monitor writes",
            interactionMonitorWriteDump,
            "",
            "## Floating bar projection trace",
            floatingBarProjectionDump,
            "",
            "## Mouse focus trace",
            mouseTraceDump,
            "",
            "## Runtime state at end",
            endRuntimeStateDump,
            ""
        ].joined(separator: "\n")

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            copyTraceExportToPasteboard(fileURL)
            Self.logger.info("Wrote runtime trace capture to \(fileURL.path, privacy: .private)")
        } catch {
            Self.logger
                .error("Failed to write runtime trace capture: \(error.localizedDescription, privacy: .public)")
            return .internalError
        }

        runtimeTraceCaptureSession = nil
        runtimeViewportTraceRecords.removeAll(keepingCapacity: true)
        runtimeResizeTraceRecords.removeAll(keepingCapacity: true)
        runtimeInsertionTraceRecords.removeAll(keepingCapacity: true)
        runtimeMouseTraceRecords.removeAll(keepingCapacity: true)
        backgroundTraceBuffer.clear()
        backgroundTraceDrafts.removeAll(keepingCapacity: true)
        backgroundTraceDraftOrder.removeAll(keepingCapacity: true)
        syncNiriResizeTraceSink()
        syncViewportMutationAuditFlag()
        controller.workspaceBarManager.update()
        controller.debugBarManager.update()
        return .executed
    }

    // MARK: - Export destinations

    private func copyDebugTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copyTraceExportToPasteboard(_ fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if controller?.settings.debugTraceExportCopiesFile == true {
            pasteboard.writeObjects([fileURL as NSURL])
        } else {
            pasteboard.setString(fileURL.path, forType: .string)
        }
    }

    /// Directory where exported runtime trace captures are written. Exposed so
    /// the Diagnostics settings tab can list recent captures from the same path
    /// the capture writer uses.
    static let traceCaptureDirectory: URL = NehirStoragePaths.live.stateDirectory
        .appendingPathComponent("traces", isDirectory: true)

    private func runtimeTraceCaptureFileURL(startedAt: Date, endedAt: Date) -> URL {
        let filename = "runtime-trace-\(Int(startedAt.timeIntervalSince1970 * 1000))-\(Int(endedAt.timeIntervalSince1970 * 1000)).log"
        return Self.traceCaptureDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private func backgroundTraceClipFileURL(startedAt: Date, endedAt: Date, exportedAt: Date) -> URL {
        let filename = "runtime-trace-background-clip-\(Int(startedAt.timeIntervalSince1970 * 1000))-\(Int(endedAt.timeIntervalSince1970 * 1000))-\(Int(exportedAt.timeIntervalSince1970 * 1000)).log"
        return Self.traceCaptureDirectory.appendingPathComponent(filename, isDirectory: false)
    }
}
