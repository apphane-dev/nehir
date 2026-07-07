// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

enum ActivationRetryReason: String, Equatable {
    case missingFocusedWindow = "missing_focused_window"
    case pendingFocusMismatch = "pending_focus_mismatch"
    case pendingFocusUnmanagedToken = "pending_focus_unmanaged_token"
    case retryExhausted = "retry_exhausted"
}

private enum ActivationRequestDisposition {
    case matchesActiveRequest(ManagedFocusRequest)
    case conflictsWithPendingRequest(ManagedFocusRequest)
    case unrelatedNoRequest
}

private enum NativeFullscreenReplacementRestoreResult {
    case notRestored
    case restored(scheduledRelayout: Bool)

    var restored: Bool {
        switch self {
        case .notRestored:
            false
        case .restored:
            true
        }
    }
}

enum ActivationCallOrigin: String {
    case external
    case probe
    case retry
}

enum PrepareCreateCandidateRejectionReason: String, Equatable {
    case missingController = "missing_controller"
    case missingToken = "missing_token"
    case tokenWindowIdMismatch = "token_window_id_mismatch"
    case existingEntry = "existing_entry"
    case ownedWindow = "owned_window"
    case missingAXRef = "missing_ax_ref"
    case untrackedDecision = "untracked_decision"
}

struct NiriCreateFocusTraceEvent: Equatable {
    enum Kind: Equatable {
        case createSeen(windowId: UInt32)
        case createRetryScheduled(windowId: UInt32, pid: pid_t, attempt: Int)
        case createPlacementResolved(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            pendingWorkspaceId: WorkspaceDescriptor.ID?,
            pendingMonitorId: Monitor.ID?,
            focusedWorkspaceId: WorkspaceDescriptor.ID?,
            focusedMonitorId: Monitor.ID?,
            nativeSpaceMonitorId: Monitor.ID?,
            frameMonitorId: Monitor.ID?,
            interactionMonitorId: Monitor.ID?,
            contextSource: String?,
            focusedWorkspaceSource: String?,
            recentPidWorkspaceId: WorkspaceDescriptor.ID?
        )
        case candidateTracked(token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
        case relayoutActivatedWindow(token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
        case pendingFocusStarted(
            requestId: UInt64,
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            reason: FocusWindowReason
        )
        case activationSourceObserved(pid: pid_t, source: ActivationEventSource)
        case followFocusToParkedWindow(token: WindowToken, workspaceId: WorkspaceDescriptor.ID, decision: String)
        /// The macOS-observed reality for a focus Nehir just confirmed. Emitted
        /// alongside `focus_confirmed` so a reader can tell Nehir's *intent*
        /// (`focus_confirmed`/`focused=`) from what the window server actually
        /// did: whether macOS made the window key (`observed_focused`), whether
        /// it is physically on screen (`on_screen`), and whether its workspace
        /// is the visible one (`ws_visible`). A confirmed focus with
        /// `observed_focused=false` or `ws_visible=false` is a model/reality
        /// divergence, not a success.
        case focusReality(
            token: WindowToken,
            observedFocused: Bool,
            observedVisible: Bool,
            onScreen: Bool,
            wsVisible: Bool,
            appFrontmost: Bool,
            appFocusedWindowId: Int?
        )
        /// The reveal decision at focus-confirm time: does Nehir actually issue a
        /// workspace switch for the confirmed window, or skip it. This is the
        /// model→screen boundary. `should_activate=false` while `visible=false`
        /// means Nehir believes the target workspace is already active and never
        /// commands the display to switch — the model diverges from the screen
        /// and nothing appears.
        case revealDecision(
            token: WindowToken,
            targetWs: WorkspaceDescriptor.ID,
            isWorkspaceActive: Bool,
            shouldActivate: Bool,
            targetWsVisible: Bool,
            source: ActivationEventSource
        )
        /// A window-rule reevaluation moved an already-placed window to a
        /// different workspace (a suspected source of workspace-assignment churn).
        /// Measured at zero on current builds, kept as a regression tripwire.
        case reevalWorkspaceChanged(
            token: WindowToken,
            from: WorkspaceDescriptor.ID,
            to: WorkspaceDescriptor.ID,
            context: String
        )
        case activationDeferred(
            requestId: UInt64,
            token: WindowToken,
            source: ActivationEventSource,
            reason: ActivationRetryReason,
            attempt: Int
        )
        case focusConfirmed(token: WindowToken, workspaceId: WorkspaceDescriptor.ID, source: ActivationEventSource)
        case borderReapplied(token: WindowToken, phase: ManagedBorderReapplyPhase)
        case nonManagedFallbackEntered(pid: pid_t, source: ActivationEventSource)
        case prepareCreateRejected(
            windowId: UInt32,
            token: WindowToken?,
            context: String,
            reason: PrepareCreateCandidateRejectionReason,
            hasWindowInfo: Bool,
            windowInfoPid: pid_t?,
            windowInfoLevel: Int32?,
            windowInfoParentId: UInt32?,
            windowInfoHasFloatingTag: Bool?,
            windowInfoHasDocumentTag: Bool?,
            windowInfoFrame: CGRect?,
            fallbackToken: WindowToken?,
            hasFallbackAXRef: Bool,
            createContextSource: String?
        )
        case unrequestedAdmissionDuringNonManagedFocusDecision(
            token: WindowToken,
            suppressed: Bool,
            reason: String,
            createContextSource: String?,
            recentPidWorkspaceId: WorkspaceDescriptor.ID?,
            hasExplicitWorkspaceAssignment: Bool,
            activeManagedRequestToken: WindowToken?
        )
        // Emitted when a `window_decision` is vetoed by the
        // unrequested-admission guard (i.e.
        // `shouldSuppressUnrequestedAdmissionDuringNonManagedFocus` returns
        // true), so tooling grepping decision records alone does not conclude
        // the window was admitted.
        case windowDecisionSuppressed(
            token: WindowToken,
            reason: String
        )
        case focusedAdmissionGuard(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID?,
            monitorId: Monitor.ID?,
            source: ActivationEventSource,
            outcome: String,
            reason: String,
            shouldDelayManagedReplacementCreate: Bool?,
            suppressedByUnrequestedGuard: Bool?,
            hasStructuralReplacementWorkspaceMatch: Bool?,
            mode: TrackedWindowMode?,
            createContextSource: String?,
            recentPidWorkspaceId: WorkspaceDescriptor.ID?
        )
        case trackPreparedCreate(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            monitorId: Monitor.ID?,
            admissionContext: WindowAdmissionContext,
            mode: TrackedWindowMode,
            hasStructuralReplacementWorkspaceMatch: Bool,
            metadataSummary: String
        )
        case windowAdmitted(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            monitorId: Monitor.ID?,
            admissionContext: WindowAdmissionContext,
            mode: TrackedWindowMode
        )
        case windowDecision(
            token: WindowToken,
            context: String,
            existingMode: TrackedWindowMode?,
            disposition: String,
            source: String,
            outcome: String,
            layout: String,
            deferred: String?,
            bundleId: String?,
            titleLength: Int?,
            axRole: String?,
            axSubrole: String?,
            hasCloseButton: Bool,
            hasFullscreenButton: Bool,
            fullscreenButtonEnabled: Bool?,
            hasZoomButton: Bool,
            hasMinimizeButton: Bool,
            appPolicy: NSApplication.ActivationPolicy?,
            attributeDiagnostics: String?,
            windowLevel: Int32?,
            windowTags: UInt64?,
            windowAttributes: UInt32?,
            parentWindowId: UInt32?,
            windowFrame: CGRect?
        )
    }

    let timestamp: Date
    let kind: Kind

    init(
        timestamp: Date = Date(),
        kind: Kind
    ) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

struct WindowCreatePlacementContext: Equatable {
    let nativeSpaceMonitorId: Monitor.ID?
    let activeFocusRequestWorkspaceId: WorkspaceDescriptor.ID?
    let activeFocusRequestMonitorId: Monitor.ID?
    let focusedWorkspaceId: WorkspaceDescriptor.ID?
    let focusedMonitorId: Monitor.ID?
    let interactionMonitorId: Monitor.ID?
    let source: String
    let focusedWorkspaceSource: String?
    let recentPidWorkspaceId: WorkspaceDescriptor.ID?
    let createdAt: Date
}

extension WindowCreatePlacementContext: CustomStringConvertible {
    var description: String {
        "native_monitor=\(String(describing: nativeSpaceMonitorId)) "
            + "active_focus_request_workspace=\(activeFocusRequestWorkspaceId?.uuidString ?? "nil") "
            + "active_focus_request_monitor=\(String(describing: activeFocusRequestMonitorId)) "
            + "focused_workspace=\(focusedWorkspaceId?.uuidString ?? "nil") "
            + "focused_monitor=\(String(describing: focusedMonitorId)) "
            + "interaction_monitor=\(String(describing: interactionMonitorId)) "
            + "source=\(source) "
            + "focused_workspace_source=\(focusedWorkspaceSource ?? "nil") "
            + "recent_pid_workspace=\(recentPidWorkspaceId?.uuidString ?? "nil") "
            + "createdAt=\(createdAt.ISO8601Format())"
    }
}

extension NiriCreateFocusTraceEvent: CustomStringConvertible {
    var description: String {
        switch kind {
        case let .createSeen(windowId):
            "create_seen window=\(windowId)"
        case let .createRetryScheduled(windowId, pid, attempt):
            "create_retry_scheduled window=\(windowId) pid=\(pid) attempt=\(attempt)"
        case let .createPlacementResolved(
            token,
            workspaceId,
            pendingWorkspaceId,
            pendingMonitorId,
            focusedWorkspaceId,
            focusedMonitorId,
            nativeSpaceMonitorId,
            frameMonitorId,
            interactionMonitorId,
            contextSource,
            focusedWorkspaceSource,
            recentPidWorkspaceId
        ):
            "create_placement_resolved token=\(token) workspace=\(workspaceId.uuidString) pending_workspace=\(pendingWorkspaceId?.uuidString ?? "nil") pending_monitor=\(String(describing: pendingMonitorId)) focused_workspace=\(focusedWorkspaceId?.uuidString ?? "nil") focused_monitor=\(String(describing: focusedMonitorId)) native_monitor=\(String(describing: nativeSpaceMonitorId)) frame_monitor=\(String(describing: frameMonitorId)) interaction_monitor=\(String(describing: interactionMonitorId)) context_source=\(contextSource ?? "nil") focused_workspace_source=\(focusedWorkspaceSource ?? "nil") recent_pid_workspace=\(recentPidWorkspaceId?.uuidString ?? "nil")"
        case let .candidateTracked(token, workspaceId):
            "candidate_tracked token=\(token) workspace=\(workspaceId.uuidString)"
        case let .relayoutActivatedWindow(token, workspaceId):
            "relayout_activated_window token=\(token) workspace=\(workspaceId.uuidString)"
        case let .pendingFocusStarted(requestId, token, workspaceId, reason):
            "pending_focus_started request=\(requestId) token=\(token) workspace=\(workspaceId.uuidString) reason=\(reason.rawValue)"
        case let .activationSourceObserved(pid, source):
            "activation_source_observed pid=\(pid) source=\(source.rawValue)"
        case let .followFocusToParkedWindow(token, workspaceId, decision):
            "follow_focus_to_parked_window token=\(token) workspace=\(workspaceId.uuidString) decision=\(decision)"
        case let .focusReality(
            token,
            observedFocused,
            observedVisible,
            onScreen,
            wsVisible,
            appFrontmost,
            appFocusedWindowId
        ):
            "focus_reality token=\(token) observed_focused=\(observedFocused) "
                + "observed_visible=\(observedVisible) on_screen=\(onScreen) ws_visible=\(wsVisible) "
                + "app_frontmost=\(appFrontmost) app_focused_window=\(appFocusedWindowId.map(String.init) ?? "nil")"
        case let .revealDecision(token, targetWs, isWorkspaceActive, shouldActivate, targetWsVisible, source):
            "reveal_decision token=\(token) target_ws=\(targetWs.uuidString) "
                + "is_ws_active=\(isWorkspaceActive) should_activate=\(shouldActivate) "
                + "target_ws_visible=\(targetWsVisible) source=\(source.rawValue)"
        case let .reevalWorkspaceChanged(token, from, to, context):
            "reeval_workspace_changed token=\(token) from=\(from.uuidString) "
                + "to=\(to.uuidString) context=\(context)"
        case let .activationDeferred(requestId, token, source, reason, attempt):
            "activation_deferred request=\(requestId) token=\(token) source=\(source.rawValue) reason=\(reason.rawValue) attempt=\(attempt)"
        case let .focusConfirmed(token, workspaceId, source):
            "focus_confirmed token=\(token) workspace=\(workspaceId.uuidString) source=\(source.rawValue)"
        case let .borderReapplied(token, phase):
            "border_reapplied token=\(token) phase=\(phase.rawValue)"
        case let .nonManagedFallbackEntered(pid, source):
            "non_managed_fallback_entered pid=\(pid) source=\(source.rawValue)"
        case let .prepareCreateRejected(
            windowId,
            token,
            context,
            reason,
            hasWindowInfo,
            windowInfoPid,
            windowInfoLevel,
            windowInfoParentId,
            windowInfoHasFloatingTag,
            windowInfoHasDocumentTag,
            windowInfoFrame,
            fallbackToken,
            hasFallbackAXRef,
            createContextSource
        ):
            "prepare_create_rejected window=\(windowId) token=\(String(describing: token)) context=\(context) reason=\(reason.rawValue) has_window_info=\(hasWindowInfo) window_info_pid=\(windowInfoPid.map(String.init) ?? "nil") window_info_level=\(windowInfoLevel.map(String.init) ?? "nil") window_info_parent=\(windowInfoParentId.map(String.init) ?? "nil") ws_float=\(windowInfoHasFloatingTag.map(String.init) ?? "nil") ws_doc=\(windowInfoHasDocumentTag.map(String.init) ?? "nil") ws_frame=\(windowInfoFrame.map { LayoutTrace.rect($0) } ?? "nil") fallback_token=\(String(describing: fallbackToken)) has_fallback_ax_ref=\(hasFallbackAXRef) create_context_source=\(createContextSource ?? "nil")"
        case let .unrequestedAdmissionDuringNonManagedFocusDecision(
            token,
            suppressed,
            reason,
            createContextSource,
            recentPidWorkspaceId,
            hasExplicitWorkspaceAssignment,
            activeManagedRequestToken
        ):
            "unrequested_admission_nonmanaged_focus_decision token=\(token) suppressed=\(suppressed) reason=\(reason) context_source=\(createContextSource ?? "nil") recent_pid_workspace=\(recentPidWorkspaceId?.uuidString ?? "nil") explicit_workspace_assignment=\(hasExplicitWorkspaceAssignment) active_managed_request_token=\(String(describing: activeManagedRequestToken))"
        case let .windowDecisionSuppressed(token, reason):
            "window_decision_suppressed token=\(token) reason=\(reason)"
        case let .focusedAdmissionGuard(
            token,
            workspaceId,
            monitorId,
            source,
            outcome,
            reason,
            shouldDelayManagedReplacementCreate,
            suppressedByUnrequestedGuard,
            hasStructuralReplacementWorkspaceMatch,
            mode,
            createContextSource,
            recentPidWorkspaceId
        ):
            "focused_admission_guard token=\(token) workspace=\(workspaceId?.uuidString ?? "nil") monitor=\(String(describing: monitorId)) source=\(source.rawValue) outcome=\(outcome) reason=\(reason) shouldDelayManagedReplacementCreate=\(shouldDelayManagedReplacementCreate.map(String.init) ?? "nil") suppressedByUnrequestedGuard=\(suppressedByUnrequestedGuard.map(String.init) ?? "nil") structuralWorkspaceMatch=\(hasStructuralReplacementWorkspaceMatch.map(String.init) ?? "nil") mode=\(mode.map { String(describing: $0) } ?? "nil") context_source=\(createContextSource ?? "nil") recent_pid_workspace=\(recentPidWorkspaceId?.uuidString ?? "nil")"
        case let .trackPreparedCreate(
            token,
            workspaceId,
            monitorId,
            admissionContext,
            mode,
            hasStructuralReplacementWorkspaceMatch,
            metadataSummary
        ):
            "track_prepared_create token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId)) admissionContext=\(admissionContext) mode=\(mode) structuralWorkspaceMatch=\(hasStructuralReplacementWorkspaceMatch) \(metadataSummary)"
        case let .windowAdmitted(token, workspaceId, monitorId, admissionContext, mode):
            "window_admitted token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId)) admissionContext=\(admissionContext) mode=\(mode)"
        case let .windowDecision(
            token,
            context,
            existingMode,
            disposition,
            source,
            outcome,
            layout,
            deferred,
            bundleId,
            titleLength,
            axRole,
            axSubrole,
            hasCloseButton,
            hasFullscreenButton,
            fullscreenButtonEnabled,
            hasZoomButton,
            hasMinimizeButton,
            appPolicy,
            attributeDiagnostics,
            windowLevel,
            windowTags,
            windowAttributes,
            parentWindowId,
            windowFrame
        ):
            "window_decision token=\(token) context=\(context) existingMode=\(existingMode.map { String(describing: $0) } ?? "nil") disposition=\(disposition) source=\(source) outcome=\(outcome) layout=\(layout) deferred=\(deferred ?? "nil") bundleId=\(bundleId ?? "nil") titleLength=\(titleLength.map(String.init) ?? "nil") axRole=\(axRole ?? "nil") axSubrole=\(axSubrole ?? "nil") hasCloseButton=\(hasCloseButton) hasFullscreenButton=\(hasFullscreenButton) fullscreenButtonEnabled=\(fullscreenButtonEnabled.map(String.init) ?? "nil") hasZoomButton=\(hasZoomButton) hasMinimizeButton=\(hasMinimizeButton) appPolicy=\(appPolicy.map { String(describing: $0) } ?? "nil") axAttributeDiagnostics=\(attributeDiagnostics ?? "nil") wsLevel=\(windowLevel.map(String.init) ?? "nil") wsTags=\(windowTags.map { String(format: "0x%llx", $0) } ?? "nil") wsAttributes=\(windowAttributes.map { String(format: "0x%x", $0) } ?? "nil") wsParent=\(parentWindowId.map(String.init) ?? "nil") wsFrame=\(windowFrame.map { "(\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height))" } ?? "nil")"
        }
    }
}

@MainActor
final class AXEventHandler: CGSEventDelegate {
    struct DebugCounters {
        var geometryRelayoutRequests = 0
        var geometryRelayoutsSuppressedDuringGesture = 0
        var geometryRelayoutsSuppressedForOwnFrameWrites = 0
        var scopedGeometryRelayoutRequests = 0
    }

    struct ManagedReplacementTraceEvent: Equatable {
        enum Kind: Equatable {
            case enqueued(
                policy: String,
                createCount: Int,
                destroyCount: Int,
                holdCount: Int,
                deadlineReset: Bool
            )
            case enqueueManagedReplacementCreate(
                policy: String,
                token: WindowToken,
                windowId: UInt32,
                monitorId: Monitor.ID?,
                mode: TrackedWindowMode,
                createCount: Int,
                destroyCount: Int,
                deadlineReset: Bool,
                hasStructuralReplacementWorkspaceMatch: Bool,
                metadataSummary: String
            )
            case enqueueManagedReplacementDestroy(
                policy: String,
                token: WindowToken,
                windowId: Int,
                monitorId: Monitor.ID?,
                mode: TrackedWindowMode,
                createCount: Int,
                destroyCount: Int,
                deadlineReset: Bool,
                metadataSummary: String
            )
            case scheduleManagedReplacementFlush(
                policy: String,
                delayMillis: Int,
                deadlineReset: Bool,
                reusedExistingDeadline: Bool,
                createCount: Int,
                destroyCount: Int
            )
            case flushed(
                policy: String,
                createCount: Int,
                destroyCount: Int,
                holdCount: Int,
                elapsedMillis: Int
            )
            case flushManagedReplacementBurst(
                policy: String,
                createCount: Int,
                destroyCount: Int,
                elapsedMillis: Int,
                matched: Bool,
                rekeyed: Bool,
                replayedCount: Int
            )
            case replayManagedReplacementEvents(count: Int, createCount: Int, destroyCount: Int, reason: String)
            case replayManagedReplacementCreate(
                token: WindowToken,
                windowId: UInt32,
                monitorId: Monitor.ID?,
                mode: TrackedWindowMode,
                metadataSummary: String
            )
            case replayManagedReplacementDestroy(
                token: WindowToken,
                windowId: Int,
                monitorId: Monitor.ID?,
                mode: TrackedWindowMode,
                metadataSummary: String
            )
            case matched(policy: String, elapsedMillis: Int)
        }

        let timestamp: TimeInterval
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
        let kind: Kind

        var description: String {
            let prefix = "pid=\(pid) workspace=\(workspaceId.uuidString) key=(\(pid),\(workspaceId.uuidString))"
            switch kind {
            case let .enqueued(policy, createCount, destroyCount, holdCount, deadlineReset):
                return "managedReplacement.enqueued \(prefix) policy=\(policy) creates=\(createCount) destroys=\(destroyCount) holds=\(holdCount) deadlineReset=\(deadlineReset)"
            case let .enqueueManagedReplacementCreate(
                policy,
                token,
                windowId,
                monitorId,
                mode,
                createCount,
                destroyCount,
                deadlineReset,
                hasStructuralReplacementWorkspaceMatch,
                metadataSummary
            ):
                return "enqueueManagedReplacementCreate \(prefix) policy=\(policy) token=\(token) windowId=\(windowId) monitor=\(String(describing: monitorId)) mode=\(mode) creates=\(createCount) destroys=\(destroyCount) deadlineReset=\(deadlineReset) structuralWorkspaceMatch=\(hasStructuralReplacementWorkspaceMatch) \(metadataSummary)"
            case let .enqueueManagedReplacementDestroy(
                policy,
                token,
                windowId,
                monitorId,
                mode,
                createCount,
                destroyCount,
                deadlineReset,
                metadataSummary
            ):
                return "enqueueManagedReplacementDestroy \(prefix) policy=\(policy) token=\(token) windowId=\(windowId) monitor=\(String(describing: monitorId)) mode=\(mode) creates=\(createCount) destroys=\(destroyCount) deadlineReset=\(deadlineReset) \(metadataSummary)"
            case let .scheduleManagedReplacementFlush(
                policy,
                delayMillis,
                deadlineReset,
                reusedExistingDeadline,
                createCount,
                destroyCount
            ):
                return "scheduleManagedReplacementFlush \(prefix) policy=\(policy) delayMillis=\(delayMillis) deadlineReset=\(deadlineReset) reusedExistingDeadline=\(reusedExistingDeadline) creates=\(createCount) destroys=\(destroyCount)"
            case let .flushed(policy, createCount, destroyCount, holdCount, elapsedMillis):
                return "managedReplacement.flushed \(prefix) policy=\(policy) creates=\(createCount) destroys=\(destroyCount) holds=\(holdCount) elapsedMillis=\(elapsedMillis)"
            case let .flushManagedReplacementBurst(
                policy,
                createCount,
                destroyCount,
                elapsedMillis,
                matched,
                rekeyed,
                replayedCount
            ):
                return "flushManagedReplacementBurst \(prefix) policy=\(policy) elapsedMillis=\(elapsedMillis) creates=\(createCount) destroys=\(destroyCount) matched=\(matched) rekeyed=\(rekeyed) replayed=\(replayedCount)"
            case let .replayManagedReplacementEvents(count, createCount, destroyCount, reason):
                return "replayManagedReplacementEvents \(prefix) count=\(count) creates=\(createCount) destroys=\(destroyCount) reason=\(reason)"
            case let .replayManagedReplacementCreate(token, windowId, monitorId, mode, metadataSummary):
                return "replayManagedReplacementEvents.create \(prefix) token=\(token) windowId=\(windowId) monitor=\(String(describing: monitorId)) mode=\(mode) \(metadataSummary)"
            case let .replayManagedReplacementDestroy(token, windowId, monitorId, mode, metadataSummary):
                return "replayManagedReplacementEvents.destroy \(prefix) token=\(token) windowId=\(windowId) monitor=\(String(describing: monitorId)) mode=\(mode) \(metadataSummary)"
            case let .matched(policy, elapsedMillis):
                return "managedReplacement.matched \(prefix) policy=\(policy) elapsedMillis=\(elapsedMillis)"
            }
        }
    }

    private func managedReplacementMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        controller?.workspaceManager.monitor(for: workspaceId)?.id
    }

    private func managedReplacementMetadataSummary(_ metadata: ManagedReplacementMetadata) -> String {
        var parts = [
            "bundle=\(metadata.bundleId ?? "nil")",
            "role=\(metadata.role ?? "nil")",
            "subrole=\(metadata.subrole ?? "nil")",
            "titleLength=\(metadata.title?.count.description ?? "nil")",
            "title=\(compactTraceString(metadata.title))",
            "frame=\(metadata.frame.map { LayoutTrace.rect($0) } ?? "nil")",
            "transient=\(metadata.transientWindowServerEvidence)",
            "degraded=\(metadata.degradedWindowServerChildEvidence)"
        ]
        if let level = metadata.windowLevel {
            parts.append("level=\(level)")
        }
        if let parent = metadata.parentWindowId {
            parts.append("parent=\(parent)")
        }
        return parts.joined(separator: " ")
    }

    private func compactTraceString(_ value: String?, limit: Int = 80) -> String {
        guard let value else { return "nil" }
        let oneLine = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if oneLine.count <= limit {
            return "\"\(oneLine)\""
        }
        let prefix = oneLine.prefix(limit)
        return "\"\(prefix)…\""
    }

    private struct PreparedCreate {
        let windowId: UInt32
        let token: WindowToken
        let axRef: AXWindowRef
        let ruleEffects: ManagedWindowRuleEffects
        let replacementMetadata: ManagedReplacementMetadata
        let hasStructuralReplacementWorkspaceMatch: Bool
        let hasExplicitWorkspaceAssignment: Bool
        let requiresPostCreateLifecycleVerification: Bool

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
    }

    private struct PreparedDestroy {
        let token: WindowToken
        let replacementMetadata: ManagedReplacementMetadata

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
    }

    private struct ManagedReplacementKey: Hashable {
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
    }

    private struct WindowCloseFocusRecoveryContext: Equatable {
        let workspaceId: WorkspaceDescriptor.ID
        let expiresAt: Date
        let suppressedActivationPid: pid_t?
        let preservedToken: WindowToken?
    }

    private enum ManagedReplacementCorrelationPolicy {
        case structural
    }

    private struct PendingManagedCreate {
        let sequence: UInt64
        let candidate: PreparedCreate
    }

    private struct PendingManagedDestroy {
        let sequence: UInt64
        let candidate: PreparedDestroy
    }

    private enum PendingManagedReplacementEvent {
        case create(PendingManagedCreate)
        case destroy(PendingManagedDestroy)

        var sequence: UInt64 {
            switch self {
            case let .create(create): create.sequence
            case let .destroy(destroy): destroy.sequence
            }
        }
    }

    private struct PendingManagedReplacementBurst {
        let policy: ManagedReplacementCorrelationPolicy
        let firstEventUptime: TimeInterval
        var creates: [PendingManagedCreate] = []
        var destroys: [PendingManagedDestroy] = []

        mutating func append(create: PendingManagedCreate) {
            guard !creates.contains(where: { $0.candidate.token == create.candidate.token }) else { return }
            creates.append(create)
        }

        mutating func append(destroy: PendingManagedDestroy) {
            guard !destroys.contains(where: { $0.candidate.token == destroy.candidate.token }) else { return }
            destroys.append(destroy)
        }

        var orderedEvents: [PendingManagedReplacementEvent] {
            let events = creates.map(PendingManagedReplacementEvent.create) + destroys
                .map(PendingManagedReplacementEvent.destroy)
            return events.sorted { $0.sequence < $1.sequence }
        }

        func orderedEvents(excludingSequences sequences: Set<UInt64>) -> [PendingManagedReplacementEvent] {
            orderedEvents.filter { !sequences.contains($0.sequence) }
        }
    }

    private struct MatchedManagedReplacementPair {
        let destroy: PendingManagedDestroy
        let create: PendingManagedCreate

        var excludedSequences: Set<UInt64> {
            [destroy.sequence, create.sequence]
        }
    }

    private struct StructuralReplacementMatch {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
    }

    private struct RecentManagedAdmission {
        let workspaceId: WorkspaceDescriptor.ID
        let recordedAt: TimeInterval
    }

    private struct FocusedWindowLossClosePrecursor {
        let workspaceId: WorkspaceDescriptor.ID
        let preservedToken: WindowToken?
        let recordedAt: TimeInterval
    }

    private static let managedReplacementGraceDelay: Duration = .milliseconds(150)
    private static let nativeFullscreenFollowupDelay: Duration = .seconds(1)
    private static let nativeFullscreenStaleCleanupDelay: Duration = .seconds(
        Int64(WorkspaceManager.staleUnavailableNativeFullscreenTimeout)
    )
    private static let windowCloseFocusRecoveryDuration: TimeInterval = 0.6
    private static let stabilizationRetryDelay: Duration = .milliseconds(100)
    private static let postCreateLifecycleVerificationDelay: Duration = .milliseconds(75)
    private static let createdWindowRetryLimit = 5
    private static let createPlacementContextTTL: TimeInterval = 15
    private static let recentManagedAdmissionTTL: TimeInterval = 15
    // A deliberate user app switch (Dock/Cmd-Tab/launcher) and the target
    // window's focused-admission arrive within a second or two of each other,
    // so a short window suffices to bridge them. Kept well below
    // recentManagedAdmissionTTL (15s) on purpose: this exemption widens the
    // unrequested-admission guard, so it should decay quickly to avoid
    // admitting unrelated surfaces that merely happen to share the pid.
    private static let recentAppActivationTTL: TimeInterval = 10
    private static let activationRetryLimit = 5
    private static let nativeAppSwitchLeaseRequestConfirmationGrace: TimeInterval = 0.6
    private static let createFocusTraceLimit = 128
    private static let managedReplacementTraceLimit = 128
    private static let createFocusTraceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_NIRI_CREATE_FOCUS"] == "1"
    private static let managedReplacementTraceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_MANAGED_REPLACEMENT"] == "1"

    weak var controller: WMController?
    private var deferredCreatedWindowIds: Set<UInt32> = []
    private var deferredCreatedWindowOrder: [UInt32] = []
    private var createPlacementContextsByWindowId: [UInt32: WindowCreatePlacementContext] = [:]
    private struct RecentManagedWorkspace {
        let workspaceId: WorkspaceDescriptor.ID
        let recordedAt: TimeInterval
    }

    private var recentManagedWorkspaceByPid: [pid_t: RecentManagedWorkspace] = [:]
    private var recentAppActivationByPid: [pid_t: TimeInterval] = [:]
    // A same-app window that recently closed is the only case the
    // inactive-workspace activation guard is meant for (macOS re-focuses a
    // successor window of the same app after a close). Tracked per pid.
    private static let recentSameAppWindowCloseTTL: TimeInterval = 2
    private static let recentNonManagedFocusTTL: TimeInterval = 2
    private static let focusedWindowLossClosePrecursorTTL: TimeInterval = 0.6
    private var recentSameAppWindowCloseByPid: [pid_t: TimeInterval] = [:]
    private var recentNonManagedFocusByPid: [pid_t: TimeInterval] = [:]
    private var focusedWindowLossClosePrecursorByPid: [pid_t: FocusedWindowLossClosePrecursor] = [:]
    private static let parkedFocusFollowDedupTTL: TimeInterval = 1.5
    private var recentParkedFocusFollowByToken: [WindowToken: TimeInterval] = [:]
    // After follow_focus switches an app to a parked window's workspace, hold
    // that workspace briefly so a same-app confirm of another window does not
    // bounce the view back.
    private static let parkedFollowHoldTTL: TimeInterval = 1.2
    private var parkedFollowHoldByPid: [pid_t: (workspaceId: WorkspaceDescriptor.ID, at: TimeInterval)] = [:]
    private var recentManagedAdmissionByToken: [WindowToken: RecentManagedAdmission] = [:]
    private var pendingManagedReplacementBursts: [ManagedReplacementKey: PendingManagedReplacementBurst] = [:]
    private var pendingManagedReplacementTasks: [ManagedReplacementKey: Task<Void, Never>] = [:]
    private var windowCloseFocusRecoveryContext: WindowCloseFocusRecoveryContext?
    private var deferredInactiveNativeActivationTokens: Set<WindowToken> = []
    private var deferredSameAppActiveNativeActivationTokens: Set<WindowToken> = []
    private var pendingNativeFullscreenFollowupTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingNativeFullscreenStaleCleanupTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingWindowRuleReevaluationTask: Task<Void, Never>?
    private var pendingWindowRuleReevaluationTargets: Set<WindowRuleReevaluationTarget> = []
    private var pendingWindowStabilizationTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingPostCreateLifecycleVerificationTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingDestroyLivenessVerificationTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingCreatedWindowRetryTasks: [UInt32: Task<Void, Never>] = [:]
    private var createdWindowRetryCountById: [UInt32: Int] = [:]
    private var pendingActivationRetryTask: Task<Void, Never>?
    private var pendingActivationRetryRequestId: UInt64?
    private var createFocusTrace: [NiriCreateFocusTraceEvent] = []
    private var managedReplacementTrace: [ManagedReplacementTraceEvent] = []
    private var nextManagedReplacementEventSequence: UInt64 = 0
    var windowInfoProvider: ((UInt32) -> WindowServerInfo?)?
    var windowInfoProviderIsAuthoritativeForTests = false
    var axWindowRefProvider: ((UInt32, pid_t) -> AXWindowRef?)?
    var bundleIdProvider: ((pid_t) -> String?)?
    var windowSubscriptionHandler: (([UInt32]) -> Void)?
    var focusedWindowValueProvider: ((pid_t) -> CFTypeRef?)?
    var focusedWindowRefProvider: ((pid_t) -> AXWindowRef?)?
    var windowFactsProvider: ((AXWindowRef, pid_t) -> WindowRuleFacts?)?
    var frameProvider: ((AXWindowRef) -> CGRect?)?
    var fastFrameProvider: ((AXWindowRef) -> CGRect?)?
    var isFullscreenProvider: ((AXWindowRef) -> Bool)?
    var spaceDisplayResolver: ((UInt64, [Monitor]) -> CGDirectDisplayID?)?
    var managedReplacementTimeSourceForTests: (() -> TimeInterval)?
    var axContextWarmupHandlerForTests: ((pid_t) -> Void)?
    private(set) var debugCounters = DebugCounters()

    init(
        controller: WMController
    ) {
        self.controller = controller
    }

    func setup() {
        CGSEventObserver.shared.delegate = self
        CGSEventObserver.shared.start()
    }

    func cleanup() {
        resetCreatePlacementContextState()
        recentManagedWorkspaceByPid.removeAll()
        recentAppActivationByPid.removeAll()
        recentSameAppWindowCloseByPid.removeAll()
        recentNonManagedFocusByPid.removeAll()
        focusedWindowLossClosePrecursorByPid.removeAll()
        recentParkedFocusFollowByToken.removeAll()
        parkedFollowHoldByPid.removeAll()
        recentManagedAdmissionByToken.removeAll()
        resetManagedReplacementState()
        deferredInactiveNativeActivationTokens.removeAll()
        deferredSameAppActiveNativeActivationTokens.removeAll()
        endWindowCloseFocusRecovery()
        resetNativeFullscreenReplacementState()
        resetWindowStabilizationState()
        resetLifecycleVerificationState()
        resetCreatedWindowRetryState()
        resetActivationRetryState()
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
        CGSEventObserver.shared.delegate = nil
        CGSEventObserver.shared.stop()
    }

    func cgsEventObserver(_: CGSEventObserver, didReceive event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, spaceId):
            handleCGSWindowCreated(windowId: windowId, spaceId: spaceId)
            controller.workspaceManager.noteNativeSpace(windowId: windowId, spaceId: spaceId)

        case let .destroyed(windowId, _):
            handleCGSWindowDestroyed(windowId: windowId)
            controller.workspaceManager.forgetNativeSpace(windowId: windowId)

        case let .closed(windowId):
            handleCGSWindowDestroyed(windowId: windowId)
            controller.workspaceManager.forgetNativeSpace(windowId: windowId)

        case let .frameChanged(windowId):
            handleFrameChanged(windowId: windowId)

        case let .frontAppChanged(pid):
            handleAppActivation(pid: pid, source: .cgsFrontAppChanged)

        case let .titleChanged(windowId):
            AXWindowService.invalidateCachedTitle(windowId: windowId)
            controller.requestWorkspaceProjectionRefresh()
            if let token = resolveWindowToken(windowId) ?? resolveTrackedToken(windowId) {
                updateManagedReplacementTitle(windowId: windowId, token: token)
                scheduleWindowRuleReevaluationIfNeeded(targets: [.window(token)])
            }
        }
    }

    private func scheduleWindowRuleReevaluationIfNeeded(
        targets: Set<WindowRuleReevaluationTarget>
    ) {
        guard let controller,
              controller.windowRuleEngine.needsWindowReevaluation,
              !targets.isEmpty
        else {
            return
        }

        pendingWindowRuleReevaluationTargets.formUnion(targets)
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard let self, let controller = self.controller else { return }
            let targets = self.pendingWindowRuleReevaluationTargets
            self.pendingWindowRuleReevaluationTargets.removeAll()
            _ = await controller.reevaluateWindowRules(for: targets)
        }
    }

    private func isWindowDisplayable(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            return false
        }
        return controller.isManagedWindowDisplayable(entry.handle)
    }

    private func handleCGSWindowCreated(windowId: UInt32, spaceId: UInt64) {
        captureCreatePlacementContext(windowId: windowId, spaceId: spaceId)
        recordNiriCreateFocusTrace(.init(kind: .createSeen(windowId: windowId)))
        processCreatedWindow(windowId: windowId)
    }

    private func processCreatedWindow(windowId: UInt32) {
        guard let controller else { return }
        if controller.isDiscoveryInProgress {
            deferCreatedWindow(windowId)
            return
        }
        if controller.isOwnedWindow(windowNumber: Int(windowId)) {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            removeDeferredCreatedWindow(windowId)
            return
        }

        let windowInfo = resolveWindowInfo(windowId)
        let nativeFullscreenRestore = restoreNativeFullscreenCreateBeforeAdmissionIfNeeded(
            windowId: windowId,
            windowInfo: windowInfo,
            createPlacementContext: createPlacementContextsByWindowId[windowId]
        )
        if nativeFullscreenRestore.restored {
            completeNativeFullscreenCreateRestore(
                nativeFullscreenRestore,
                windowId: windowId
            )
            return
        }
        guard let candidate = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            createPlacementContext: createPlacementContextsByWindowId[windowId]
        ) else {
            if let windowInfo {
                _ = scheduleCreatedWindowRetryIfNeeded(
                    windowId: windowId,
                    pid: pid_t(windowInfo.pid)
                )
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(windowInfo.pid))])
            } else {
                _ = scheduleCreatedWindowInfoRetryIfNeeded(windowId: windowId)
            }
            return
        }

        cancelCreatedWindowRetry(windowId: windowId)
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(candidate)
            return
        }

        trackPreparedCreate(candidate)
    }

    func resetDebugStateForTests() {
        debugCounters = .init()
        resetManagedReplacementState()
        resetNativeFullscreenReplacementState()
        resetWindowStabilizationState()
        resetLifecycleVerificationState()
        resetCreatedWindowRetryState()
        resetCreatePlacementContextState()
        recentManagedWorkspaceByPid.removeAll()
        recentAppActivationByPid.removeAll()
        recentSameAppWindowCloseByPid.removeAll()
        recentNonManagedFocusByPid.removeAll()
        focusedWindowLossClosePrecursorByPid.removeAll()
        recentParkedFocusFollowByToken.removeAll()
        parkedFollowHoldByPid.removeAll()
        recentManagedAdmissionByToken.removeAll()
        deferredInactiveNativeActivationTokens.removeAll()
        deferredSameAppActiveNativeActivationTokens.removeAll()
        resetActivationRetryState()
        controller?.focusBridge.reset()
        createFocusTrace.removeAll(keepingCapacity: true)
        managedReplacementTrace.removeAll(keepingCapacity: true)
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
    }

    func probeFocusedWindowAfterFronting(
        expectedToken: WindowToken,
        workspaceId _: WorkspaceDescriptor.ID
    ) {
        let requestId = controller?.focusBridge.activeManagedRequest(for: expectedToken)?.requestId
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let requestId,
               self.controller?.focusBridge.activeManagedRequest(requestId: requestId) == nil
            {
                return
            }
            self.handleAppActivation(
                pid: expectedToken.pid,
                source: .focusedWindowChanged,
                origin: .probe
            )
        }
    }

    func createFocusTraceSnapshot() -> [NiriCreateFocusTraceEvent] {
        createFocusTrace
    }

    func niriCreateFocusTraceSnapshotForTests() -> [NiriCreateFocusTraceEvent] {
        createFocusTraceSnapshot()
    }

    func managedReplacementTraceSnapshot() -> [ManagedReplacementTraceEvent] {
        managedReplacementTrace
    }

    func managedReplacementTraceSnapshotForTests() -> [ManagedReplacementTraceEvent] {
        managedReplacementTraceSnapshot()
    }

    func managedReplacementTraceDump() -> String {
        var sections: [String] = []
        if pendingManagedReplacementBursts.isEmpty {
            sections.append("pending managed replacement bursts empty")
        } else {
            let pending = pendingManagedReplacementBursts
                .sorted { lhs, rhs in
                    if lhs.key.pid != rhs.key.pid { return lhs.key.pid < rhs.key.pid }
                    return lhs.key.workspaceId.uuidString < rhs.key.workspaceId.uuidString
                }
                .map { key, burst in
                    let elapsedMillis = max(
                        0,
                        Int(((managedReplacementCurrentUptime() - burst.firstEventUptime) * 1000).rounded())
                    )
                    return "pending key=(\(key.pid),\(key.workspaceId.uuidString)) policy=\(managedReplacementPolicyName(burst.policy)) creates=\(burst.creates.count) destroys=\(burst.destroys.count) elapsedMillis=\(elapsedMillis) task=\(pendingManagedReplacementTasks[key] != nil)"
                }
            sections.append(pending.joined(separator: "\n"))
        }

        if managedReplacementTrace.isEmpty {
            sections.append("managed replacement trace empty")
        } else {
            sections.append(managedReplacementTrace.map(\.description).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n")
    }

    /// Renders the live `WindowCreatePlacementContext` map (the inputs captured at
    /// create time) for the runtime trace dump. Preserves the placement inputs even
    /// if `create_placement_resolved` has rotated out of the ring buffer.
    func createPlacementContextDebugDump() -> String {
        pruneExpiredCreatePlacementContexts()
        guard !createPlacementContextsByWindowId.isEmpty else {
            return "create placement contexts empty"
        }
        let entries = createPlacementContextsByWindowId
            .sorted { $0.key < $1.key }
            .map { windowId, context in "window=\(windowId) \(context)" }
        return "count=\(createPlacementContextsByWindowId.count)\n"
            + entries.joined(separator: "\n")
    }

    func pendingCreatePlacementContext(for windowId: Int) -> WindowCreatePlacementContext? {
        guard let windowId = UInt32(exactly: windowId) else { return nil }
        pruneExpiredCreatePlacementContexts()
        return createPlacementContextsByWindowId[windowId]
    }

    func discardCreatePlacementContext(for windowId: Int) {
        guard let windowId = UInt32(exactly: windowId) else { return }
        discardCreatePlacementContext(windowId: windowId)
    }

    func shouldSuppressUnrequestedAdmissionDuringNonManagedFocus(
        token: WindowToken,
        createPlacementContext: WindowCreatePlacementContext?,
        hasExplicitWorkspaceAssignment: Bool = false
    ) -> Bool {
        guard let controller,
              controller.workspaceManager.isNonManagedFocusActive
        else {
            return false
        }
        let activeManagedRequestToken = controller.focusBridge.activeManagedRequest?.token
        guard !hasExplicitWorkspaceAssignment else {
            recordUnrequestedAdmissionDuringNonManagedFocusDecision(
                token: token,
                suppressed: false,
                reason: "explicit_workspace_assignment",
                createPlacementContext: createPlacementContext,
                hasExplicitWorkspaceAssignment: hasExplicitWorkspaceAssignment,
                activeManagedRequestToken: activeManagedRequestToken
            )
            return false
        }
        guard activeManagedRequestToken != token else {
            recordUnrequestedAdmissionDuringNonManagedFocusDecision(
                token: token,
                suppressed: false,
                reason: "matches_active_managed_request",
                createPlacementContext: createPlacementContext,
                hasExplicitWorkspaceAssignment: hasExplicitWorkspaceAssignment,
                activeManagedRequestToken: activeManagedRequestToken
            )
            return false
        }

        // A real CGS create is a user/new-window signal and should still be
        // admitted. Likewise, an AX-focused admission tied to a fresh recently
        // managed workspace for the same pid is a focused app-bounce
        // continuation, not a random stale surface discovered while unmanaged
        // focus is active. Existing AX/WindowServer surfaces without either
        // signal are not reliable placement/focus inputs; admitting them here
        // pulls random apps into the active workspace.
        if createPlacementContext?.source == "cgs_created" {
            recordUnrequestedAdmissionDuringNonManagedFocusDecision(
                token: token,
                suppressed: false,
                reason: "cgs_created_context",
                createPlacementContext: createPlacementContext,
                hasExplicitWorkspaceAssignment: hasExplicitWorkspaceAssignment,
                activeManagedRequestToken: activeManagedRequestToken
            )
            return false
        }
        if createPlacementContext?.recentPidWorkspaceId != nil {
            recordUnrequestedAdmissionDuringNonManagedFocusDecision(
                token: token,
                suppressed: false,
                reason: "recent_pid_workspace",
                createPlacementContext: createPlacementContext,
                hasExplicitWorkspaceAssignment: hasExplicitWorkspaceAssignment,
                activeManagedRequestToken: activeManagedRequestToken
            )
            return false
        }
        // A deliberate user app switch to this pid (observed as a
        // workspaceDidActivateApplication activation moments earlier) is an
        // intent signal on par with a CGS create. Without this, launcher/Dock/
        // Cmd-Tab switches to an existing-but-untracked window are dropped and
        // the untracked window's own focus keeps non-managed focus armed,
        // trapping it permanently.
        if hasRecentAppActivation(for: token.pid) {
            recordUnrequestedAdmissionDuringNonManagedFocusDecision(
                token: token,
                suppressed: false,
                reason: "recent_app_activation",
                createPlacementContext: createPlacementContext,
                hasExplicitWorkspaceAssignment: hasExplicitWorkspaceAssignment,
                activeManagedRequestToken: activeManagedRequestToken
            )
            return false
        }

        recordUnrequestedAdmissionDuringNonManagedFocusDecision(
            token: token,
            suppressed: true,
            reason: "stale_unrequested_nonmanaged_focus",
            createPlacementContext: createPlacementContext,
            hasExplicitWorkspaceAssignment: hasExplicitWorkspaceAssignment,
            activeManagedRequestToken: activeManagedRequestToken
        )
        recordNiriCreateFocusTrace(
            .init(
                kind: .windowDecisionSuppressed(
                    token: token,
                    reason: "stale_unrequested_nonmanaged_focus"
                )
            )
        )
        return true
    }

    private func recordUnrequestedAdmissionDuringNonManagedFocusDecision(
        token: WindowToken,
        suppressed: Bool,
        reason: String,
        createPlacementContext: WindowCreatePlacementContext?,
        hasExplicitWorkspaceAssignment: Bool,
        activeManagedRequestToken: WindowToken?
    ) {
        recordNiriCreateFocusTrace(
            .init(
                kind: .unrequestedAdmissionDuringNonManagedFocusDecision(
                    token: token,
                    suppressed: suppressed,
                    reason: reason,
                    createContextSource: createPlacementContext?.source,
                    recentPidWorkspaceId: createPlacementContext?.recentPidWorkspaceId,
                    hasExplicitWorkspaceAssignment: hasExplicitWorkspaceAssignment,
                    activeManagedRequestToken: activeManagedRequestToken
                )
            )
        )
    }

    func structuralReplacementWorkspaceIdForCreate(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts,
        admittedThisPass: Set<WindowToken>
    ) -> WorkspaceDescriptor.ID? {
        if let workspaceId = recentManagedAdmissionWorkspaceId(for: token) {
            return workspaceId
        }
        return structuralReplacementMatch(
            token: token,
            bundleId: bundleId,
            mode: mode,
            facts: facts,
            admittedThisPass: admittedThisPass
        )?.workspaceId
    }

    @discardableResult
    func rekeyStructuralManagedReplacementIfNeeded(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts,
        admittedThisPass: Set<WindowToken>
    ) -> Bool {
        guard let match = structuralReplacementMatch(
            token: token,
            bundleId: bundleId,
            mode: mode,
            facts: facts,
            admittedThisPass: admittedThisPass
        ) else {
            return false
        }

        let metadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: match.workspaceId,
            mode: mode,
            facts: facts
        )
        guard rekeyManagedWindowIdentity(
            from: match.token,
            to: token,
            windowId: windowId,
            axRef: axRef,
            managedReplacementMetadata: metadata
        ) != nil else {
            return false
        }

        discardCreatePlacementContext(windowId: windowId)
        return true
    }

    func recordNiriCreateFocusTrace(_ event: NiriCreateFocusTraceEvent) {
        if createFocusTrace.count == Self.createFocusTraceLimit {
            createFocusTrace.removeFirst()
        }
        createFocusTrace.append(event)

        if Self.createFocusTraceLoggingEnabled {
            fputs("[NiriCreateFocus] \(event.description)\n", stderr)
        }
    }

    private func managedReplacementCurrentUptime() -> TimeInterval {
        managedReplacementTimeSourceForTests?() ?? ProcessInfo.processInfo.systemUptime
    }

    private func managedReplacementPolicyName(_ policy: ManagedReplacementCorrelationPolicy) -> String {
        switch policy {
        case .structural:
            "structural"
        }
    }

    private func recordManagedReplacementTrace(
        key: ManagedReplacementKey,
        kind: ManagedReplacementTraceEvent.Kind
    ) {
        let event = ManagedReplacementTraceEvent(
            timestamp: managedReplacementCurrentUptime(),
            pid: key.pid,
            workspaceId: key.workspaceId,
            kind: kind
        )
        if managedReplacementTrace.count == Self.managedReplacementTraceLimit {
            managedReplacementTrace.removeFirst()
        }
        managedReplacementTrace.append(event)

        if Self.managedReplacementTraceLoggingEnabled {
            fputs("[ManagedReplacement] \(event.description)\n", stderr)
        }
    }

    private func handleFrameChanged(windowId: UInt32) {
        guard let controller else { return }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        let windowServerToken = resolveWindowToken(windowId)
        let resolvedToken = resolveTrackedToken(
            windowId,
            resolvedWindowToken: windowServerToken
        )
        let focusedObservedFrame = updateFocusedBorderForFrameChange(
            windowId: windowId,
            windowServerToken: windowServerToken,
            resolvedToken: resolvedToken
        )
        guard let token = resolvedToken else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else { return }

        guard isWindowDisplayable(token: token) else {
            return
        }

        if entry.mode == .floating {
            if let frame = focusedObservedFrame ?? observedFrame(for: entry) {
                controller.workspaceManager.updateFloatingGeometry(frame: frame, for: token)
            }
            return
        }

        if controller.isInteractiveGestureActive {
            debugCounters.geometryRelayoutsSuppressedDuringGesture += 1
            return
        }

        if controller.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) {
            debugCounters.geometryRelayoutsSuppressedDuringGesture += 1
            return
        }

        if shouldSuppressFrameChangedRelayout(
            for: entry,
            observedFrame: focusedObservedFrame
        ) {
            return
        }

        let suppressionObservedFrame = focusedObservedFrame
            ?? (controller.axManager.lastAppliedFrame(for: entry.windowId) == nil ? nil : observedFrame(for: entry))
        if suppressionObservedFrame != focusedObservedFrame,
           shouldSuppressFrameChangedRelayout(
               for: entry,
               observedFrame: suppressionObservedFrame
           )
        {
            return
        }

        debugCounters.geometryRelayoutRequests += 1
        debugCounters.scopedGeometryRelayoutRequests += 1
        controller.layoutRefreshController.requestRefresh(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func shouldSuppressFrameChangedRelayout(
        for entry: WindowModel.Entry,
        observedFrame: CGRect?
    ) -> Bool {
        guard let controller else { return false }
        if controller.axManager.shouldSuppressFrameChangeRelayout(
            for: entry.windowId,
            observedFrame: observedFrame
        ) {
            debugCounters.geometryRelayoutsSuppressedForOwnFrameWrites += 1
            return true
        }
        return false
    }

    private func updateFocusedBorderForFrameChange(
        windowId: UInt32,
        windowServerToken: WindowToken?,
        resolvedToken: WindowToken?
    ) -> CGRect? {
        guard let controller else { return nil }
        guard let target = controller.currentBorderTarget() else { return nil }

        if let windowServerToken {
            guard windowServerToken == target.token else { return nil }
        } else if let entry = controller.workspaceManager.entry(for: target.token) {
            guard resolvedToken == target.token,
                  entry.mode == .floating
            else { return nil }
            if needsFocusedAXConfirmationForUnresolvedFrameChange(entry),
               focusedWindowToken(for: target.pid) != target.token
            {
                return nil
            }
        } else {
            guard !target.isManaged,
                  target.windowId == Int(windowId),
                  focusedWindowToken(for: target.pid) == target.token
            else { return nil }
        }

        if let entry = controller.workspaceManager.entry(for: target.token) {
            let pendingFrame = controller.axManager.pendingFrameWrite(for: entry.windowId)

            if let pendingFrame {
                _ = controller.focusBorderController.updateFrameHint(
                    for: target.token,
                    frame: pendingFrame
                )
                return nil
            }

            if let frame = observedFrame(for: entry) {
                updateManagedReplacementFrame(frame, for: entry)
                _ = controller.focusBorderController.updateFrameHint(
                    for: target.token,
                    frame: frame,
                    source: .observed
                )
                return frame
            }

            return nil
        }

        if let frame = observedFrame(for: target.axRef) {
            _ = controller.focusBorderController.updateFrameHint(
                for: target.token,
                frame: frame,
                source: .observed
            )
            return frame
        }

        return nil
    }

    private func needsFocusedAXConfirmationForUnresolvedFrameChange(_ entry: WindowModel.Entry) -> Bool {
        guard let controller else { return true }
        return entry.layoutReason == .nativeFullscreen
            || controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
    }

    private func observedFrame(for entry: WindowModel.Entry) -> CGRect? {
        observedFrame(for: entry.axRef)
    }

    private func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        frameProvider?(axRef)
            ?? fastFrameProvider?(axRef)
            ?? AXWindowService.framePreferFast(axRef)
            ?? (try? AXWindowService.frame(axRef))
    }

    private func handleCGSWindowDestroyed(windowId: UInt32) {
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        cancelCreatedWindowRetry(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        handleWindowDestroyed(windowId: windowId, pidHint: nil, verifyWindowServerLiveness: false)
    }

    func subscribeToManagedWindows() {
        guard let controller else { return }
        let windowIds = controller.workspaceManager.allEntries().compactMap { entry -> UInt32? in
            UInt32(entry.windowId)
        }
        subscribeToWindows(windowIds)
    }

    func drainDeferredCreatedWindows() async {
        guard !deferredCreatedWindowOrder.isEmpty else { return }

        let deferredWindowIds = deferredCreatedWindowOrder
        deferredCreatedWindowOrder.removeAll()
        deferredCreatedWindowIds.removeAll()

        for windowId in deferredWindowIds {
            guard let controller else { return }
            if controller.isOwnedWindow(windowNumber: Int(windowId)) {
                cancelCreatedWindowRetry(windowId: windowId)
                discardCreatePlacementContext(windowId: windowId)
                continue
            }
            guard let windowInfo = resolveWindowInfo(windowId) else {
                _ = scheduleCreatedWindowInfoRetryIfNeeded(windowId: windowId)
                continue
            }
            let token = WindowToken(pid: pid_t(windowInfo.pid), windowId: Int(windowId))
            if controller.workspaceManager.entry(for: token) != nil {
                discardCreatePlacementContext(windowId: windowId)
                continue
            }
            let nativeFullscreenRestore = restoreNativeFullscreenCreateBeforeAdmissionIfNeeded(
                windowId: windowId,
                windowInfo: windowInfo,
                createPlacementContext: createPlacementContextsByWindowId[windowId]
            )
            if nativeFullscreenRestore.restored {
                completeNativeFullscreenCreateRestore(
                    nativeFullscreenRestore,
                    windowId: windowId
                )
                continue
            }
            guard let candidate = prepareCreateCandidate(
                windowId: windowId,
                windowInfo: windowInfo,
                createPlacementContext: createPlacementContextsByWindowId[windowId]
            ) else {
                _ = scheduleCreatedWindowRetryIfNeeded(
                    windowId: windowId,
                    pid: pid_t(windowInfo.pid)
                )
                continue
            }
            cancelCreatedWindowRetry(windowId: windowId)
            if shouldDelayManagedReplacementCreate(candidate) {
                enqueueManagedReplacementCreate(candidate)
            } else {
                trackPreparedCreate(candidate)
            }
        }
    }

    private func trackPreparedCreate(
        _ candidate: PreparedCreate,
        admissionContext: WindowAdmissionContext = .windowCreate
    ) {
        guard let controller else { return }
        if controller.diagnostics.isRuntimeTraceCaptureActive {
            let pendingRemoval = controller.layoutRefreshController.pendingWindowRemovalPayload(
                for: candidate.token,
                workspaceId: candidate.workspaceId
            )
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: candidate.workspaceId,
                reason: "readmit_pending_removal",
                details: [
                    "token=\(candidate.token)",
                    "workspaceId=\(candidate.workspaceId.uuidString)",
                    "pendingRemovalExists=\(pendingRemoval != nil)",
                    "pendingRemovalSeedNodeId=\(pendingRemoval?.removedNodeId.map(String.init(describing:)) ?? "nil")"
                ]
            )
        }
        cancelCreatedWindowRetry(windowId: candidate.windowId)
        discardCreatePlacementContext(windowId: candidate.windowId)
        recordNiriCreateFocusTrace(
            .init(
                kind: .candidateTracked(
                    token: candidate.token,
                    workspaceId: candidate.workspaceId
                )
            )
        )

        recordNiriCreateFocusTrace(
            .init(
                kind: .trackPreparedCreate(
                    token: candidate.token,
                    workspaceId: candidate.workspaceId,
                    monitorId: managedReplacementMonitorId(for: candidate.workspaceId),
                    admissionContext: admissionContext,
                    mode: candidate.mode,
                    hasStructuralReplacementWorkspaceMatch: candidate.hasStructuralReplacementWorkspaceMatch,
                    metadataSummary: managedReplacementMetadataSummary(candidate.replacementMetadata)
                )
            )
        )

        let appFullscreen = isFullscreenProvider?(candidate.axRef) ?? AXWindowService.isFullscreen(candidate.axRef)
        let nativeFullscreenRestore = restoreNativeFullscreenReplacement(
            token: candidate.token,
            windowId: candidate.windowId,
            axRef: candidate.axRef,
            workspaceId: candidate.workspaceId,
            appFullscreen: appFullscreen
        )
        if nativeFullscreenRestore.restored {
            if case let .restored(scheduledRelayout) = nativeFullscreenRestore,
               !scheduledRelayout
            {
                controller.layoutRefreshController.requestRefresh(reason: .axWindowCreated)
            }
            return
        }

        let trackedToken = controller.workspaceManager.addWindow(
            candidate.axRef,
            pid: candidate.token.pid,
            windowId: candidate.token.windowId,
            to: candidate.workspaceId,
            mode: candidate.mode,
            ruleEffects: candidate.ruleEffects,
            managedReplacementMetadata: candidate.replacementMetadata,
            admissionContext: admissionContext
        )
        guard let trackedEntry = controller.workspaceManager.entry(for: trackedToken) else {
            scheduleAXContextWarmup(for: candidate.token.pid)
            return
        }
        recordNiriCreateFocusTrace(
            .init(
                kind: .windowAdmitted(
                    token: trackedToken,
                    workspaceId: trackedEntry.workspaceId,
                    monitorId: managedReplacementMonitorId(for: trackedEntry.workspaceId),
                    admissionContext: admissionContext,
                    mode: trackedEntry.mode
                )
            )
        )
        recordRecentManagedAdmission(token: trackedToken, workspaceId: trackedEntry.workspaceId)

        let shouldActivateFloatingCreate = shouldActivateFloatingCreate(candidate, trackedEntry: trackedEntry)
        if shouldActivateFloatingCreate {
            controller.focusPolicyEngine.beginLease(
                owner: .ruleCreatedFloatingWindow,
                reason: "floating_window_create",
                suppressesFocusFollowsMouse: true,
                duration: 0.35
            )
        }

        var floatingTargetFrame: CGRect?
        if trackedEntry.mode == .floating {
            let observedFrame = frameProvider?(candidate.axRef)
                ?? fastFrameProvider?(candidate.axRef)
                ?? AXWindowService.framePreferFast(candidate.axRef)
                ?? (try? AXWindowService.frame(candidate.axRef))
            let preferredMonitor = controller.workspaceManager.monitor(for: trackedEntry.workspaceId)

            if let observedFrame {
                updateManagedReplacementFrame(observedFrame, for: trackedEntry)
                if controller.workspaceManager.floatingState(for: trackedToken) == nil {
                    controller.workspaceManager.updateFloatingGeometry(
                        frame: observedFrame,
                        for: trackedToken,
                        referenceMonitor: preferredMonitor
                    )
                }
            }

            floatingTargetFrame = controller.workspaceManager.resolvedFloatingFrame(
                for: trackedToken,
                preferredMonitor: preferredMonitor
            )
        }

        if shouldActivateFloatingCreate,
           let floatingTargetFrame,
           shouldApplyFloatingCreateFrameImmediately(for: trackedEntry.workspaceId)
        {
            scheduleFloatingCreateFrameApplication(
                floatingTargetFrame,
                token: trackedToken,
                pid: trackedEntry.pid,
                windowId: trackedEntry.windowId,
                workspaceId: trackedEntry.workspaceId
            )
        } else {
            scheduleAXContextWarmup(for: trackedEntry.pid)
        }
        if shouldActivateFloatingCreate {
            controller.windowActionHandler.raiseFloatingWindow(trackedToken)
        }
        if candidate.requiresPostCreateLifecycleVerification {
            schedulePostCreateLifecycleVerification(for: trackedToken)
        }

        controller.layoutRefreshController.requestRefresh(
            reason: .axWindowCreated,
            affectedWorkspaceIds: [trackedEntry.workspaceId]
        )
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(trackedEntry.pid)])
    }

    private func shouldActivateFloatingCreate(
        _ candidate: PreparedCreate,
        trackedEntry: WindowModel.Entry
    ) -> Bool {
        guard trackedEntry.mode == .floating else { return false }

        // WindowServer transient floating surfaces are native menus/popovers/contextual UI.
        // They are safe to observe for lifecycle bookkeeping, but forcing an AX focus/raise
        // or immediate frame write dismisses the menu in apps such as Telegram and Dock (#104).
        return !candidate.replacementMetadata.transientWindowServerEvidence
    }

    private func shouldApplyFloatingCreateFrameImmediately(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            return false
        }
        return controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId
    }

    private func scheduleAXContextWarmup(for pid: pid_t) {
        if let axContextWarmupHandlerForTests {
            axContextWarmupHandlerForTests(pid)
            return
        }
        Task { @MainActor [weak self] in
            await self?.warmAXContextIfNeeded(for: pid)
        }
    }

    private func warmAXContextIfNeeded(for pid: pid_t) async {
        guard let controller,
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return
        }
        _ = await controller.axManager.windowsForApp(app)
    }

    private func schedulePostCreateLifecycleVerification(for token: WindowToken) {
        pendingPostCreateLifecycleVerificationTasks[token]?.cancel()
        let task = Task { @MainActor [weak self] in
            defer { self?.pendingPostCreateLifecycleVerificationTasks[token] = nil }
            try? await Task.sleep(for: Self.postCreateLifecycleVerificationDelay)
            guard !Task.isCancelled,
                  let self,
                  let controller = self.controller,
                  controller.workspaceManager.entry(for: token) != nil,
                  let windowId = UInt32(exactly: token.windowId),
                  self.resolveWindowInfo(windowId) == nil
            else {
                return
            }
            await self.warmAXContextIfNeeded(for: token.pid)
            guard !Task.isCancelled,
                  controller.workspaceManager.entry(for: token) != nil,
                  self.resolveWindowInfo(windowId) == nil
            else {
                return
            }
            AXWindowService.invalidateCachedTitle(windowId: windowId)
            self.cancelWindowStabilizationRetry(for: token)
            self.handleRemoved(token: token)
        }
        pendingPostCreateLifecycleVerificationTasks[token] = task
    }

    private func cancelPostCreateLifecycleVerification(for token: WindowToken) {
        pendingPostCreateLifecycleVerificationTasks[token]?.cancel()
        pendingPostCreateLifecycleVerificationTasks[token] = nil
    }

    private func scheduleDestroyLivenessVerification(for token: WindowToken) {
        pendingDestroyLivenessVerificationTasks[token]?.cancel()
        let task = Task { @MainActor [weak self] in
            defer { self?.pendingDestroyLivenessVerificationTasks[token] = nil }
            try? await Task.sleep(for: Self.postCreateLifecycleVerificationDelay)
            guard !Task.isCancelled,
                  let self,
                  let controller = self.controller,
                  controller.workspaceManager.entry(for: token) != nil,
                  let windowId = UInt32(exactly: token.windowId)
            else {
                return
            }
            let windowServerAlive = self.resolveWindowInfo(windowId)?.pid == token.pid
            let axEnumerationSucceededAndMissingToken: Bool
            if windowServerAlive {
                let axEnumeration = await controller.axManager.windowEnumerationForPID(token.pid)
                switch axEnumeration {
                case .success(let windows):
                    axEnumerationSucceededAndMissingToken = !windows.contains { _, pid, enumeratedWindowId in
                        pid == token.pid && enumeratedWindowId == token.windowId
                    }
                case .failed:
                    axEnumerationSucceededAndMissingToken = false
                }
            } else {
                axEnumerationSucceededAndMissingToken = false
            }
            guard !Task.isCancelled,
                  controller.workspaceManager.entry(for: token) != nil,
                  (!windowServerAlive || axEnumerationSucceededAndMissingToken)
            else {
                return
            }
            AXWindowService.invalidateCachedTitle(windowId: windowId)
            self.handleRemoved(token: token)
        }
        pendingDestroyLivenessVerificationTasks[token] = task
    }

    private func cancelDestroyLivenessVerification(for token: WindowToken) {
        pendingDestroyLivenessVerificationTasks[token]?.cancel()
        pendingDestroyLivenessVerificationTasks[token] = nil
    }

    private func resetLifecycleVerificationState() {
        for (_, task) in pendingPostCreateLifecycleVerificationTasks {
            task.cancel()
        }
        pendingPostCreateLifecycleVerificationTasks.removeAll()
        for (_, task) in pendingDestroyLivenessVerificationTasks {
            task.cancel()
        }
        pendingDestroyLivenessVerificationTasks.removeAll()
    }

    private func scheduleFloatingCreateFrameApplication(
        _ targetFrame: CGRect,
        token: WindowToken,
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        let canApplySynchronously = controller.axManager.hasContext(for: pid)
            || controller.axManager.usesFrameApplyOverrideForTests

        if canApplySynchronously {
            applyFloatingCreateFrame(
                targetFrame,
                token: token,
                pid: pid,
                windowId: windowId,
                workspaceId: workspaceId
            )
            if controller.axManager.recentFrameWriteFailure(for: windowId) == .contextUnavailable {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.warmAXContextIfNeeded(for: pid)
                    self.applyFloatingCreateFrame(
                        targetFrame,
                        token: token,
                        pid: pid,
                        windowId: windowId,
                        workspaceId: workspaceId
                    )
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.warmAXContextIfNeeded(for: pid)
            self.applyFloatingCreateFrame(
                targetFrame,
                token: token,
                pid: pid,
                windowId: windowId,
                workspaceId: workspaceId
            )
            if self.controller?.axManager.recentFrameWriteFailure(for: windowId) == .contextUnavailable {
                await self.warmAXContextIfNeeded(for: pid)
                self.applyFloatingCreateFrame(
                    targetFrame,
                    token: token,
                    pid: pid,
                    windowId: windowId,
                    workspaceId: workspaceId
                )
            }
        }
    }

    private func applyFloatingCreateFrame(
        _ targetFrame: CGRect,
        token: WindowToken,
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              controller.workspaceManager.entry(for: token) != nil,
              shouldApplyFloatingCreateFrameImmediately(for: workspaceId)
        else {
            return
        }

        controller.axManager.forceApplyNextFrame(for: windowId)
        controller.axManager.applyFramesParallel([(pid, windowId, targetFrame)])
    }

    func handleRemoved(pid: pid_t, winId: Int) {
        guard let windowId = UInt32(exactly: winId) else { return }
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        cancelCreatedWindowRetry(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        handleWindowDestroyed(windowId: windowId, pidHint: pid, verifyWindowServerLiveness: true)
    }

    func handleRemoved(token: WindowToken) {
        guard let controller else { return }
        recordRecentSameAppWindowClose(pid: token.pid)
        let entry = controller.workspaceManager.entry(for: token)
        let affectedWorkspaceId = entry?.workspaceId
        let confirmedTokenBeforeRemoval = controller.workspaceManager.confirmedManagedFocusToken
        let recoveryContextBeforeRemoval = activeWindowCloseFocusRecoveryContext()
        let closePrecursor = focusedWindowLossClosePrecursor(for: token.pid)

        cancelPostCreateLifecycleVerification(for: token)
        cancelDestroyLivenessVerification(for: token)
        controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)
        if handleNativeFullscreenDestroy(token) {
            return
        }

        clearManagedFocusState(matching: token, workspaceId: affectedWorkspaceId)
        controller.nativeFullscreenPlaceholderManager.remove(token)

        let isAffectedWorkspaceActive = affectedWorkspaceId.flatMap { workspaceId in
            controller.workspaceManager.monitorId(for: workspaceId).map { monitorId in
                controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
            }
        } ?? false
        let removedMatchesConfirmedFocus = token == confirmedTokenBeforeRemoval
        let removedMatchesActiveRecoveryToken = recoveryContextBeforeRemoval?.preservedToken == token
        let removedMatchesFocusedWindowLossPrecursor = isAffectedWorkspaceActive
            && (closePrecursor?.preservedToken == token
                || closePrecursor?.workspaceId == affectedWorkspaceId)
        let shouldRecoverFocus = removedMatchesConfirmedFocus
            || removedMatchesActiveRecoveryToken
            || removedMatchesFocusedWindowLossPrecursor
        if let workspaceId = affectedWorkspaceId {
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: workspaceId,
                reason: "close_recovery_removed_window_focus_recovery",
                details: [
                    "removedToken=\(token)",
                    "confirmedBeforeRemoval=\(confirmedTokenBeforeRemoval.map(String.init(describing:)) ?? "nil")",
                    "activeRecoveryWorkspace=\(recoveryContextBeforeRemoval?.workspaceId.uuidString ?? "nil")",
                    "activeRecoveryPreservedToken=\(recoveryContextBeforeRemoval?.preservedToken.map(String.init(describing:)) ?? "nil")",
                    "precursorWorkspace=\(closePrecursor?.workspaceId.uuidString ?? "nil")",
                    "precursorPreservedToken=\(closePrecursor?.preservedToken.map(String.init(describing:)) ?? "nil")",
                    "matchesConfirmed=\(removedMatchesConfirmedFocus)",
                    "matchesActiveRecoveryToken=\(removedMatchesActiveRecoveryToken)",
                    "matchesFocusedWindowLossPrecursor=\(removedMatchesFocusedWindowLossPrecursor)",
                    "affectedWorkspaceActive=\(isAffectedWorkspaceActive)",
                    "shouldRecoverFocus=\(shouldRecoverFocus)"
                ]
            )
        }
        if shouldRecoverFocus, let workspaceId = affectedWorkspaceId {
            beginWindowCloseFocusRecovery(
                in: workspaceId,
                suppressingPid: token.pid,
                preservedToken: token,
                reason: "tracked_destroy"
            )
        }

        if let entry,
           let wsId = affectedWorkspaceId,
           let monitor = controller.workspaceManager.monitor(for: wsId),
           controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
        {
            let shouldAnimate = if let engine = controller.niriEngine,
                                   let windowNode = engine.findNode(for: token)
            {
                !windowNode.isHiddenInTabbedMode
            } else {
                true
            }
            if shouldAnimate {
                controller.layoutRefreshController.startWindowCloseAnimation(
                    entry: entry,
                    monitor: monitor
                )
            }
        }

        var oldFrames: [WindowToken: CGRect] = [:]
        var removedNodeId: NodeId?
        if let wsId = affectedWorkspaceId, let engine = controller.niriEngine {
            oldFrames = engine.captureWindowFrames(in: wsId)
            removedNodeId = engine.findNode(for: token)?.id
        }

        controller.cleanupScratchpadWindowResourcesIfNeeded(for: token)
        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        controller.clearManualWindowOverride(for: token)
        controller.focusBorderController.clear(matching: token)

        if let wsId = affectedWorkspaceId {
            controller.layoutRefreshController.requestWindowRemoval(
                workspaceId: wsId,
                removedNodeId: removedNodeId,
                niriOldFrames: oldFrames,
                shouldRecoverFocus: shouldRecoverFocus
            )
        }
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
    }

    private func beginWindowCloseFocusRecovery(
        in workspaceId: WorkspaceDescriptor.ID,
        suppressingPid: pid_t? = nil,
        preservedToken: WindowToken? = nil,
        reason: String = "tracked_destroy"
    ) {
        guard let controller else { return }
        guard let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
              controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
        else {
            endWindowCloseFocusRecovery()
            return
        }

        windowCloseFocusRecoveryContext = WindowCloseFocusRecoveryContext(
            workspaceId: workspaceId,
            expiresAt: Date().addingTimeInterval(Self.windowCloseFocusRecoveryDuration),
            suppressedActivationPid: suppressingPid,
            preservedToken: preservedToken
        )
        controller.diagnostics.recordRuntimeViewportTrace(
            workspaceId: workspaceId,
            reason: "close_recovery_begin",
            details: [
                "caller=\(reason)",
                "suppressedPid=\(suppressingPid.map(String.init) ?? "nil")",
                "preservedToken=\(preservedToken.map(String.init(describing:)) ?? "nil")"
            ]
        )
        controller.focusPolicyEngine.beginLease(
            owner: .windowCloseFocusRecovery,
            reason: "window_close_focus_recovery",
            suppressesFocusFollowsMouse: true,
            duration: Self.windowCloseFocusRecoveryDuration
        )
    }

    private func activeWindowCloseFocusRecoveryContext() -> WindowCloseFocusRecoveryContext? {
        guard let context = windowCloseFocusRecoveryContext else { return nil }
        guard context.expiresAt > Date() else {
            endWindowCloseFocusRecovery()
            return nil
        }
        return context
    }

    private func activeWindowCloseFocusRecoveryWorkspaceId() -> WorkspaceDescriptor.ID? {
        activeWindowCloseFocusRecoveryContext()?.workspaceId
    }

    private func endWindowCloseFocusRecovery(matching workspaceId: WorkspaceDescriptor.ID? = nil) {
        if let workspaceId, windowCloseFocusRecoveryContext?.workspaceId != workspaceId {
            return
        }
        guard windowCloseFocusRecoveryContext != nil else { return }
        windowCloseFocusRecoveryContext = nil
        controller?.focusPolicyEngine.endLease(owner: .windowCloseFocusRecovery)
    }

    private func armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded(
        pid: pid_t,
        source: ActivationEventSource,
        preservedToken: WindowToken? = nil
    ) {
        guard source == .focusedWindowChanged,
              let controller
        else { return }

        if let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
           focusedToken.pid == pid,
           let workspaceId = controller.workspaceManager.workspace(for: focusedToken)
        {
            beginWindowCloseFocusRecovery(
                in: workspaceId,
                suppressingPid: pid,
                preservedToken: preservedToken ?? focusedToken,
                reason: "focused_window_nil"
            )
            return
        }

        // Quick-terminal overlays can report AXFocusedWindowChanged(window=nil)
        // for the overlay app, not for the managed window underneath. On close,
        // the managed focus token may already have been cleared by the earlier
        // non-managed overlay focus, so anchor recovery to the current
        // interaction workspace before macOS re-focuses an older managed window
        // on another visible monitor.
        guard controller.workspaceManager.isNonManagedFocusActive,
              let workspaceId = controller.interactionWorkspace()?.id
        else { return }

        beginWindowCloseFocusRecovery(
            in: workspaceId,
            suppressingPid: pid,
            preservedToken: preservedToken ?? controller.workspaceManager.confirmedManagedFocusToken,
            reason: "focused_window_nil"
        )
    }

    private func armWindowCloseFocusRecoveryForFocusedAppEvent(pid: pid_t) {
        guard let controller,
              let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
              focusedToken.pid == pid,
              let workspaceId = controller.workspaceManager.workspace(for: focusedToken)
        else {
            return
        }
        beginWindowCloseFocusRecovery(in: workspaceId, suppressingPid: pid, reason: "auxiliary_destroy")
    }

    func handleManagedWindowHiddenStateChanged(
        token: WindowToken,
        previousState: WindowModel.HiddenState?,
        newState: WindowModel.HiddenState?
    ) {
        guard previousState != newState,
              newState?.workspaceInactive == true,
              let controller,
              controller.workspaceManager.confirmedManagedFocusToken == token,
              let workspaceId = controller.workspaceManager.workspace(for: token),
              let monitorId = controller.workspaceManager.monitorId(for: workspaceId)
        else {
            return
        }

        if controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId {
            beginWindowCloseFocusRecovery(
                in: workspaceId,
                suppressingPid: token.pid,
                preservedToken: token,
                reason: "hidden_workspace_inactive"
            )
        } else {
            clearManagedFocusState(matching: token, workspaceId: workspaceId)
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.focusBorderController.clear()
        }
    }

    private func shouldSuppressObservedActivationDuringWindowCloseRecovery(
        entry observedEntry: WindowModel.Entry,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource
    ) -> Bool {
        guard let recoveryContext = activeWindowCloseFocusRecoveryContext() else {
            return false
        }
        let recoveryWorkspaceId = recoveryContext.workspaceId

        if case .matchesActiveRequest = requestDisposition {
            return false
        }

        if let suppressedPid = recoveryContext.suppressedActivationPid,
           observedEntry.pid == suppressedPid,
           observedEntry.token != recoveryContext.preservedToken
        {
            return true
        }

        if recoveryWorkspaceId != observedEntry.workspaceId {
            return true
        }

        guard source == .workspaceDidActivateApplication,
              case .unrelatedNoRequest = requestDisposition,
              let focusedToken = controller?.workspaceManager.confirmedManagedFocusToken,
              focusedToken != observedEntry.token,
              controller?.workspaceManager.workspace(for: focusedToken) == recoveryWorkspaceId
        else {
            return false
        }

        return true
    }

    private func stableRecoveryFocusTarget(
        context: WindowCloseFocusRecoveryContext,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (token: WindowToken, reason: String)? {
        guard context.workspaceId == workspaceId,
              let controller
        else {
            return nil
        }

        if let preservedToken = context.preservedToken,
           controller.workspaceManager.entry(for: preservedToken) != nil,
           controller.workspaceManager.workspace(for: preservedToken) == workspaceId
        {
            return (preservedToken, "preserved")
        }

        guard let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            return nil
        }
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = controller.gapSize(for: monitor)
        guard let nearestToken = engine.activeTileTokenNearestViewport(
            in: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps
        ),
            controller.workspaceManager.entry(for: nearestToken) != nil,
            controller.workspaceManager.workspace(for: nearestToken) == workspaceId
        else {
            return nil
        }
        return (nearestToken, "nearest")
    }

    private func redirectToStableRecoveryFocusIfNeeded(
        observedEntry: WindowModel.Entry,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let context = activeWindowCloseFocusRecoveryContext(),
              context.workspaceId == workspaceId
        else {
            return false
        }

        guard let target = stableRecoveryFocusTarget(context: context, workspaceId: workspaceId) else {
            controller?.diagnostics.recordRuntimeViewportTrace(
                workspaceId: workspaceId,
                reason: "close_recovery_stable_target",
                details: [
                    "observedToken=\(observedEntry.token)",
                    "targetToken=nil",
                    "reason=fallback"
                ]
            )
            return false
        }

        controller?.diagnostics.recordRuntimeViewportTrace(
            workspaceId: workspaceId,
            reason: "close_recovery_stable_target",
            details: [
                "observedToken=\(observedEntry.token)",
                "targetToken=\(target.token)",
                "reason=\(target.reason)"
            ]
        )
        guard target.token != observedEntry.token else { return false }
        controller?.focusWindow(target.token, reason: .closeRecoveryStableRedirect)
        return true
    }

    private func stableViewportFocusTarget(
        workspaceId: WorkspaceDescriptor.ID,
        excluding excludedToken: WindowToken? = nil
    ) -> WindowToken? {
        guard let controller,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            return nil
        }
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        return engine.activeTileTokensNearestViewport(
            in: workspaceId,
            state: state,
            workingFrame: controller.insetWorkingFrame(for: monitor),
            gaps: controller.gapSize(for: monitor)
        ).first { candidate in
            guard candidate != excludedToken,
                  let entry = controller.workspaceManager.entry(for: candidate),
                  controller.workspaceManager.workspace(for: candidate) == workspaceId
            else {
                return false
            }
            return observedFrame(for: entry) != nil
        }
    }

    private func previousSameAppFocusDisappearedSignal(
        for observedEntry: WindowModel.Entry,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let previousToken = controller.workspaceManager.confirmedManagedFocusToken,
              previousToken.pid == observedEntry.pid,
              previousToken != observedEntry.token,
              controller.workspaceManager.workspace(for: previousToken) == workspaceId,
              let previousEntry = controller.workspaceManager.entry(for: previousToken)
        else {
            return false
        }
        return observedFrame(for: previousEntry) == nil
    }

    private func selectedSameAppFocusDisappearedSignal(
        for observedEntry: WindowModel.Entry,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let engine = controller.niriEngine,
              let selectedNodeId = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
              let selectedWindow = engine.findNode(by: selectedNodeId) as? NiriWindow,
              selectedWindow.token.pid == observedEntry.pid,
              selectedWindow.token != observedEntry.token,
              let selectedEntry = controller.workspaceManager.entry(for: selectedWindow.token),
              selectedEntry.workspaceId == workspaceId
        else {
            return false
        }
        return observedFrame(for: selectedEntry) == nil
    }

    private func hasSameAppOverlayRecoverySignal(for entry: WindowModel
        .Entry) -> (recentNonManaged: Bool, overlayVisible: Bool)
    {
        let recentNonManaged = hasRecentNonManagedFocus(for: entry.pid)
        let overlayVisible = hasVisibleSamePidOverlayWindow(for: entry)
        return (recentNonManaged, overlayVisible)
    }

    private struct SameAppCloseRecoveryViewportPins {
        let closeRecoveryPin: Bool
        let recentSameAppClosePin: Bool
        let overlayRecoveryPin: Bool
        let selectedSameAppFocusDisappearedPin: Bool
        let shouldPin: Bool
    }

    private func sameAppCloseRecoveryViewportPins(
        entry: WindowModel.Entry,
        wsId: WorkspaceDescriptor.ID,
        selectedSameAppFocusDisappearedBeforeConfirm: Bool,
        overlaySignal: (recentNonManaged: Bool, overlayVisible: Bool)
    ) -> SameAppCloseRecoveryViewportPins {
        let closeRecoveryPin = activeWindowCloseFocusRecoveryContext()?.workspaceId == wsId
        let outsideActiveCloseRecovery = activeWindowCloseFocusRecoveryWorkspaceId() == nil
        let recentSameAppClosePin = outsideActiveCloseRecovery
            && hasRecentSameAppWindowClose(for: entry.pid)
        let overlayRecoveryPin = outsideActiveCloseRecovery
            && (overlaySignal.recentNonManaged || overlaySignal.overlayVisible)
        let selectedSameAppFocusDisappearedPin = outsideActiveCloseRecovery
            && isWithinSameAppCloseRecoveryWindow(pid: entry.pid)
            && (selectedSameAppFocusDisappearedBeforeConfirm
                || selectedSameAppFocusDisappearedSignal(for: entry, workspaceId: wsId))
        let shouldPin = closeRecoveryPin
            || recentSameAppClosePin
            || overlayRecoveryPin
            || selectedSameAppFocusDisappearedPin
        return .init(
            closeRecoveryPin: closeRecoveryPin,
            recentSameAppClosePin: recentSameAppClosePin,
            overlayRecoveryPin: overlayRecoveryPin,
            selectedSameAppFocusDisappearedPin: selectedSameAppFocusDisappearedPin,
            shouldPin: shouldPin
        )
    }

    private func shouldSuppressSameAppParkedFocusBeforeConfirm(
        observedEntry: WindowModel.Entry,
        workspaceId: WorkspaceDescriptor.ID,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource
    ) -> Bool {
        guard source == .focusedWindowChanged,
              activeWindowCloseFocusRecoveryWorkspaceId() == nil,
              !isEntryOnScreen(observedEntry)
        else { return false }
        let signal = hasSameAppOverlayRecoverySignal(for: observedEntry)
        guard signal.recentNonManaged || signal.overlayVisible else { return false }
        guard case .unrelatedNoRequest = requestDisposition,
              let previousToken = controller?.workspaceManager.confirmedManagedFocusToken,
              previousToken.pid == observedEntry.pid,
              previousToken != observedEntry.token,
              controller?.workspaceManager.workspace(for: previousToken) == workspaceId
        else {
            return false
        }
        controller?.diagnostics.recordRuntimeViewportTrace(
            workspaceId: workspaceId,
            reason: "same_app_parked_focus_suppressed",
            details: [
                "observedToken=\(observedEntry.token)",
                "previousToken=\(previousToken)",
                "requestDisposition=\(requestDisposition)",
                "recentNonManaged=\(signal.recentNonManaged)",
                "overlayVisible=\(signal.overlayVisible)"
            ]
        )
        return true
    }

    private enum StableRecoveryRedirectPhase {
        case preconfirm
        case overlay

        var traceReason: String {
            switch self {
            case .preconfirm: "close_recovery_preconfirm_stable_target"
            case .overlay: "close_recovery_overlay_stable_target"
            }
        }

        var focusReason: FocusWindowReason {
            switch self {
            case .preconfirm: .closeRecoveryPreconfirmStableRedirect
            case .overlay: .overlayStableRecoveryRedirect
            }
        }
    }

    private func redirectToStableSameAppRecoveryFocusIfNeeded(
        observedEntry: WindowModel.Entry,
        workspaceId: WorkspaceDescriptor.ID,
        phase: StableRecoveryRedirectPhase
    ) -> Bool {
        guard activeWindowCloseFocusRecoveryWorkspaceId() == nil else { return false }
        let signal = hasSameAppOverlayRecoverySignal(for: observedEntry)
        let recentSameAppClose = hasRecentSameAppWindowClose(for: observedEntry.pid)
        let previousSameAppFocusDisappeared = previousSameAppFocusDisappearedSignal(
            for: observedEntry,
            workspaceId: workspaceId
        )
        let selectedSameAppFocusDisappeared = selectedSameAppFocusDisappearedSignal(
            for: observedEntry,
            workspaceId: workspaceId
        )
        let hasOverlayRecoveryEvidence = signal.recentNonManaged || signal.overlayVisible
        let shouldRedirect = switch phase {
        case .preconfirm:
            hasOverlayRecoveryEvidence
                && (previousSameAppFocusDisappeared || selectedSameAppFocusDisappeared)
        case .overlay:
            hasOverlayRecoveryEvidence
                || (recentSameAppClose
                    && (previousSameAppFocusDisappeared || selectedSameAppFocusDisappeared))
        }
        guard shouldRedirect else { return false }
        let target = stableViewportFocusTarget(workspaceId: workspaceId, excluding: observedEntry.token)
        controller?.diagnostics.recordRuntimeViewportTrace(
            workspaceId: workspaceId,
            reason: phase.traceReason,
            details: [
                "observedToken=\(observedEntry.token)",
                "targetToken=\(target.map(String.init(describing:)) ?? "nil")",
                "recentSameAppClose=\(recentSameAppClose)",
                "recentNonManaged=\(signal.recentNonManaged)",
                "overlayVisible=\(signal.overlayVisible)",
                "previousSameAppFocusDisappeared=\(previousSameAppFocusDisappeared)",
                "selectedSameAppFocusDisappeared=\(selectedSameAppFocusDisappeared)"
            ]
        )
        guard let target, target != observedEntry.token else { return false }
        controller?.focusWindow(target, reason: phase.focusReason)
        return true
    }

    private func redirectToStableCloseSuccessorFocusBeforeConfirmIfNeeded(
        observedEntry: WindowModel.Entry,
        workspaceId: WorkspaceDescriptor.ID,
        source: ActivationEventSource
    ) -> Bool {
        guard source == .focusedWindowChanged else { return false }
        return redirectToStableSameAppRecoveryFocusIfNeeded(
            observedEntry: observedEntry,
            workspaceId: workspaceId,
            phase: .preconfirm
        )
    }

    private func redirectToStableOverlayRecoveryFocusIfNeeded(
        observedEntry: WindowModel.Entry,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        redirectToStableSameAppRecoveryFocusIfNeeded(
            observedEntry: observedEntry,
            workspaceId: workspaceId,
            phase: .overlay
        )
    }

    private func shouldSuppressManagedActivationWhileNonManagedFocusAnchored(
        entry observedEntry: WindowModel.Entry,
        requestDisposition: ActivationRequestDisposition
    ) -> Bool {
        guard case .unrelatedNoRequest = requestDisposition,
              let controller,
              let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
              focusedToken != observedEntry.token,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              let focusedMonitorId = controller.workspaceManager.monitorId(for: focusedEntry.workspaceId),
              controller.workspaceManager.activeWorkspace(on: focusedMonitorId)?.id == focusedEntry.workspaceId
        else {
            return false
        }

        let overlayFocusIsActive = controller.workspaceManager.isNonManagedFocusActive
            || hasVisibleSamePidOverlayWindow(for: observedEntry)
        guard overlayFocusIsActive else { return false }

        // While an unmanaged overlay (for example Ghostty Quick Terminal) owns
        // native focus, macOS may report the app's regular managed window as the
        // focused AX window. The overlay should not move Nehir's managed
        // interaction/focus anchor away from the window the user was using before
        // the overlay appeared, even when both windows are on the same workspace.
        return true
    }

    private func hasVisibleSamePidOverlayWindow(for entry: WindowModel.Entry) -> Bool {
        guard let windowId = UInt32(exactly: entry.windowId) else { return false }
        let currentNonManagedFocusToken = controller?.currentBorderTarget().flatMap { target in
            !target.isManaged ? target.token : nil
        }
        return SkyLight.shared.queryAllVisibleWindows().contains { info in
            guard info.pid == entry.pid,
                  info.id != windowId,
                  info.level != 0,
                  !info.frame.isNull,
                  !info.frame.isEmpty
            else {
                return false
            }

            let token = WindowToken(pid: entry.pid, windowId: Int(info.id))
            if currentNonManagedFocusToken == token {
                return true
            }
            return isKnownSamePidOverlayWindow(info, pid: entry.pid)
        }
    }

    private func isKnownSamePidOverlayWindow(_ info: WindowServerInfo, pid: pid_t) -> Bool {
        guard let controller else { return false }
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(info.id))
        let facts = managedReplacementFacts(
            for: axRef,
            pid: pid,
            bundleId: resolveBundleId(pid),
            windowInfo: info,
            includeTitle: false
        )
        let decision = controller.windowRuleEngine.decision(
            for: facts,
            token: WindowToken(pid: pid, windowId: Int(info.id)),
            appFullscreen: false
        )
        if case let .builtInRule(name) = decision.source {
            return name == "ghosttyQuickTerminalOverlay"
                || name == "cleanShotRecordingOverlay"
                || name == "systemTextInputPanel"
        }
        return false
    }

    private func recordCloseRecoveryActivationGate(
        entry observedEntry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        decision: String
    ) {
        controller?.diagnostics.recordRuntimeViewportTrace(
            workspaceId: observedEntry.workspaceId,
            reason: "close_recovery_activation_gate",
            details: [
                "token=\(observedEntry.token)",
                "isWorkspaceActive=\(isWorkspaceActive)",
                "source=\(source.rawValue)",
                "origin=\(origin.rawValue)",
                "requestDisposition=\(requestDisposition)",
                "activeRecoveryWorkspace=\(activeWindowCloseFocusRecoveryContext()?.workspaceId.uuidString ?? "nil")",
                "recentSameAppClose=\(hasRecentSameAppWindowClose(for: observedEntry.pid))",
                "recentNonManagedFocus=\(hasRecentNonManagedFocus(for: observedEntry.pid))",
                "focusedWindowLossPrecursor=\(focusedWindowLossClosePrecursor(for: observedEntry.pid)?.workspaceId.uuidString ?? "nil")",
                "decision=\(decision)"
            ]
        )
    }

    /// Native app activation can lead the observable quick-terminal close signal.
    ///
    /// In the close sequence that caused workspace jumps, macOS first reported a
    /// `workspaceDidActivateApplication` for an older managed window on an
    /// inactive workspace, then delivered the quick-terminal hide/destroy signal
    /// a few milliseconds later. Accepting that first activation immediately
    /// scrolls or switches away before `windowCloseFocusRecovery` has a chance to
    /// arm. Defer exactly that ambiguous pre-close shape briefly, then retry it:
    /// if close recovery armed during the delay, the normal recovery suppression
    /// handles it; if not, the retry proceeds as a real user/native activation.
    private func shouldDeferInactiveNativeActivationBeforeCloseRecovery(
        entry observedEntry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard origin == .external,
              source == .workspaceDidActivateApplication,
              case .unrelatedNoRequest = requestDisposition,
              !isWorkspaceActive,
              activeWindowCloseFocusRecoveryWorkspaceId() == nil,
              let controller,
              let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
              focusedToken != observedEntry.token,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              let focusedMonitorId = controller.workspaceManager.monitorId(for: focusedEntry.workspaceId),
              controller.workspaceManager.activeWorkspace(on: focusedMonitorId)?.id == focusedEntry.workspaceId
        else {
            return false
        }

        guard !deferredInactiveNativeActivationTokens.contains(observedEntry.token) else {
            return true
        }

        deferredInactiveNativeActivationTokens.insert(observedEntry.token)
        Task { [weak self, token = observedEntry.token, pid = observedEntry.pid, source] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.deferredInactiveNativeActivationTokens.remove(token)
                self.handleAppActivation(pid: pid, source: source, origin: .retry)
            }
        }
        return true
    }

    private func shouldDeferSameAppInactiveNativeActivationBeforeCloseRecovery(
        entry observedEntry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard origin == .external,
              source == .workspaceDidActivateApplication || source == .focusedWindowChanged,
              case .unrelatedNoRequest = requestDisposition,
              !isWorkspaceActive,
              activeWindowCloseFocusRecoveryWorkspaceId() == nil,
              let controller
        else {
            return false
        }

        let precursor = focusedWindowLossClosePrecursor(for: observedEntry.pid)
        let samePidActiveFocusedToken = controller.workspaceManager.confirmedManagedFocusToken
            .flatMap { focusedToken -> WindowToken? in
                guard focusedToken != observedEntry.token,
                      focusedToken.pid == observedEntry.pid,
                      let focusedWorkspaceId = controller.workspaceManager.workspace(for: focusedToken),
                      let focusedMonitorId = controller.workspaceManager.monitorId(for: focusedWorkspaceId),
                      controller.workspaceManager.activeWorkspace(on: focusedMonitorId)?.id == focusedWorkspaceId
                else {
                    return nil
                }
                return focusedToken
            }
        guard precursor != nil || samePidActiveFocusedToken != nil else {
            return false
        }

        controller.diagnostics.recordRuntimeViewportTrace(
            workspaceId: observedEntry.workspaceId,
            reason: "close_recovery_inactive_successor_deferred",
            details: [
                "token=\(observedEntry.token)",
                "source=\(source.rawValue)",
                "origin=\(origin.rawValue)",
                "requestDisposition=\(requestDisposition)",
                "activeRecoveryWorkspace=\(activeWindowCloseFocusRecoveryContext()?.workspaceId.uuidString ?? "nil")",
                "focusedWindowLossPrecursor=\(precursor?.workspaceId.uuidString ?? "nil")",
                "samePidActiveFocusedToken=\(samePidActiveFocusedToken.map(String.init(describing:)) ?? "nil")",
                "recentSameAppClose=\(hasRecentSameAppWindowClose(for: observedEntry.pid))",
                "recentNonManagedFocus=\(hasRecentNonManagedFocus(for: observedEntry.pid))"
            ]
        )

        guard !deferredSameAppActiveNativeActivationTokens.contains(observedEntry.token) else {
            return true
        }

        deferredSameAppActiveNativeActivationTokens.insert(observedEntry.token)
        Task { [weak self, token = observedEntry.token, pid = observedEntry.pid, source] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.deferredSameAppActiveNativeActivationTokens.remove(token)
                self.handleAppActivation(pid: pid, source: source, origin: .retry)
            }
        }
        return true
    }

    private func shouldDeferSameAppActiveNativeActivationBeforeCloseRecovery(
        entry observedEntry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard origin == .external,
              source == .workspaceDidActivateApplication || source == .focusedWindowChanged,
              isWorkspaceActive,
              activeWindowCloseFocusRecoveryWorkspaceId() == nil
        else {
            return false
        }

        guard case .unrelatedNoRequest = requestDisposition else {
            return false
        }

        let recentNonManaged = hasRecentNonManagedFocus(for: observedEntry.pid)
        let overlayVisible = hasVisibleSamePidOverlayWindow(for: observedEntry)
        guard recentNonManaged || overlayVisible else { return false }

        controller?.diagnostics.recordRuntimeViewportTrace(
            workspaceId: observedEntry.workspaceId,
            reason: "close_recovery_predefer",
            details: [
                "token=\(observedEntry.token)",
                "source=\(source.rawValue)",
                "requestDisposition=\(requestDisposition)",
                "recentNonManaged=\(recentNonManaged)",
                "overlayVisible=\(overlayVisible)"
            ]
        )

        guard !deferredSameAppActiveNativeActivationTokens.contains(observedEntry.token) else {
            return true
        }

        deferredSameAppActiveNativeActivationTokens.insert(observedEntry.token)
        Task { [weak self, token = observedEntry.token, pid = observedEntry.pid, source] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.deferredSameAppActiveNativeActivationTokens.remove(token)
                self.handleAppActivation(pid: pid, source: source, origin: .retry)
            }
        }
        return true
    }

    private func shouldSuppressHiddenInactiveStickyActivation(
        entry observedEntry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource
    ) -> Bool {
        guard !isWorkspaceActive,
              case .unrelatedNoRequest = requestDisposition,
              source == .workspaceDidActivateApplication || source == .focusedWindowChanged,
              observedEntry.visibility == .hiddenWorkspaceInactive,
              let controller,
              controller.workspaceManager.hasStickyWindowSource(observedEntry.token),
              !controller.workspaceManager.isStickyWindow(observedEntry.token)
        else {
            return false
        }

        // A manually unstuck PiP keeps its automatic sticky source so commands
        // can still target/toggle it, but it should behave like a normal
        // inactive-workspace window while unstuck. Some native PiP surfaces
        // report app activation/focus again immediately after Nehir parks them;
        // accepting that unrelated activation switches back to the PiP's
        // workspace and reveals the window. Suppress that app-internal churn
        // unless there is an explicit managed focus request.
        return true
    }

    private func shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery(
        entry observedEntry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource
    ) -> Bool {
        guard case .unrelatedNoRequest = requestDisposition else { return false }
        guard let controller else { return false }

        // This guard exists only to absorb the successor-focus churn macOS emits
        // when one of the app's own windows *closes* (it re-focuses another of
        // the app's windows, possibly on an inactive workspace). It must not fire
        // for an ordinary same-app focus switch with no close — that is a
        // legitimate move to another of the app's windows and should reveal its
        // workspace. Gate on a recent same-app window close.
        guard hasRecentSameAppWindowClose(for: observedEntry.pid) else {
            recordCloseRecoveryActivationGate(
                entry: observedEntry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: .external,
                decision: "allow reason=no_recent_same_app_close"
            )
            return false
        }

        if let currentTarget = controller.currentBorderTarget(),
           currentTarget.token != observedEntry.token,
           currentTarget.pid == observedEntry.pid
        {
            if !currentTarget.isManaged {
                controller.diagnostics.recordRuntimeViewportTrace(
                    workspaceId: observedEntry.workspaceId,
                    reason: "close_recovery_inactive_successor_suppressed",
                    details: [
                        "token=\(observedEntry.token)",
                        "currentTarget=\(currentTarget.token)",
                        "reason=unmanaged_current_target"
                    ]
                )
                return true
            }
            let shouldSuppress = !isWorkspaceActive
            recordCloseRecoveryActivationGate(
                entry: observedEntry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: .external,
                decision: shouldSuppress ? "suppress reason=current_target_same_pid" : "allow reason=workspace_active"
            )
            if shouldSuppress {
                controller.diagnostics.recordRuntimeViewportTrace(
                    workspaceId: observedEntry.workspaceId,
                    reason: "close_recovery_inactive_successor_suppressed",
                    details: [
                        "token=\(observedEntry.token)",
                        "currentTarget=\(currentTarget.token)",
                        "reason=current_target_same_pid"
                    ]
                )
            }
            return shouldSuppress
        }

        guard !isWorkspaceActive else { return false }

        // Same-pid confirmed focus on the active workspace anchors suppression:
        // the user is actively working with another window of the same app.
        if let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
           focusedToken != observedEntry.token,
           focusedToken.pid == observedEntry.pid,
           let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
           let focusedMonitorId = controller.workspaceManager.monitorId(for: focusedEntry.workspaceId),
           controller.workspaceManager.activeWorkspace(on: focusedMonitorId)?.id == focusedEntry.workspaceId
        {
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: observedEntry.workspaceId,
                reason: "close_recovery_inactive_successor_suppressed",
                details: [
                    "token=\(observedEntry.token)",
                    "focusedToken=\(focusedToken)",
                    "reason=confirmed_focus_same_pid_active_workspace"
                ]
            )
            return true
        }

        // When the active workspace has no same-pid confirmed managed focus
        // (empty workspace, or a different app is focused), a focusedWindowChanged
        // that resolves to a managed window on an inactive workspace is an
        // app-internal re-focus (quick-terminal toggle, activation churn) — not
        // a user workspace switch. Suppress it to preserve the active workspace.
        // A genuine user switch arrives as workspaceDidActivateApplication (which
        // makes the workspace active first) or with a pending managed request
        // (which is not .unrelatedNoRequest).
        if source == .focusedWindowChanged {
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: observedEntry.workspaceId,
                reason: "close_recovery_inactive_successor_suppressed",
                details: [
                    "token=\(observedEntry.token)",
                    "reason=focused_window_changed_close_successor"
                ]
            )
            return true
        }

        recordCloseRecoveryActivationGate(
            entry: observedEntry,
            isWorkspaceActive: isWorkspaceActive,
            requestDisposition: requestDisposition,
            source: source,
            origin: .external,
            decision: "allow reason=no_suppression_anchor"
        )
        return false
    }

    func handleAppActivation(
        pid: pid_t,
        source: ActivationEventSource = .workspaceDidActivateApplication,
        origin: ActivationCallOrigin = .external
    ) {
        guard let controller else { return }
        guard controller.focusPolicyEngine.evaluate(
            .managedAppActivation(source: source)
        ).allowsFocusChange else {
            return
        }
        recordNiriCreateFocusTrace(
            .init(
                kind: .activationSourceObserved(
                    pid: pid,
                    source: source
                )
            )
        )
        // A genuine app-level switch (Dock, Cmd-Tab, launcher activate()) is a
        // user-intent signal that should still admit the app's window even while
        // non-managed focus is active. Window-level focus churn
        // (.focusedWindowChanged) does not qualify, so only record app
        // activations here.
        if source == .workspaceDidActivateApplication {
            recordRecentAppActivation(pid: pid)
        }
        guard controller.hasStartedServices else { return }

        let activeRequest = controller.focusBridge.activeManagedRequest

        if pid == getpid(), (controller.hasFrontmostOwnedWindow || controller.hasVisibleOwnedWindow) {
            if let activeRequest, activeRequest.token.pid == pid {
                _ = controller.focusBridge.cancelManagedRequest(requestId: activeRequest.requestId)
                cancelActivationRetry(requestId: activeRequest.requestId)
            }
            controller.clearKeyboardFocusTarget(pid: pid)
            _ = controller.workspaceManager.enterNonManagedFocus(
                appFullscreen: false,
                preserveFocusedToken: true
            )
            controller.focusBorderController.clear()
            return
        }

        let axRef = resolveFocusedAXWindowRef(pid: pid)
        let observedToken = axRef.map { WindowToken(pid: pid, windowId: $0.windowId) }
        let isActivationForManagedRequest = observedToken.map { token in
            activeRequest?.token == token
                || controller.focusBridge.recentlyConfirmedManagedRequest(
                    for: token,
                    within: Self.nativeAppSwitchLeaseRequestConfirmationGrace
                )
        } ?? (activeRequest?.token.pid == pid)
        if source != .focusedWindowChanged, !isActivationForManagedRequest {
            controller.focusPolicyEngine.beginLease(
                owner: .nativeAppSwitch,
                reason: source.rawValue,
                suppressesFocusFollowsMouse: true,
                duration: 0.4
            )
        }

        let requestDisposition = activationRequestDisposition(
            for: pid,
            token: observedToken,
            activeRequest: activeRequest
        )

        guard let axRef else {
            handleMissingFocusedWindow(
                pid: pid,
                source: source,
                origin: origin,
                requestDisposition: requestDisposition
            )
            return
        }
        let token = WindowToken(pid: pid, windowId: axRef.windowId)

        let appFullscreen = isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef)

        if let entry = controller.workspaceManager.entry(for: token) {
            if removeExistingEntryIfCurrentDecisionIsUntracked(
                entry,
                axRef: axRef,
                appFullscreen: appFullscreen,
                source: source
            ) {
                return
            }

            if appFullscreen {
                suspendManagedWindowForNativeFullscreen(entry)
                return
            }
            _ = restoreManagedWindowFromNativeFullscreen(entry)
            let wsId = entry.workspaceId

            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            if shouldSuppressSameAppParkedFocusBeforeConfirm(
                observedEntry: entry,
                workspaceId: wsId,
                requestDisposition: requestDisposition,
                source: source
            ) {
                return
            }

            if redirectToStableCloseSuccessorFocusBeforeConfirmIfNeeded(
                observedEntry: entry,
                workspaceId: wsId,
                source: source
            ) {
                return
            }

            if shouldSuppressHiddenInactiveStickyActivation(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source
            ) {
                return
            }

            recordCloseRecoveryActivationGate(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin,
                decision: "evaluate"
            )

            if shouldDeferSameAppInactiveNativeActivationBeforeCloseRecovery(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin
            ) {
                return
            }

            if shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source
            ) {
                return
            }

            if shouldSuppressManagedActivationWhileNonManagedFocusAnchored(
                entry: entry,
                requestDisposition: requestDisposition
            ) {
                return
            }

            if shouldDeferInactiveNativeActivationBeforeCloseRecovery(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin
            ) {
                return
            }

            if shouldDeferSameAppActiveNativeActivationBeforeCloseRecovery(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin
            ) {
                return
            }

            if shouldSuppressObservedActivationDuringWindowCloseRecovery(
                entry: entry,
                requestDisposition: requestDisposition,
                source: source
            ) {
                if case let .conflictsWithPendingRequest(request) = requestDisposition {
                    continueManagedFocusRequest(
                        request,
                        source: source,
                        origin: origin,
                        reason: .pendingFocusMismatch
                    )
                }
                return
            }

            if redirectToStableOverlayRecoveryFocusIfNeeded(observedEntry: entry, workspaceId: wsId) {
                return
            }

            switch requestDisposition {
            case .matchesActiveRequest:
                break
            case let .conflictsWithPendingRequest(request):
                if shouldHonorObservedFocusOverPendingRequest(
                    source: source,
                    origin: origin
                ) {
                    clearManagedFocusState(
                        matching: request.token,
                        workspaceId: request.workspaceId
                    )
                    break
                }
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusMismatch
                )
                return
            case .unrelatedNoRequest:
                guard shouldHandleObservedManagedActivationWithoutPendingRequest(
                    source: source,
                    origin: origin,
                    isWorkspaceActive: isWorkspaceActive
                ) else { return }
            }

            if redirectToStableRecoveryFocusIfNeeded(observedEntry: entry, workspaceId: wsId) {
                return
            }

            endWindowCloseFocusRecovery(matching: wsId)
            handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen,
                source: source,
                confirmRequest: true,
                origin: origin
            )
            return
        }

        if restoreNativeFullscreenReplacementIfNeeded(
            token: token,
            windowId: UInt32(axRef.windowId),
            axRef: axRef,
            workspaceId: controller.interactionWorkspace()?.id,
            appFullscreen: appFullscreen
        ),
            let restoredEntry = controller.workspaceManager.entry(for: token)
        {
            let wsId = restoredEntry.workspaceId
            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            if shouldSuppressSameAppParkedFocusBeforeConfirm(
                observedEntry: restoredEntry,
                workspaceId: wsId,
                requestDisposition: requestDisposition,
                source: source
            ) {
                return
            }

            if redirectToStableCloseSuccessorFocusBeforeConfirmIfNeeded(
                observedEntry: restoredEntry,
                workspaceId: wsId,
                source: source
            ) {
                return
            }

            recordCloseRecoveryActivationGate(
                entry: restoredEntry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin,
                decision: "evaluate"
            )

            if shouldDeferSameAppInactiveNativeActivationBeforeCloseRecovery(
                entry: restoredEntry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin
            ) {
                return
            }

            if shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery(
                entry: restoredEntry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source
            ) {
                return
            }

            if shouldSuppressManagedActivationWhileNonManagedFocusAnchored(
                entry: restoredEntry,
                requestDisposition: requestDisposition
            ) {
                return
            }

            if shouldDeferInactiveNativeActivationBeforeCloseRecovery(
                entry: restoredEntry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin
            ) {
                return
            }

            if shouldDeferSameAppActiveNativeActivationBeforeCloseRecovery(
                entry: restoredEntry,
                isWorkspaceActive: isWorkspaceActive,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin
            ) {
                return
            }

            if shouldSuppressObservedActivationDuringWindowCloseRecovery(
                entry: restoredEntry,
                requestDisposition: requestDisposition,
                source: source
            ) {
                if case let .conflictsWithPendingRequest(request) = requestDisposition {
                    continueManagedFocusRequest(
                        request,
                        source: source,
                        origin: origin,
                        reason: .pendingFocusMismatch
                    )
                }
                return
            }

            if redirectToStableOverlayRecoveryFocusIfNeeded(observedEntry: restoredEntry, workspaceId: wsId) {
                return
            }

            switch requestDisposition {
            case .matchesActiveRequest:
                break
            case let .conflictsWithPendingRequest(request):
                if shouldHonorObservedFocusOverPendingRequest(
                    source: source,
                    origin: origin
                ) {
                    clearManagedFocusState(
                        matching: request.token,
                        workspaceId: request.workspaceId
                    )
                    break
                }
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusMismatch
                )
                return
            case .unrelatedNoRequest:
                guard shouldHandleObservedManagedActivationWithoutPendingRequest(
                    source: source,
                    origin: origin,
                    isWorkspaceActive: isWorkspaceActive
                ) else { return }
            }

            if redirectToStableRecoveryFocusIfNeeded(observedEntry: restoredEntry, workspaceId: wsId) {
                return
            }

            endWindowCloseFocusRecovery(matching: wsId)
            handleManagedAppActivation(
                entry: restoredEntry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen,
                source: source,
                confirmRequest: true,
                origin: origin
            )
            return
        }

        if admitFocusedWindowBeforeNonManagedFallback(
            token: token,
            axRef: axRef,
            source: source,
            origin: origin,
            requestDisposition: requestDisposition,
            appFullscreen: appFullscreen
        ) {
            return
        }

        if activeWindowCloseFocusRecoveryWorkspaceId() != nil {
            switch requestDisposition {
            case .matchesActiveRequest:
                break
            case let .conflictsWithPendingRequest(request):
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusUnmanagedToken
                )
                return
            case .unrelatedNoRequest:
                return
            }
        }

        switch requestDisposition {
        case let .matchesActiveRequest(request),
             let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                source: source,
                origin: origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                break
            }
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .pendingFocusUnmanagedToken
            )
            return
        case .unrelatedNoRequest:
            break
        }

        let focusedTokenBeforeFallback = controller.workspaceManager.confirmedManagedFocusToken
        let shouldPreserveManagedFocus = source == .focusedWindowChanged
            && focusedTokenBeforeFallback != nil
        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
        let fallbackFullscreen = appFullscreenForFallbackLifecyclePreservation(
            observedAppFullscreen: appFullscreen
        )
        _ = controller.workspaceManager.enterNonManagedFocus(
            appFullscreen: fallbackFullscreen,
            preserveFocusedToken: shouldPreserveManagedFocus
        )
        _ = controller.focusBorderController.focusChanged(to: target, forceOrdering: true)

        recordNonManagedFallbackEntered(pid: pid, source: source)
    }

    private func admitFocusedWindowBeforeNonManagedFallback(
        token: WindowToken,
        axRef: AXWindowRef,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        requestDisposition: ActivationRequestDisposition,
        appFullscreen: Bool
    ) -> Bool {
        guard let controller,
              let windowId = UInt32(exactly: token.windowId)
        else {
            return false
        }

        let windowInfo = resolveWindowInfo(windowId)
        // AX focus can arrive before the matching CGS .created event. If we
        // admit the window from this path without a context, placement loses the
        // create-time focus/interaction inputs and falls back to frame/live state.
        let createPlacementContext = ensureCreatePlacementContextForFocusedAdmission(
            windowId: windowId,
            pid: token.pid
        )
        guard let candidate = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            fallbackToken: token,
            fallbackAXRef: axRef,
            createPlacementContext: createPlacementContext,
            traceContext: "focused_admission"
        ) else {
            if let windowInfo {
                _ = scheduleCreatedWindowRetryIfNeeded(
                    windowId: windowId,
                    pid: pid_t(windowInfo.pid)
                )
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(windowInfo.pid))])
            } else {
                _ = scheduleCreatedWindowInfoRetryIfNeeded(windowId: windowId)
            }
            return false
        }
        guard candidate.token == token else { return false }

        cancelCreatedWindowRetry(windowId: windowId)
        let suppressedByUnrequestedGuard = shouldSuppressUnrequestedAdmissionDuringNonManagedFocus(
            token: candidate.token,
            createPlacementContext: createPlacementContext,
            hasExplicitWorkspaceAssignment: candidate.hasExplicitWorkspaceAssignment
        )
        if suppressedByUnrequestedGuard {
            recordFocusedAdmissionGuard(
                candidate,
                source: source,
                origin: origin,
                requestDisposition: requestDisposition,
                outcome: "suppressed",
                reason: "unrequested_nonmanaged_focus_guard",
                shouldDelayManagedReplacementCreate: nil,
                suppressedByUnrequestedGuard: true,
                createPlacementContext: createPlacementContext
            )
            discardCreatePlacementContext(windowId: windowId)
            return true
        }
        let delayManagedReplacementCreate = shouldDelayManagedReplacementCreate(candidate)
        if delayManagedReplacementCreate {
            recordFocusedAdmissionGuard(
                candidate,
                source: source,
                origin: origin,
                requestDisposition: requestDisposition,
                outcome: "delayed",
                reason: "managed_replacement_create",
                shouldDelayManagedReplacementCreate: true,
                suppressedByUnrequestedGuard: false,
                createPlacementContext: createPlacementContext
            )
            enqueueManagedReplacementCreate(candidate)
            return true
        }

        recordFocusedAdmissionGuard(
            candidate,
            source: source,
            origin: origin,
            requestDisposition: requestDisposition,
            outcome: "trackPreparedCreate",
            reason: "direct_focused_admission",
            shouldDelayManagedReplacementCreate: false,
            suppressedByUnrequestedGuard: false,
            createPlacementContext: createPlacementContext
        )
        trackPreparedCreate(candidate, admissionContext: .focusedAdmission)
        guard let entry = controller.workspaceManager.entry(for: candidate.token) else {
            return true
        }

        let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let isWorkspaceActive = targetMonitor.map { monitor in
            controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
        } ?? false

        if shouldSuppressManagedActivationWhileNonManagedFocusAnchored(
            entry: entry,
            requestDisposition: requestDisposition
        ) {
            return true
        }

        if shouldSuppressObservedActivationDuringWindowCloseRecovery(
            entry: entry,
            requestDisposition: requestDisposition,
            source: source
        ) {
            if case let .conflictsWithPendingRequest(request) = requestDisposition {
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusMismatch
                )
            }
            return true
        }

        switch requestDisposition {
        case .matchesActiveRequest:
            break
        case let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                source: source,
                origin: origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                break
            }
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .pendingFocusUnmanagedToken
            )
            return true
        case .unrelatedNoRequest:
            guard shouldHandleObservedManagedActivationWithoutPendingRequest(
                source: source,
                origin: origin,
                isWorkspaceActive: isWorkspaceActive
            ) else { return true }
        }

        handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            appFullscreen: appFullscreen,
            source: source,
            confirmRequest: true,
            origin: origin
        )
        return true
    }

    private func recordFocusedAdmissionGuard(
        _ candidate: PreparedCreate,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        requestDisposition: ActivationRequestDisposition,
        outcome: String,
        reason: String,
        shouldDelayManagedReplacementCreate: Bool?,
        suppressedByUnrequestedGuard: Bool?,
        createPlacementContext: WindowCreatePlacementContext?
    ) {
        recordNiriCreateFocusTrace(
            .init(
                kind: .focusedAdmissionGuard(
                    token: candidate.token,
                    workspaceId: candidate.workspaceId,
                    monitorId: managedReplacementMonitorId(for: candidate.workspaceId),
                    source: source,
                    outcome: outcome,
                    reason: reason,
                    shouldDelayManagedReplacementCreate: shouldDelayManagedReplacementCreate,
                    suppressedByUnrequestedGuard: suppressedByUnrequestedGuard,
                    hasStructuralReplacementWorkspaceMatch: candidate.hasStructuralReplacementWorkspaceMatch,
                    mode: candidate.mode,
                    createContextSource: createPlacementContext?.source,
                    recentPidWorkspaceId: createPlacementContext?.recentPidWorkspaceId
                )
            )
        )
    }

    func handleManagedAppActivation(
        entry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        source: ActivationEventSource = .focusedWindowChanged,
        confirmRequest: Bool? = nil,
        origin: ActivationCallOrigin = .external
    ) {
        guard let controller else { return }
        if appFullscreen {
            suspendManagedWindowForNativeFullscreen(entry)
            return
        }

        _ = restoreManagedWindowFromNativeFullscreen(entry)
        let wsId = entry.workspaceId
        let monitorId = controller.workspaceManager.monitorId(for: wsId)
        // If follow_focus just switched this app to a parked window's workspace,
        // hold there briefly: an immediate confirm of another of the app's
        // windows (the still-on-screen origin) must not bounce the view back to
        // a different workspace. Suppress the workspace activation while the hold
        // is on a different workspace than this window's.
        let heldWorkspace = activeParkedFollowHoldWorkspace(forPid: entry.pid)
        let bounceBlocked = heldWorkspace != nil && heldWorkspace != wsId
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow && !bounceBlocked
        recordNiriCreateFocusTrace(
            .init(
                kind: .revealDecision(
                    token: entry.token,
                    targetWs: wsId,
                    isWorkspaceActive: isWorkspaceActive,
                    shouldActivate: shouldActivateWorkspace,
                    targetWsVisible: controller.workspaceManager.visibleWorkspaceIds().contains(wsId),
                    source: source
                )
            )
        )
        let activeRequest = controller.focusBridge.activeManagedRequest(for: entry.pid)
        let shouldConfirmRequest = confirmRequest ?? true
        // Detect re-confirmation of an already-confirmed focus token. A
        // quick-terminal hide can cause macOS to re-focus the existing managed
        // window; without this guard the viewport scrolls back to a column the
        // user deliberately scrolled away from.
        let wasAlreadyConfirmedFocus = controller.workspaceManager.confirmedManagedFocusToken == entry.token
        let selectedSameAppFocusDisappearedBeforeConfirm = selectedSameAppFocusDisappearedSignal(
            for: entry,
            workspaceId: wsId
        )
        var confirmedRequestId: UInt64?

        if shouldConfirmRequest {
            let wasNonManagedFocusActive = controller.workspaceManager.isNonManagedFocusActive
            _ = controller.workspaceManager.confirmManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId,
                appFullscreen: appFullscreen,
                activateWorkspaceOnMonitor: shouldActivateWorkspace
            )
            if wasNonManagedFocusActive {
                controller.suppressMouseMoveToFocusedWindow(for: entry.token)
            }

            if let activeRequest {
                confirmedRequestId = activeRequest.requestId
                if activeRequest.token == entry.token {
                    _ = controller.focusBridge.confirmManagedRequest(
                        token: entry.token,
                        source: source
                    )
                } else {
                    _ = controller.focusBridge.cancelManagedRequest(requestId: activeRequest.requestId)
                }
            }

            if let confirmedRequestId {
                cancelActivationRetry(requestId: confirmedRequestId)
            }
            recordRecentManagedWorkspace(pid: entry.pid, workspaceId: wsId)
            recordNiriCreateFocusTrace(
                .init(
                    kind: .focusConfirmed(
                        token: entry.token,
                        workspaceId: wsId,
                        source: source
                    )
                )
            )
            let onScreen = isEntryOnScreen(entry)
            recordFocusRealityCheck(entry: entry, onScreen: onScreen)
            followFocusToParkedWindowWorkspaceIfNeeded(entry: entry, onScreen: onScreen)
        } else {
            _ = controller.workspaceManager.setManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId
            )
            recordRecentManagedWorkspace(pid: entry.pid, workspaceId: wsId)
        }

        let target = controller.keyboardFocusTarget(for: entry.token, axRef: entry.axRef)
        var preferredMouseFrame: CGRect?
        // M3: whether this confirmation is focus-follows-mouse driven. Hoisted out of
        // the engine block so the cursor-warp gate below can suppress warp on hover.
        var confirmationIsFFM = false
        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.handle),
           let _ = controller.workspaceManager.monitor(for: wsId)
        {
            let preferredFrame = node.preferredFrame
            preferredMouseFrame = preferredFrame
            var state = controller.workspaceManager.niriViewportState(for: wsId)
            let now = Date()
            let pendingFFMToken = state.pendingFFMFocusToken
            let pendingFFMDate = state.pendingFFMFocusTimestamp
            let pendingFFMIsFresh = pendingFFMDate.map { now.timeIntervalSince($0) <= 1.0 } ?? false
            let recentFFMToken = state.recentFFMFocusToken
            let recentFFMDate = state.recentFFMFocusTimestamp
            let recentFFMIsFresh = recentFFMDate.map { now.timeIntervalSince($0) <= 1.0 } ?? false
            let isFFM = pendingFFMToken == entry.token && pendingFFMIsFresh
                || (recentFFMToken == entry.token && recentFFMIsFresh)
            confirmationIsFFM = isFFM
            if pendingFFMToken == entry.token, pendingFFMIsFresh {
                state.pendingFFMFocusToken = nil
                state.pendingFFMFocusTimestamp = nil
                state.recentFFMFocusToken = entry.token
                state.recentFFMFocusTimestamp = now
            } else {
                state.pendingFFMFocusToken = nil
                state.pendingFFMFocusTimestamp = nil
                if !isFFM {
                    state.recentFFMFocusToken = nil
                    state.recentFFMFocusTimestamp = nil
                }
            }
            // `isAnimating` stays true through a spring's cosmetic settle tail
            // (current already converged to target, not yet flipped to
            // `.static`). Only treat the spring as genuinely in flight when it
            // hasn't yet converged within the same pixel tolerance used by
            // scrollToReveal, so a settled spring
            // doesn't suppress this step's own reveal in favor of the
            // follow-up relayout.
            let settleTolerance = 1.0 / max(engine.displayScale(in: wsId), 1.0)
            let isSpringInFlight = state.viewOffsetPixels.isAnimating
                && abs(state.viewOffsetPixels.current() - state.viewOffsetPixels.target()) > settleTolerance
            var overlaySignal = (recentNonManaged: hasRecentNonManagedFocus(for: entry.pid), overlayVisible: false)
            var closeRecoveryPins = sameAppCloseRecoveryViewportPins(
                entry: entry,
                wsId: wsId,
                selectedSameAppFocusDisappearedBeforeConfirm: selectedSameAppFocusDisappearedBeforeConfirm,
                overlaySignal: overlaySignal
            )
            if !closeRecoveryPins.shouldPin,
               activeWindowCloseFocusRecoveryWorkspaceId() == nil,
               isWithinSameAppCloseRecoveryWindow(pid: entry.pid)
            {
                overlaySignal.overlayVisible = hasVisibleSamePidOverlayWindow(for: entry)
                closeRecoveryPins = sameAppCloseRecoveryViewportPins(
                    entry: entry,
                    wsId: wsId,
                    selectedSameAppFocusDisappearedBeforeConfirm: selectedSameAppFocusDisappearedBeforeConfirm,
                    overlaySignal: overlaySignal
                )
            }
            let closeRecoveryPin = closeRecoveryPins.closeRecoveryPin
            let recentSameAppClosePin = closeRecoveryPins.recentSameAppClosePin
            let overlayRecoveryPin = closeRecoveryPins.overlayRecoveryPin
            let selectedSameAppFocusDisappearedPin = closeRecoveryPins.selectedSameAppFocusDisappearedPin
            let preserveActiveViewport = state.viewOffsetPixels.isGesture
                || isSpringInFlight
                || (wasAlreadyConfirmedFocus && source == .focusedWindowChanged)
                || closeRecoveryPins.shouldPin
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: wsId,
                reason: "ax_focus_confirm_before_activate",
                details: [
                    "token=\(entry.token)",
                    "pendingFFM=\(pendingFFMToken.map(String.init(describing:)) ?? "nil")",
                    "pendingFFMFresh=\(pendingFFMIsFresh)",
                    "recentFFM=\(recentFFMToken.map(String.init(describing:)) ?? "nil")",
                    "recentFFMFresh=\(recentFFMIsFresh)",
                    "isFFM=\(isFFM)",
                    "preserveActiveViewport=\(preserveActiveViewport)",
                    "closeRecoveryPin=\(closeRecoveryPin)",
                    "recentSameAppClosePin=\(recentSameAppClosePin)",
                    "overlayRecoveryPin=\(overlayRecoveryPin)",
                    "selectedSameAppFocusDisappearedPin=\(selectedSameAppFocusDisappearedPin)",
                    "recentNonManaged=\(overlaySignal.recentNonManaged)",
                    "overlayVisible=\(overlaySignal.overlayVisible)",
                    "wasAlreadyConfirmedFocus=\(wasAlreadyConfirmedFocus)",
                    "isGesture=\(state.viewOffsetPixels.isGesture)",
                    "wasAnimating=\(state.viewOffsetPixels.isAnimating)"
                ]
            )
            controller.niriLayoutHandler.activateNode(
                node, in: wsId, state: &state,
                options: .init(
                    ensureVisible: false,
                    preserveViewportAnchor: true,
                    layoutRefresh: false,
                    axFocus: false,
                    startAnimation: false
                )
            )
            // Keep activeColumnIndex synced to the newly activated node's real
            // column unconditionally, regardless of preserveActiveViewport.
            // This is anchor-preserving (the compensating offset delta keeps
            // the resulting view position unchanged), so it produces no
            // visible motion on its own; it only removes the staleness that
            // would otherwise force the next relayout's ensureSelectionVisible
            // to perform its own instant rebase.
            controller.niriLayoutHandler.rebaseViewportAnchor(to: node, in: wsId, state: &state)
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: wsId,
                reason: "ax_focus_confirm_after_activate",
                details: [
                    "token=\(entry.token)",
                    "isFFM=\(isFFM)",
                    "preserveActiveViewport=\(preserveActiveViewport)"
                ]
            )
            if !isFFM,
               !preserveActiveViewport,
               let column = engine.column(of: node),
               let columnIndex = engine.columnIndex(of: column, in: wsId),
               let monitor = controller.workspaceManager.monitor(for: wsId)
            {
                let gap = controller.gapSize(for: monitor)
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                let columns = engine.columns(in: wsId)
                let context = engine.makeViewportSnapContext(
                    columns: columns,
                    state: state,
                    workingFrame: workingFrame,
                    gaps: gap,
                    intentionallyDoesNotFillViewport: engine.loneWindowIntentionallyDoesNotFillViewport(in: wsId)
                )
                let viewStart = context.currentViewStart(in: state)
                let visibility = context.visibility(of: columnIndex, viewportOffset: viewStart, in: state)
                let columnSnaps = context.snapCandidates(for: columnIndex, in: state)
                let closestSnap = columnSnaps.closest(to: viewStart)
                let centerSnap = columnSnaps.first { $0.kind == .center }
                controller.diagnostics.recordRuntimeViewportTrace(
                    workspaceId: wsId,
                    reason: "ax_focus_confirm_reveal_candidate",
                    details: [
                        "token=\(entry.token)",
                        "columnIndex=\(columnIndex)",
                        "revealStyle=\(engine.revealStyle.rawValue)",
                        "locked=\(state.isScrollLocked)",
                        "visibility=\(visibility)",
                        String(format: "viewStart=%.1f", viewStart),
                        "closest=\(closestSnap.map { String(format: "%.1f:%@", $0.offset, String(describing: $0.kind)) } ?? "nil")",
                        "closestFills=\(closestSnap.map { context.fillsViewport(at: $0.offset, in: state) }.map(String.init) ?? "nil")",
                        "center=\(centerSnap.map { String(format: "%.1f:%@", $0.offset, String(describing: $0.kind)) } ?? "nil")",
                        "centerFills=\(centerSnap.map { context.fillsViewport(at: $0.offset, in: state) }.map(String.init) ?? "nil")",
                        "snapCount=\(columnSnaps.count)"
                    ]
                )
                let didReveal = engine.scrollToReveal(
                    columnIndex: columnIndex,
                    isFFM: isFFM,
                    state: &state,
                    context: context,
                    motion: controller.motionPolicy.snapshot(),
                    scale: engine.displayScale(in: wsId)
                )
                controller.diagnostics.recordRuntimeViewportTrace(
                    workspaceId: wsId,
                    reason: "ax_focus_confirm_reveal_result",
                    details: [
                        "token=\(entry.token)",
                        "columnIndex=\(columnIndex)",
                        "isFFM=\(isFFM)",
                        "didReveal=\(didReveal)"
                    ]
                )
            } else {
                controller.diagnostics.recordRuntimeViewportTrace(
                    workspaceId: wsId,
                    reason: "ax_focus_confirm_reveal_skipped",
                    details: [
                        "token=\(entry.token)",
                        "isFFM=\(isFFM)",
                        "preserveActiveViewport=\(preserveActiveViewport)"
                    ]
                )
            }
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: state,
                    rememberedFocusToken: nil
                )
            )
            if isWorkspaceActive, !isFFM {
                controller.diagnostics.recordRuntimeViewportTrace(
                    workspaceId: wsId,
                    reason: "ax_focus_confirm_request_relayout",
                    details: ["token=\(entry.token)", "isFFM=\(isFFM)"]
                )
                controller.layoutRefreshController.requestRefresh(reason: .layoutCommand)
                if state.viewOffsetPixels.isAnimating {
                    controller.layoutRefreshController.startScrollAnimation(for: wsId)
                }
            } else {
                controller.diagnostics.recordRuntimeViewportTrace(
                    workspaceId: wsId,
                    reason: "ax_focus_confirm_skip_relayout",
                    details: [
                        "token=\(entry.token)",
                        "isWorkspaceActive=\(isWorkspaceActive)",
                        "isFFM=\(isFFM)",
                        "isAnimating=\(state.viewOffsetPixels.isAnimating)"
                    ]
                )
            }

            _ = controller.focusBorderController.focusChanged(
                to: target,
                preferredFrame: preferredFrame,
                forceOrdering: true
            )
        } else {
            _ = controller.focusBorderController.focusChanged(to: target, forceOrdering: true)
        }

        controller.niriLayoutHandler.updateTabbedColumnOverlays(forceOrdering: true)
        if shouldActivateWorkspace, shouldConfirmRequest {
            controller.syncMonitorsToNiriEngine()
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .appActivationTransition
            )
        }
        if shouldConfirmRequest,
           controller.moveMouseToFocusedWindowEnabled,
           controller.workspaceManager.confirmedManagedFocusToken == entry.token,
           !controller.workspaceManager.isNonManagedFocusActive,
           !controller.shouldSuppressMouseMoveToFocusedWindow(for: entry.token),
           !confirmationIsFFM
        {
            controller.moveMouseToWindow(entry.token, preferredFrame: preferredMouseFrame, reason: "axFocusConfirmed")
        }
    }

    func focusedWindowToken(for pid: pid_t) -> WindowToken? {
        guard let axRef = resolveFocusedAXWindowRef(pid: pid) else { return nil }
        return WindowToken(pid: pid, windowId: axRef.windowId)
    }

    func handleWindowMiniaturized(pid: pid_t, windowId: Int) {
        controller?.clearKeyboardFocusTarget(
            matching: WindowToken(pid: pid, windowId: windowId),
            pid: pid
        )
    }

    @discardableResult
    private func suspendManagedWindowForNativeFullscreen(_ entry: WindowModel.Entry) -> Bool {
        guard let controller else { return false }
        cancelNativeFullscreenLifecycleTasks(containing: entry.token)
        let changed = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
        _ = controller.focusBorderController.focusChanged(
            to: controller.keyboardFocusTarget(for: entry.token, axRef: entry.axRef),
            forceOrdering: true
        )
        if changed {
            controller.layoutRefreshController.requestRefresh(
                reason: .appActivationTransition,
                affectedWorkspaceIds: [entry.workspaceId]
            )
        }
        return changed
    }

    @discardableResult
    private func restoreManagedWindowFromNativeFullscreen(_ entry: WindowModel.Entry) -> Bool {
        guard let controller else { return false }
        let hadRecord = controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
        guard hadRecord || controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen else {
            return false
        }
        cancelNativeFullscreenLifecycleTasks(containing: entry.token)
        let restored = controller.workspaceManager.restoreNativeFullscreenRecord(for: entry.token) != nil || hadRecord
        if restored {
            controller.layoutRefreshController.markNativeFullscreenRestoredForFrameApply(entry.token)
            controller.nativeFullscreenPlaceholderManager.remove(entry.token)
        }
        return restored
    }

    @discardableResult
    func restoreNativeFullscreenReplacementIfNeeded(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?,
        appFullscreen: Bool
    ) -> Bool {
        restoreNativeFullscreenReplacement(
            token: token,
            windowId: windowId,
            axRef: axRef,
            workspaceId: workspaceId,
            appFullscreen: appFullscreen
        ).restored
    }

    private func restoreNativeFullscreenReplacement(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?,
        appFullscreen: Bool
    ) -> NativeFullscreenReplacementRestoreResult {
        guard let controller else { return .notRestored }
        let unavailableRecord = controller.workspaceManager.nativeFullscreenUnavailableCandidate(
            for: token.pid,
            activeWorkspaceId: workspaceId
        ) ?? (appFullscreen ? synthesizeNativeFullscreenUnavailableRecord(
            for: token,
            activeWorkspaceId: workspaceId
        ) : nil)
        guard let record = unavailableRecord else {
            return .notRestored
        }
        if record.currentToken == token {
            guard let entry = controller.workspaceManager.entry(for: token) else {
                return .notRestored
            }
            cancelNativeFullscreenLifecycleTasks(for: record.originalToken)
            let scheduledRelayout: Bool
            if appFullscreen {
                scheduledRelayout = suspendManagedWindowForNativeFullscreen(entry)
            } else {
                _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
                controller.layoutRefreshController.markNativeFullscreenRestoredForFrameApply(token)
                controller.nativeFullscreenPlaceholderManager.remove(token)
                scheduledRelayout = false
            }
            return .restored(scheduledRelayout: scheduledRelayout)
        }
        let hasDuplicateRestoredToken = controller.workspaceManager.entry(for: token) != nil
        guard let entry = rekeyManagedWindowIdentity(
            from: record.currentToken,
            to: token,
            windowId: windowId,
            axRef: axRef,
            replacingExistingDuplicate: hasDuplicateRestoredToken
        )
        else {
            return .notRestored
        }

        cancelNativeFullscreenLifecycleTasks(for: record.originalToken)

        let scheduledRelayout: Bool
        if appFullscreen {
            scheduledRelayout = suspendManagedWindowForNativeFullscreen(entry)
        } else {
            _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
            controller.layoutRefreshController.markNativeFullscreenRestoredForFrameApply(token)
            controller.nativeFullscreenPlaceholderManager.remove(token)
            scheduledRelayout = false
        }

        return .restored(scheduledRelayout: scheduledRelayout)
    }

    private func restoreNativeFullscreenCreateBeforeAdmissionIfNeeded(
        windowId: UInt32,
        windowInfo: WindowServerInfo?,
        createPlacementContext: WindowCreatePlacementContext?
    ) -> NativeFullscreenReplacementRestoreResult {
        guard let controller,
              let windowInfo
        else {
            return .notRestored
        }

        let token = WindowToken(pid: pid_t(windowInfo.pid), windowId: Int(windowId))
        guard controller.workspaceManager.entry(for: token) == nil,
              let axRef = resolveAXWindowRef(windowId: windowId, pid: token.pid)
        else {
            return .notRestored
        }

        let appFullscreen = isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef)
        guard appFullscreen else { return .notRestored }

        return restoreNativeFullscreenReplacement(
            token: token,
            windowId: windowId,
            axRef: axRef,
            workspaceId: nativeFullscreenCreateWorkspaceId(createPlacementContext),
            appFullscreen: true
        )
    }

    private func completeNativeFullscreenCreateRestore(
        _ restore: NativeFullscreenReplacementRestoreResult,
        windowId: UInt32
    ) {
        guard let controller else { return }
        cancelCreatedWindowRetry(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        subscribeToWindows([windowId])
        if case let .restored(scheduledRelayout) = restore,
           !scheduledRelayout
        {
            controller.layoutRefreshController.requestRefresh(reason: .axWindowCreated)
        }
    }

    private func nativeFullscreenCreateWorkspaceId(
        _ createPlacementContext: WindowCreatePlacementContext?
    ) -> WorkspaceDescriptor.ID? {
        createPlacementContext?.focusedWorkspaceId
            ?? createPlacementContext?.activeFocusRequestWorkspaceId
            ?? controller?.interactionWorkspace()?.id
    }

    private func synthesizeNativeFullscreenUnavailableRecord(
        for token: WindowToken,
        activeWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceManager.NativeFullscreenRecord? {
        guard let controller,
              controller.workspaceManager.nativeFullscreenRecord(for: token) == nil,
              controller.workspaceManager.entry(for: token) == nil,
              let entry = nativeFullscreenOriginCandidate(
                  for: token,
                  activeWorkspaceId: activeWorkspaceId
              )
        else {
            return nil
        }

        _ = controller.workspaceManager.requestNativeFullscreenEnter(entry.token, in: entry.workspaceId)
        return controller.workspaceManager.markNativeFullscreenTemporarilyUnavailable(entry.token)
    }

    private func nativeFullscreenOriginCandidate(
        for token: WindowToken,
        activeWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WindowModel.Entry? {
        guard let controller else { return nil }
        let workspaceManager = controller.workspaceManager

        func eligible(_ entry: WindowModel.Entry?) -> WindowModel.Entry? {
            guard let entry,
                  entry.token != token,
                  entry.token.pid == token.pid,
                  entry.mode == .tiling,
                  activeWorkspaceId.map({ entry.workspaceId == $0 }) ?? true,
                  !workspaceManager.isScratchpadToken(entry.token),
                  workspaceManager.hiddenState(for: entry.token)?.isScratchpad != true,
                  workspaceManager.layoutReason(for: entry.token) == .standard,
                  workspaceManager.nativeFullscreenRecord(for: entry.token) == nil
            else {
                return nil
            }
            return entry
        }

        let focusedCandidates = [
            workspaceManager.confirmedManagedFocusToken,
            activeWorkspaceId.flatMap { workspaceManager.preferredWorkspaceFocusToken(in: $0) },
            activeWorkspaceId.flatMap { workspaceManager.rememberedTiledFocusToken(in: $0) }
        ]

        for candidateToken in focusedCandidates.compactMap(\.self) {
            if let entry = eligible(workspaceManager.entry(for: candidateToken)) {
                return entry
            }
        }

        let samePidEntries = workspaceManager.entries(forPid: token.pid).compactMap(eligible)
        guard samePidEntries.count == 1 else { return nil }
        return samePidEntries[0]
    }

    @discardableResult
    func rekeyManagedWindowIdentity(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil,
        replacingExistingDuplicate: Bool = false
    ) -> WindowModel.Entry? {
        guard let controller else { return nil }

        guard let entry = controller.workspaceManager.rekeyWindow(
            from: oldToken,
            to: newToken,
            newAXRef: axRef,
            managedReplacementMetadata: managedReplacementMetadata,
            replacingExistingDuplicate: replacingExistingDuplicate
        )
        else {
            return nil
        }

        _ = controller.niriEngine?.rekeyWindow(
            from: oldToken,
            to: newToken,
            replacingExistingDuplicate: replacingExistingDuplicate
        )
        controller.nativeFullscreenPlaceholderManager.rekey(from: oldToken, to: newToken)

        controller.focusBridge.rekeyPendingFocus(from: oldToken, to: newToken)
        controller.focusBridge.rekeyManagedRequest(from: oldToken, to: newToken)
        controller.focusBorderController.rekeyFocusedTarget(
            from: oldToken,
            to: newToken,
            axRef: axRef,
            workspaceId: entry.workspaceId
        )
        controller.axManager.rekeyWindowState(
            pid: newToken.pid,
            oldWindowId: oldToken.windowId,
            newWindow: axRef
        )
        controller.rekeyScratchpadWindowResources(from: oldToken, to: newToken, axRef: axRef)
        controller.layoutRefreshController.rekeyPendingRevealTransaction(
            from: oldToken,
            to: newToken,
            entry: entry
        )
        AXWindowService.invalidateCachedTitles(windowIds: [UInt32(oldToken.windowId), windowId])
        subscribeToWindows([windowId])
        controller.niriLayoutHandler.updateTabbedColumnOverlays(forceOrdering: true)
        refreshBorderAfterManagedRekey(entry: entry)

        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            if let app = NSRunningApplication(processIdentifier: newToken.pid) {
                _ = await controller.axManager.windowsForApp(app)
            }
        }

        return entry
    }

    private func handleNativeFullscreenDestroy(_ token: WindowToken) -> Bool {
        guard let controller else {
            return false
        }

        let existingRecord = controller.workspaceManager.nativeFullscreenRecord(for: token)
        let unavailableRecord: WorkspaceManager.NativeFullscreenRecord?
        if existingRecord?.currentToken == token {
            unavailableRecord = controller.workspaceManager.markNativeFullscreenTemporarilyUnavailable(token)
        } else if existingRecord != nil {
            return false
        } else if shouldSpeculativelyPreserveNativeFullscreenDestroy(token) {
            unavailableRecord = controller.workspaceManager.markNativeFullscreenSpeculativelyUnavailable(token)
        } else {
            return false
        }

        guard let unavailableRecord else { return false }
        controller.focusBorderController.hide()
        controller.nativeFullscreenPlaceholderManager.remove(token)
        clearManagedFocusState(matching: token, workspaceId: unavailableRecord.workspaceId)
        controller.layoutRefreshController.requestRefresh(
            reason: .appActivationTransition,
            affectedWorkspaceIds: [unavailableRecord.workspaceId]
        )
        scheduleNativeFullscreenFollowup(for: unavailableRecord.originalToken)
        return true
    }

    private func shouldSpeculativelyPreserveNativeFullscreenDestroy(_ token: WindowToken) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              entry.mode == .tiling,
              controller.workspaceManager.confirmedManagedFocusToken == token,
              controller.workspaceManager.scratchpadToken() != token
        else {
            return false
        }

        if let isFullscreenProvider {
            return isFullscreenProvider(entry.axRef)
        }
        return AXWindowService.isFullscreenAttributeSet(entry.axRef)
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.insert(pid)

        if let activeRequest = controller.focusBridge.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            _ = controller.focusBridge.cancelManagedRequest(requestId: activeRequest.requestId)
            cancelActivationRetry(requestId: activeRequest.requestId)
            controller.focusBridge.discardPendingFocus(activeRequest.token)
        }
        if controller.currentBorderTarget()?.pid == pid {
            controller.clearKeyboardFocusTarget(pid: pid)
            _ = controller.workspaceManager.enterNonManagedFocus(
                appFullscreen: false,
                preserveFocusedToken: true
            )
            controller.focusBorderController.clear(pid: pid)
        }

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.token)
        }
        controller.layoutRefreshController.requestRefresh(reason: .appHidden)
    }

    func handleAppDeactivated(pid: pid_t) {
        guard let controller else { return }
        let clearedTarget = controller.focusBorderController.clearCurrentTarget(matching: pid) { target in
            if !target.isManaged {
                return true
            }
            guard let entry = controller.workspaceManager.entry(for: target.token) else {
                return false
            }
            return entry.mode == .floating
        }

        guard let clearedTarget,
              clearedTarget.isManaged,
              let entry = controller.workspaceManager.entry(for: clearedTarget.token),
              entry.mode == .floating
        else { return }

        controller.focusBorderController.suppressManagedTarget(clearedTarget.token)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.remove(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            if controller.workspaceManager.layoutReason(for: entry.token) == .macosHiddenApp {
                _ = controller.workspaceManager.restoreFromNativeState(for: entry.token)
            }
        }
        controller.layoutRefreshController.requestRefresh(reason: .appUnhidden)
    }

    func resetManagedReplacementState() {
        for (_, task) in pendingManagedReplacementTasks {
            task.cancel()
        }
        pendingManagedReplacementTasks.removeAll()
        pendingManagedReplacementBursts.removeAll()
        nextManagedReplacementEventSequence = 0
    }

    func resetWindowStabilizationState() {
        for (_, task) in pendingWindowStabilizationTasks {
            task.cancel()
        }
        pendingWindowStabilizationTasks.removeAll()
    }

    func flushPendingManagedReplacementEventsForTests() {
        let keys = pendingManagedReplacementBursts.keys.sorted {
            ($0.pid, $0.workspaceId.uuidString) < ($1.pid, $1.workspaceId.uuidString)
        }
        for key in keys {
            pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
            flushManagedReplacementBurst(for: key)
        }
    }

    func flushPendingNativeFullscreenFollowupsForTests() {
        let tokens = pendingNativeFullscreenFollowupTasks.keys.sorted {
            ($0.pid, $0.windowId) < ($1.pid, $1.windowId)
        }
        for originalToken in tokens {
            pendingNativeFullscreenFollowupTasks.removeValue(forKey: originalToken)?.cancel()
            guard let controller,
                  let record = controller.workspaceManager.nativeFullscreenRecord(for: originalToken),
                  record.originalToken == originalToken,
                  record.availability == .temporarilyUnavailable
            else {
                continue
            }
            controller.layoutRefreshController.requestRefresh(reason: .activeSpaceChanged)
        }
    }

    private func prepareCreateCandidate(
        windowId: UInt32,
        windowInfo: WindowServerInfo?,
        fallbackToken: WindowToken? = nil,
        fallbackAXRef: AXWindowRef? = nil,
        createPlacementContext: WindowCreatePlacementContext? = nil,
        traceContext: String = "create"
    ) -> PreparedCreate? {
        guard let controller else {
            recordPrepareCreateRejection(
                windowId: windowId,
                token: fallbackToken ?? windowInfo.map { WindowToken(pid: pid_t($0.pid), windowId: Int(windowId)) },
                context: traceContext,
                reason: .missingController,
                windowInfo: windowInfo,
                fallbackToken: fallbackToken,
                fallbackAXRef: fallbackAXRef,
                createPlacementContext: createPlacementContext
            )
            return nil
        }
        let ownedWindow = controller.isOwnedWindow(windowNumber: Int(windowId))
        let windowInfoToken = windowInfo.map { WindowToken(pid: pid_t($0.pid), windowId: Int(windowId)) }
        let token = fallbackToken ?? windowInfoToken
        guard let token else {
            recordPrepareCreateRejection(
                windowId: windowId,
                token: nil,
                context: traceContext,
                reason: .missingToken,
                windowInfo: windowInfo,
                fallbackToken: fallbackToken,
                fallbackAXRef: fallbackAXRef,
                createPlacementContext: createPlacementContext
            )
            return nil
        }
        guard token.windowId == Int(windowId) else {
            recordPrepareCreateRejection(
                windowId: windowId,
                token: token,
                context: traceContext,
                reason: .tokenWindowIdMismatch,
                windowInfo: windowInfo,
                fallbackToken: fallbackToken,
                fallbackAXRef: fallbackAXRef,
                createPlacementContext: createPlacementContext
            )
            return nil
        }
        if controller.workspaceManager.entry(for: token) != nil {
            recordPrepareCreateRejection(
                windowId: windowId,
                token: token,
                context: traceContext,
                reason: .existingEntry,
                windowInfo: windowInfo,
                fallbackToken: fallbackToken,
                fallbackAXRef: fallbackAXRef,
                createPlacementContext: createPlacementContext
            )
            return nil
        }
        if ownedWindow {
            recordPrepareCreateRejection(
                windowId: windowId,
                token: token,
                context: traceContext,
                reason: .ownedWindow,
                windowInfo: windowInfo,
                fallbackToken: fallbackToken,
                fallbackAXRef: fallbackAXRef,
                createPlacementContext: createPlacementContext
            )
            discardCreatePlacementContext(windowId: windowId)
            return nil
        }

        let resolvedAXRef = if fallbackAXRef?.windowId == Int(windowId) {
            fallbackAXRef
        } else {
            resolveAXWindowRef(windowId: windowId, pid: token.pid, matching: windowInfo)
                ?? resolveFocusedAXWindowRef(pid: token.pid).flatMap { $0.windowId == Int(windowId) ? $0 : nil }
        }
        guard let axRef = resolvedAXRef else {
            if let windowServerOnlyCandidate = prepareWindowServerOnlyStickyCreate(
                windowId: windowId,
                token: token,
                windowInfo: windowInfo,
                createPlacementContext: createPlacementContext
            ) {
                return windowServerOnlyCandidate
            }
            recordPrepareCreateRejection(
                windowId: windowId,
                token: token,
                context: traceContext,
                reason: .missingAXRef,
                windowInfo: windowInfo,
                fallbackToken: fallbackToken,
                fallbackAXRef: fallbackAXRef,
                createPlacementContext: createPlacementContext
            )
            return nil
        }

        let app = NSRunningApplication(processIdentifier: token.pid)
        let bundleId = resolveBundleId(token.pid) ?? app?.bundleIdentifier
        let appFullscreen = isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef)
        let matchingWindowInfo = windowInfo.flatMap { pid_t($0.pid) == token.pid ? $0 : nil }
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            appFullscreen: appFullscreen,
            windowInfo: matchingWindowInfo,
            traceContext: traceContext,
            existingModeForTrace: nil
        )

        let trackedMode = controller.trackedModeForLifecycle(
            decision: evaluation.decision,
            existingEntry: nil
        )

        if trackedMode == nil {
            scheduleWindowStabilizationRetryIfNeeded(
                token: token,
                decision: evaluation.decision
            )
        }

        guard let trackedMode else {
            recordPrepareCreateRejection(
                windowId: windowId,
                token: token,
                context: traceContext,
                reason: .untrackedDecision,
                windowInfo: windowInfo,
                fallbackToken: fallbackToken,
                fallbackAXRef: fallbackAXRef,
                createPlacementContext: createPlacementContext
            )
            return nil
        }
        subscribeToWindows([windowId])

        let resolvedBundleId = bundleId ?? evaluation.facts.ax.bundleId
        let structuralReplacementWorkspaceId = structuralReplacementWorkspaceIdForCreate(
            token: token,
            bundleId: resolvedBundleId,
            mode: trackedMode,
            facts: evaluation.facts,
            admittedThisPass: []
        )
        let inheritTrackedParentWorkspace = controller.shouldInheritTrackedParentWorkspace(for: evaluation)
        let placementFrame = evaluation.facts.windowServer?.frame ?? matchingWindowInfo?.frame
        let workspaceId = controller.resolveWorkspaceForNewWindow(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: token.pid,
            parentWindowId: evaluation.facts.windowServer?.parentId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            preferSameAppSiblingWorkspace: controller.shouldPreferSameAppSiblingWorkspace(
                for: evaluation,
                inheritTrackedParentWorkspace: inheritTrackedParentWorkspace
            ),
            structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
            restrictWorkspaceRuleToPlacementMonitor: trackedMode != .floating,
            createPlacementContext: createPlacementContext,
            windowFrame: placementFrame,
            fallbackWorkspaceId: controller.interactionWorkspace()?.id
        )
        recordCreatePlacementTrace(
            token: token,
            workspaceId: workspaceId,
            createPlacementContext: createPlacementContext,
            windowFrame: placementFrame,
            controller: controller
        )

        return PreparedCreate(
            windowId: windowId,
            token: token,
            axRef: axRef,
            ruleEffects: evaluation.decision.ruleEffects,
            replacementMetadata: makeManagedReplacementMetadata(
                bundleId: resolvedBundleId,
                workspaceId: workspaceId,
                mode: trackedMode,
                facts: evaluation.facts
            ),
            hasStructuralReplacementWorkspaceMatch: structuralReplacementWorkspaceId != nil,
            hasExplicitWorkspaceAssignment: evaluation.decision.workspaceName != nil,
            requiresPostCreateLifecycleVerification: requiresPostCreateLifecycleVerification(
                trackedMode: trackedMode,
                facts: evaluation.facts
            )
        )
    }

    private func prepareWindowServerOnlyStickyCreate(
        windowId: UInt32,
        token: WindowToken,
        windowInfo: WindowServerInfo?,
        createPlacementContext: WindowCreatePlacementContext?
    ) -> PreparedCreate? {
        guard let controller,
              let windowInfo,
              isWindowServerOnlyStickyCreateCandidate(windowInfo, token: token)
        else {
            return nil
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        let bundleId = resolveBundleId(token.pid)
        let isParented = windowInfo.parentId != 0
        let workspaceId = controller.resolveWorkspaceForNewWindow(
            workspaceName: nil,
            axRef: axRef,
            pid: token.pid,
            parentWindowId: isParented ? windowInfo.parentId : nil,
            inheritTrackedParentWorkspace: isParented,
            preferSameAppSiblingWorkspace: false,
            structuralReplacementWorkspaceId: nil,
            restrictWorkspaceRuleToPlacementMonitor: false,
            createPlacementContext: createPlacementContext,
            windowFrame: windowInfo.frame,
            fallbackWorkspaceId: controller.interactionWorkspace()?.id
        )
        recordCreatePlacementTrace(
            token: token,
            workspaceId: workspaceId,
            createPlacementContext: createPlacementContext,
            windowFrame: windowInfo.frame,
            controller: controller
        )
        subscribeToWindows([windowId])

        return PreparedCreate(
            windowId: windowId,
            token: token,
            axRef: axRef,
            ruleEffects: ManagedWindowRuleEffects(sticky: true),
            replacementMetadata: ManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                mode: .floating,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: windowInfo.title,
                windowLevel: windowInfo.level,
                parentWindowId: windowInfo.parentId == 0 ? nil : windowInfo.parentId,
                frame: windowInfo.frame,
                transientWindowServerEvidence: true,
                degradedWindowServerChildEvidence: false,
                userAddressableTransientWindowServerSurface: true
            ),
            hasStructuralReplacementWorkspaceMatch: false,
            hasExplicitWorkspaceAssignment: false,
            requiresPostCreateLifecycleVerification: false
        )
    }

    private func isWindowServerOnlyStickyCreateCandidate(
        _ windowInfo: WindowServerInfo,
        token: WindowToken
    ) -> Bool {
        guard pid_t(windowInfo.pid) == token.pid,
              windowInfo.id == UInt32(token.windowId),
              !windowInfo.hasDocumentTag
        else {
            return false
        }

        // Top-level floating media surface (Helium/Chrome/Vivaldi/Zen style PiP):
        // a level-3, parentless, floating-tagged window with a media-like frame.
        if windowInfo.parentId == 0,
           windowInfo.level == 3,
           windowInfo.hasFloatingTag,
           isTopLevelResizableMediaLikeSurfaceFrame(windowInfo.frame)
        {
            return true
        }

        return false
    }

    private func recordPrepareCreateRejection(
        windowId: UInt32,
        token: WindowToken?,
        context: String,
        reason: PrepareCreateCandidateRejectionReason,
        windowInfo: WindowServerInfo?,
        fallbackToken: WindowToken?,
        fallbackAXRef: AXWindowRef?,
        createPlacementContext: WindowCreatePlacementContext?
    ) {
        if let token,
           let windowInfo,
           reason == .untrackedDecision || reason == .missingAXRef,
           isKnownSamePidOverlayWindow(windowInfo, pid: token.pid)
        {
            recordRecentNonManagedFocus(pid: token.pid)
        }

        recordNiriCreateFocusTrace(
            .init(
                kind: .prepareCreateRejected(
                    windowId: windowId,
                    token: token,
                    context: context,
                    reason: reason,
                    hasWindowInfo: windowInfo != nil,
                    windowInfoPid: windowInfo.map { pid_t($0.pid) },
                    windowInfoLevel: windowInfo.map { $0.level },
                    windowInfoParentId: windowInfo.map { $0.parentId },
                    windowInfoHasFloatingTag: windowInfo.map { $0.hasFloatingTag },
                    windowInfoHasDocumentTag: windowInfo.map { $0.hasDocumentTag },
                    windowInfoFrame: windowInfo.map { $0.frame },
                    fallbackToken: fallbackToken,
                    hasFallbackAXRef: fallbackAXRef != nil,
                    createContextSource: createPlacementContext?.source
                )
            )
        )
    }

    private func requiresPostCreateLifecycleVerification(
        trackedMode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> Bool {
        guard trackedMode == .floating else { return false }
        return !facts.ax.attributeFetchSucceeded
            || facts.ax.subrole == (kAXSystemDialogSubrole as String)
            || facts.windowServer?.hasTransientSurfaceEvidence == true
    }

    private func recordCreatePlacementTrace(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        controller: WMController
    ) {
        recordNiriCreateFocusTrace(
            .init(
                kind: .createPlacementResolved(
                    token: token,
                    workspaceId: workspaceId,
                    pendingWorkspaceId: createPlacementContext?.activeFocusRequestWorkspaceId,
                    pendingMonitorId: createPlacementContext?.activeFocusRequestMonitorId,
                    focusedWorkspaceId: createPlacementContext?.focusedWorkspaceId,
                    focusedMonitorId: createPlacementContext?.focusedMonitorId,
                    nativeSpaceMonitorId: createPlacementContext?.nativeSpaceMonitorId,
                    frameMonitorId: placementTraceMonitorId(for: windowFrame, controller: controller),
                    interactionMonitorId: createPlacementContext?.interactionMonitorId,
                    contextSource: createPlacementContext?.source,
                    focusedWorkspaceSource: createPlacementContext?.focusedWorkspaceSource,
                    recentPidWorkspaceId: createPlacementContext?.recentPidWorkspaceId
                )
            )
        )
    }

    private func placementTraceMonitorId(
        for frame: CGRect?,
        controller: WMController
    ) -> Monitor.ID? {
        guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
        return frame.center.monitorApproximation(in: controller.workspaceManager.monitors)?.id
    }

    private func prepareDestroyCandidate(
        windowId: UInt32,
        pidHint: pid_t?
    ) -> PreparedDestroy? {
        guard let controller else { return nil }

        let hintedToken = pidHint.flatMap { hintedPid -> WindowToken? in
            let token = WindowToken(pid: hintedPid, windowId: Int(windowId))
            return controller.workspaceManager.entry(for: token) != nil ? token : nil
        }
        let resolvedToken = hintedToken
            ?? resolveTrackedToken(windowId)
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }

        guard let token = resolvedToken,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return nil
        }

        let bundleId = resolveBundleId(token.pid) ?? entry.managedReplacementMetadata?.bundleId
        let windowInfo = resolveWindowInfo(windowId)
        let cachedMetadata = overlayWindowServerInfo(
            windowInfo,
            onto: cachedManagedReplacementMetadata(
                for: entry,
                fallbackBundleId: bundleId
            )
        )
        let replacementMetadata: ManagedReplacementMetadata
        if managedReplacementNeedsLiveAXFacts(cachedMetadata) {
            let facts = managedReplacementFacts(
                for: entry.axRef,
                pid: token.pid,
                bundleId: cachedMetadata.bundleId,
                windowInfo: windowInfo,
                includeTitle: false
            )
            let liveMetadata = makeManagedReplacementMetadata(
                bundleId: cachedMetadata.bundleId,
                workspaceId: entry.workspaceId,
                mode: entry.mode,
                facts: facts
            )
            replacementMetadata = cachedMetadata.mergingNonNilValues(from: liveMetadata)
        } else {
            replacementMetadata = cachedMetadata
        }

        return PreparedDestroy(
            token: token,
            replacementMetadata: replacementMetadata
        )
    }

    private func handleWindowDestroyed(
        windowId: UInt32,
        pidHint: pid_t?,
        verifyWindowServerLiveness: Bool
    ) {
        let resolvedToken = resolveWindowToken(windowId)
            ?? resolveTrackedToken(windowId)
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }
        if let resolvedToken {
            cancelWindowStabilizationRetry(for: resolvedToken)
            cancelPostCreateLifecycleVerification(for: resolvedToken)
            controller?.clearManualWindowOverride(for: resolvedToken)
        }

        guard let candidate = prepareDestroyCandidate(windowId: windowId, pidHint: pidHint) else {
            if let destroyedPid = pidHint ?? resolvedToken?.pid {
                if hasDeferredSameAppNativeActivation(for: destroyedPid) {
                    // A browser/profile-style same-app focus switch can destroy
                    // an auxiliary AX element after the target focus has already
                    // been observed. Do not convert that into close recovery;
                    // let the deferred activation retry reveal the target.
                } else {
                    recordRecentSameAppWindowClose(pid: destroyedPid)
                    // Quick-terminal hide/close can destroy an auxiliary AX element
                    // instead of the tracked managed window. Preserve the current
                    // workspace before macOS activates a successor app/window.
                    armWindowCloseFocusRecoveryForFocusedAppEvent(pid: destroyedPid)
                }
            }
            clearFocusedTargetForDestroyedWindow(
                windowId: windowId,
                resolvedToken: resolvedToken,
                pidHint: pidHint
            )
            if let resolvedToken {
                controller?.axManager.removeWindowState(
                    pid: resolvedToken.pid,
                    windowId: resolvedToken.windowId
                )
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(resolvedToken.pid)])
            } else if let pid = pidHint ?? resolveWindowInfo(windowId)?.pid {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(pid))])
            }
            return
        }

        recordRecentSameAppWindowClose(pid: candidate.token.pid)

        if verifyWindowServerLiveness {
            if handleNativeFullscreenDestroy(candidate.token) {
                return
            }
            if resolveWindowInfo(windowId)?.pid == candidate.token.pid {
                if pendingDestroyLivenessVerificationTasks[candidate.token] == nil {
                    scheduleDestroyLivenessVerification(for: candidate.token)
                }
                return
            }
        }

        cancelDestroyLivenessVerification(for: candidate.token)

        let shouldDelayDestroy = shouldDelayManagedReplacementDestroy(candidate)
        if shouldDelayDestroy, handleNativeFullscreenDestroy(candidate.token) {
            return
        }

        if shouldDelayDestroy {
            if controller?.currentBorderTarget()?.token == candidate.token {
                controller?.focusBorderController.hide()
            }
            enqueueManagedReplacementDestroy(candidate)
            return
        }

        processPreparedDestroy(candidate)
    }

    private func clearFocusedTargetForDestroyedWindow(
        windowId: UInt32,
        resolvedToken: WindowToken?,
        pidHint: pid_t?
    ) {
        guard let controller,
              let target = controller.currentBorderTarget()
        else { return }

        let matchesResolvedToken = resolvedToken.map { $0 == target.token } ?? false
        let matchesPidHint = pidHint.map { $0 == target.pid && target.windowId == Int(windowId) } ?? false
        let matchesWindowId = target.windowId == Int(windowId)
        guard matchesResolvedToken || matchesPidHint || matchesWindowId else { return }

        controller.clearKeyboardFocusTarget(matching: target.token)
    }

    private func processPreparedDestroy(_ candidate: PreparedDestroy) {
        handleRemoved(token: candidate.token)
    }

    private func shouldDelayManagedReplacementCreate(_ candidate: PreparedCreate) -> Bool {
        guard let _ = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else {
            return false
        }

        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        if pendingManagedReplacementBursts[key] != nil {
            return true
        }

        return candidate.hasStructuralReplacementWorkspaceMatch
    }

    private func shouldDelayManagedReplacementDestroy(_ candidate: PreparedDestroy) -> Bool {
        managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) != nil
    }

    private func enqueueManagedReplacementCreate(_ candidate: PreparedCreate) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        let isNewBurst = pendingManagedReplacementBursts[key] == nil
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: managedReplacementCurrentUptime()
        )
        let hadPendingDestroy = !burst.destroys.isEmpty
        let pendingCreate = PendingManagedCreate(sequence: nextManagedReplacementSequence(), candidate: candidate)
        burst.append(create: pendingCreate)
        pendingManagedReplacementBursts[key] = burst
        let resetExistingDeadline = isNewBurst || hadPendingDestroy
        let policyName = managedReplacementPolicyName(policy)
        recordManagedReplacementTrace(
            key: key,
            kind: .enqueued(
                policy: policyName,
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                deadlineReset: resetExistingDeadline
            )
        )
        recordManagedReplacementTrace(
            key: key,
            kind: .enqueueManagedReplacementCreate(
                policy: policyName,
                token: candidate.token,
                windowId: candidate.windowId,
                monitorId: managedReplacementMonitorId(for: candidate.workspaceId),
                mode: candidate.mode,
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                deadlineReset: resetExistingDeadline,
                hasStructuralReplacementWorkspaceMatch: candidate.hasStructuralReplacementWorkspaceMatch,
                metadataSummary: managedReplacementMetadataSummary(candidate.replacementMetadata)
            )
        )
        scheduleManagedReplacementFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    private func enqueueManagedReplacementDestroy(_ candidate: PreparedDestroy) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        let isNewBurst = pendingManagedReplacementBursts[key] == nil
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: managedReplacementCurrentUptime()
        )
        let hadPendingCreate = !burst.creates.isEmpty
        let pendingDestroy = PendingManagedDestroy(sequence: nextManagedReplacementSequence(), candidate: candidate)
        burst.append(destroy: pendingDestroy)
        pendingManagedReplacementBursts[key] = burst
        let resetExistingDeadline = isNewBurst || hadPendingCreate
        let policyName = managedReplacementPolicyName(policy)
        recordManagedReplacementTrace(
            key: key,
            kind: .enqueued(
                policy: policyName,
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                deadlineReset: resetExistingDeadline
            )
        )
        recordManagedReplacementTrace(
            key: key,
            kind: .enqueueManagedReplacementDestroy(
                policy: policyName,
                token: candidate.token,
                windowId: candidate.token.windowId,
                monitorId: managedReplacementMonitorId(for: candidate.workspaceId),
                mode: candidate.mode,
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                deadlineReset: resetExistingDeadline,
                metadataSummary: managedReplacementMetadataSummary(candidate.replacementMetadata)
            )
        )
        scheduleManagedReplacementFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    private func matchedManagedReplacementPair(
        in burst: PendingManagedReplacementBurst
    ) -> MatchedManagedReplacementPair? {
        var matchedPair: MatchedManagedReplacementPair?

        for destroy in burst.destroys {
            for create in burst.creates {
                guard destroy.candidate.token != create.candidate.token,
                      managedReplacementMetadataMatches(
                          oldToken: destroy.candidate.token,
                          old: destroy.candidate.replacementMetadata,
                          new: create.candidate.replacementMetadata,
                          newFacts: nil
                      )
                else {
                    continue
                }

                if matchedPair != nil {
                    return nil
                }
                matchedPair = MatchedManagedReplacementPair(destroy: destroy, create: create)
            }
        }

        return matchedPair
    }

    @discardableResult
    private func completeManagedReplacement(
        destroy: PendingManagedDestroy,
        create: PendingManagedCreate
    ) -> Bool {
        rekeyManagedReplacement(from: destroy.candidate.token, to: create.candidate)
    }

    private func replayManagedReplacementEvents(
        _ events: [PendingManagedReplacementEvent],
        key: ManagedReplacementKey,
        reason: String
    ) {
        let orderedEvents = events.sorted(by: { $0.sequence < $1.sequence })
        let createCount = orderedEvents.reduce(0) { count, event in
            if case .create = event { return count + 1 }
            return count
        }
        let destroyCount = orderedEvents.count - createCount
        recordManagedReplacementTrace(
            key: key,
            kind: .replayManagedReplacementEvents(
                count: orderedEvents.count,
                createCount: createCount,
                destroyCount: destroyCount,
                reason: reason
            )
        )
        for event in orderedEvents {
            switch event {
            case let .create(create):
                recordManagedReplacementTrace(
                    key: key,
                    kind: .replayManagedReplacementCreate(
                        token: create.candidate.token,
                        windowId: create.candidate.windowId,
                        monitorId: managedReplacementMonitorId(for: create.candidate.workspaceId),
                        mode: create.candidate.mode,
                        metadataSummary: managedReplacementMetadataSummary(create.candidate.replacementMetadata)
                    )
                )
                trackPreparedCreate(create.candidate)
            case let .destroy(destroy):
                recordManagedReplacementTrace(
                    key: key,
                    kind: .replayManagedReplacementDestroy(
                        token: destroy.candidate.token,
                        windowId: destroy.candidate.token.windowId,
                        monitorId: managedReplacementMonitorId(for: destroy.candidate.workspaceId),
                        mode: destroy.candidate.mode,
                        metadataSummary: managedReplacementMetadataSummary(destroy.candidate.replacementMetadata)
                    )
                )
                processPreparedDestroy(destroy.candidate)
            }
        }
    }

    @discardableResult
    private func rekeyManagedReplacement(from oldToken: WindowToken, to create: PreparedCreate) -> Bool {
        let entry = rekeyManagedWindowIdentity(
            from: oldToken,
            to: create.token,
            windowId: create.windowId,
            axRef: create.axRef,
            managedReplacementMetadata: create.replacementMetadata
        )
        if entry != nil {
            discardCreatePlacementContext(windowId: create.windowId)
        }
        return entry != nil
    }

    private func makeManagedReplacementMetadata(
        bundleId: String?,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> ManagedReplacementMetadata {
        let hasGeckoTransientDialogEvidence = WindowRuleEngine.isGeckoTransientDialog(facts: facts)
            || WindowRuleEngine.isGeckoCompactTransientDialog(facts: facts)

        return ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: workspaceId,
            mode: mode,
            role: facts.ax.role,
            subrole: facts.ax.subrole,
            title: facts.ax.title,
            windowLevel: facts.windowServer?.level,
            parentWindowId: normalizedParentWindowId(facts.windowServer?.parentId),
            frame: facts.windowServer?.frame,
            transientWindowServerEvidence: hasGeckoTransientDialogEvidence
                || (facts.windowServer?.hasTransientSurfaceEvidence ?? false),
            degradedWindowServerChildEvidence: facts.degradedWindowServerChildEvidence,
            userAddressableTransientWindowServerSurface: hasGeckoTransientDialogEvidence
                ? false
                : facts.userAddressableTransientWindowServerSurface
        )
    }

    private func normalizedParentWindowId(_ parentWindowId: UInt32?) -> UInt32? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return parentWindowId
    }

    private func cachedManagedReplacementMetadata(
        for entry: WindowModel.Entry,
        fallbackBundleId: String?
    ) -> ManagedReplacementMetadata {
        var metadata = entry.managedReplacementMetadata ?? ManagedReplacementMetadata(
            bundleId: fallbackBundleId,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )
        metadata.bundleId = metadata.bundleId ?? fallbackBundleId
        metadata.workspaceId = entry.workspaceId
        metadata.mode = entry.mode
        return metadata
    }

    private func overlayWindowServerInfo(
        _ windowInfo: WindowServerInfo?,
        onto metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementMetadata {
        guard let windowInfo else { return metadata }
        var metadata = metadata
        metadata.title = windowInfo.title ?? metadata.title
        metadata.windowLevel = windowInfo.level
        metadata.parentWindowId = normalizedParentWindowId(windowInfo.parentId) ?? metadata.parentWindowId
        if !windowInfo.frame.isNull, !windowInfo.frame.isEmpty {
            metadata.frame = windowInfo.frame
        }
        return metadata
    }

    private func managedReplacementFacts(
        for axRef: AXWindowRef,
        pid: pid_t,
        bundleId: String?,
        windowInfo: WindowServerInfo?,
        includeTitle: Bool
    ) -> WindowRuleFacts {
        if let providedFacts = windowFactsProvider?(axRef, pid) {
            return WindowRuleFacts(
                appName: providedFacts.appName,
                ax: providedFacts.ax,
                sizeConstraints: providedFacts.sizeConstraints,
                windowServer: providedFacts.windowServer ?? windowInfo
            )
        }

        let app = NSRunningApplication(processIdentifier: pid)
        return WindowRuleFacts(
            appName: app?.localizedName,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: app?.activationPolicy,
                bundleId: bundleId,
                includeTitle: includeTitle
            ),
            sizeConstraints: nil,
            windowServer: windowInfo
        )
    }

    private func managedReplacementNeedsLiveAXFacts(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        guard metadata.role != nil, metadata.subrole != nil else {
            return true
        }
        return !managedReplacementHasStructuralAnchor(metadata)
    }

    private func structuralReplacementMatch(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts,
        admittedThisPass: Set<WindowToken>
    ) -> StructuralReplacementMatch? {
        guard let controller,
              let fallbackWorkspaceId = controller.interactionWorkspace()?.id
              ?? controller.workspaceManager.primaryWorkspace()?.id
              ?? controller.workspaceManager.workspaces.first?.id
        else {
            return nil
        }

        let baseMetadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: fallbackWorkspaceId,
            mode: mode,
            facts: facts
        )
        guard managedReplacementCorrelationPolicy(for: baseMetadata) != nil else { return nil }

        let recentAdmissionWorkspaceId = recentManagedAdmissionWorkspaceId(for: token)

        var match: StructuralReplacementMatch?
        func recordMatch(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) -> Bool {
            if let recentAdmissionWorkspaceId,
               recentAdmissionWorkspaceId != workspaceId
            {
                return true
            }
            if match != nil {
                return false
            }
            match = StructuralReplacementMatch(token: token, workspaceId: workspaceId)
            return true
        }

        func matches(_ oldMetadata: ManagedReplacementMetadata, oldToken: WindowToken) -> Bool {
            var newMetadata = baseMetadata
            newMetadata.workspaceId = oldMetadata.workspaceId
            return managedReplacementMetadataMatches(
                oldToken: oldToken,
                old: oldMetadata,
                new: newMetadata,
                newFacts: facts
            )
        }

        for burst in pendingManagedReplacementBursts.values {
            for destroy in burst.destroys where destroy.candidate.token.pid == token.pid {
                let metadata = destroy.candidate.replacementMetadata
                if matches(metadata, oldToken: destroy.candidate.token),
                   !recordMatch(token: destroy.candidate.token, workspaceId: metadata.workspaceId)
                {
                    return nil
                }
            }
        }

        for entry in controller.workspaceManager.entries(forPid: token.pid)
            where entry.token != token && !admittedThisPass.contains(entry.token)
        {
            let cachedMetadata = cachedManagedReplacementMetadata(
                for: entry,
                fallbackBundleId: bundleId
            )
            if matches(cachedMetadata, oldToken: entry.token),
               !recordMatch(token: entry.token, workspaceId: cachedMetadata.workspaceId)
            {
                return nil
            }
            if match?.token == entry.token {
                continue
            }
            let liveMetadata = overlayWindowServerInfo(
                UInt32(exactly: entry.windowId).flatMap(resolveWindowInfo),
                onto: cachedMetadata
            )
            if liveMetadata != cachedMetadata,
               matches(liveMetadata, oldToken: entry.token),
               !recordMatch(token: entry.token, workspaceId: liveMetadata.workspaceId)
            {
                return nil
            }
        }

        return match
    }

    private func recordRecentManagedAdmission(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) {
        pruneRecentManagedAdmissions()
        recentManagedAdmissionByToken[token] = RecentManagedAdmission(
            workspaceId: workspaceId,
            recordedAt: managedReplacementCurrentUptime()
        )
    }

    private func recordRecentManagedWorkspace(pid: pid_t, workspaceId: WorkspaceDescriptor.ID) {
        pruneRecentManagedWorkspaces()
        recentManagedWorkspaceByPid[pid] = RecentManagedWorkspace(
            workspaceId: workspaceId,
            recordedAt: managedReplacementCurrentUptime()
        )
    }

    /// Emit the macOS-observed reality for a focus Nehir just confirmed, so the
    /// trace records intent *and* what the window server actually did. Without
    /// this, `focus_confirmed`/`focused=` alone can read as success while the
    /// window is not key (`observed_focused=false`) or its workspace is not the
    /// visible one — a model/reality divergence where the trace looked like it
    /// worked but nothing was on screen.
    /// Whether the window's live frame physically overlaps the visible area of
    /// the monitors by at least half of its area — i.e. it is actually on
    /// screen, not parked off the edge on an inactive workspace. Overlap is
    /// summed across monitors so a window straddling two displays is not
    /// misjudged as off-screen. Frame is resolved through the same injectable
    /// path as the rest of the handler (`observedFrame`) so it stays testable.
    private func isEntryOnScreen(_ entry: WindowModel.Entry) -> Bool {
        guard let controller, let frame = observedFrame(for: entry) else {
            return false
        }
        return Monitor.isFrameOnScreen(frame, across: controller.workspaceManager.monitors)
    }

    /// After a same-app focus switch, Nehir can end up with focus on one of the
    /// app's windows that is parked off-screen (its workspace not actually
    /// rendered), so nothing appears and the user has to reveal it by hand. If
    /// the just-confirmed focus is on a managed, non-sticky window that is
    /// physically off screen, follow it — switch to / re-reveal its workspace.
    /// Keyed on the trustworthy on-screen signal (liveAXFrame), not the model's
    /// visibility flag, because the bug is precisely that the model believes the
    /// workspace is visible while the window is parked.
    ///
    /// Deduplicated per token for a short grace so the re-confirmation that
    /// `activateWorkspace` triggers does not loop before the window unparks.
    /// Restricted to tiling windows: `activateWorkspace` reveals a tiled column;
    /// a floating window has no niri node for it to select, so it would no-op
    /// and emit a misleading `switch` decision.
    private func followFocusToParkedWindowWorkspaceIfNeeded(entry: WindowModel.Entry, onScreen: Bool) {
        guard let controller else { return }
        let manager = controller.workspaceManager
        let now = managedReplacementCurrentUptime()
        recentParkedFocusFollowByToken = recentParkedFocusFollowByToken.filter {
            now - $0.value <= Self.parkedFocusFollowDedupTTL
        }
        // During close recovery, parked-follow would chase the offscreen same-app successor we are trying to ignore.
        if isWithinSameAppCloseRecoveryWindow(pid: entry.pid) {
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: entry.workspaceId,
                reason: "close_recovery_follow_parked_skip",
                details: [
                    "token=\(entry.token)",
                    "skipReason=close_recovery_window"
                ]
            )
            recordNiriCreateFocusTrace(
                .init(
                    kind: .followFocusToParkedWindow(
                        token: entry.token,
                        workspaceId: entry.workspaceId,
                        decision: "skip reason=close_recovery_window"
                    )
                )
            )
            return
        }
        if onScreen {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .followFocusToParkedWindow(
                        token: entry.token,
                        workspaceId: entry.workspaceId,
                        decision: "skip reason=on_screen"
                    )
                )
            )
            return
        }
        if entry.mode != .tiling {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .followFocusToParkedWindow(
                        token: entry.token,
                        workspaceId: entry.workspaceId,
                        decision: "skip reason=floating"
                    )
                )
            )
            return
        }
        if manager.hasStickyWindowSource(entry.token) {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .followFocusToParkedWindow(
                        token: entry.token,
                        workspaceId: entry.workspaceId,
                        decision: "skip reason=sticky"
                    )
                )
            )
            return
        }
        if manager.monitorId(for: entry.workspaceId) == nil {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .followFocusToParkedWindow(
                        token: entry.token,
                        workspaceId: entry.workspaceId,
                        decision: "skip reason=no_monitor"
                    )
                )
            )
            return
        }
        if recentParkedFocusFollowByToken[entry.token] != nil {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .followFocusToParkedWindow(
                        token: entry.token,
                        workspaceId: entry.workspaceId,
                        decision: "skip reason=dedup"
                    )
                )
            )
            return
        }
        recentParkedFocusFollowByToken[entry.token] = now
        parkedFollowHoldByPid[entry.pid] = (workspaceId: entry.workspaceId, at: now)
        recordNiriCreateFocusTrace(
            .init(
                kind: .followFocusToParkedWindow(
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    decision: "switch"
                )
            )
        )
        controller.workspaceNavigationHandler.activateWorkspace(
            entry.workspaceId,
            focusing: entry.token
        )
    }

    private func recordRecentSameAppWindowClose(pid: pid_t) {
        recentSameAppWindowCloseByPid[pid] = managedReplacementCurrentUptime()
    }

    private func recordFocusedWindowLossClosePrecursor(
        pid: pid_t,
        workspaceId: WorkspaceDescriptor.ID,
        preservedToken: WindowToken?
    ) {
        pruneFocusedWindowLossClosePrecursors()
        focusedWindowLossClosePrecursorByPid[pid] = .init(
            workspaceId: workspaceId,
            preservedToken: preservedToken,
            recordedAt: managedReplacementCurrentUptime()
        )
    }

    private func focusedWindowLossClosePrecursor(for pid: pid_t) -> FocusedWindowLossClosePrecursor? {
        pruneFocusedWindowLossClosePrecursors()
        return focusedWindowLossClosePrecursorByPid[pid]
    }

    private func hasDeferredSameAppNativeActivation(for pid: pid_t) -> Bool {
        deferredSameAppActiveNativeActivationTokens.contains { $0.pid == pid }
    }

    private func pruneFocusedWindowLossClosePrecursors(now: TimeInterval? = nil) {
        let now = now ?? managedReplacementCurrentUptime()
        focusedWindowLossClosePrecursorByPid = focusedWindowLossClosePrecursorByPid.filter { _, precursor in
            now - precursor.recordedAt <= Self.focusedWindowLossClosePrecursorTTL
        }
    }

    private func recordRecentNonManagedFocus(pid: pid_t) {
        pruneRecentNonManagedFocus()
        recentNonManagedFocusByPid[pid] = managedReplacementCurrentUptime()
    }

    private func hasRecentNonManagedFocus(for pid: pid_t) -> Bool {
        pruneRecentNonManagedFocus()
        return recentNonManagedFocusByPid[pid] != nil
    }

    private func pruneRecentNonManagedFocus(now: TimeInterval? = nil) {
        let now = now ?? managedReplacementCurrentUptime()
        recentNonManagedFocusByPid = recentNonManagedFocusByPid.filter { _, recordedAt in
            now - recordedAt <= Self.recentNonManagedFocusTTL
        }
    }

    private func recordNonManagedFallbackEntered(pid: pid_t, source: ActivationEventSource) {
        recordRecentNonManagedFocus(pid: pid)
        recordNiriCreateFocusTrace(
            .init(
                kind: .nonManagedFallbackEntered(
                    pid: pid,
                    source: source
                )
            )
        )
    }

    private func hasRecentSameAppWindowClose(for pid: pid_t) -> Bool {
        guard let at = recentSameAppWindowCloseByPid[pid] else { return false }
        guard managedReplacementCurrentUptime() - at <= Self.recentSameAppWindowCloseTTL else {
            recentSameAppWindowCloseByPid.removeValue(forKey: pid)
            return false
        }
        return true
    }

    private func isWithinSameAppCloseRecoveryWindow(pid: pid_t) -> Bool {
        hasRecentNonManagedFocus(for: pid) || hasRecentSameAppWindowClose(for: pid)
    }

    /// The workspace a recent follow_focus pinned for `pid`, if the hold has not
    /// expired.
    private func activeParkedFollowHoldWorkspace(forPid pid: pid_t) -> WorkspaceDescriptor.ID? {
        guard let hold = parkedFollowHoldByPid[pid] else { return nil }
        guard managedReplacementCurrentUptime() - hold.at <= Self.parkedFollowHoldTTL else {
            parkedFollowHoldByPid.removeValue(forKey: pid)
            return nil
        }
        return hold.workspaceId
    }

    private func recordFocusRealityCheck(entry: WindowModel.Entry, onScreen: Bool) {
        guard let controller else { return }
        let wsVisible = controller.workspaceManager.visibleWorkspaceIds().contains(entry.workspaceId)
        // App-level ground truth: is the app even frontmost, and which window
        // does the app itself report as focused. An `observed_focused=false`
        // with `app_frontmost=false` means macOS never activated the app; an
        // `app_focused_window` that differs from the token means Nehir confirmed
        // a different window than the one the app actually made key.
        let appFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid
        let appFocusedWindowId = resolveFocusedAXWindowRef(pid: entry.pid)?.windowId
        recordNiriCreateFocusTrace(
            .init(
                kind: .focusReality(
                    token: entry.token,
                    observedFocused: entry.observedState.isFocused,
                    observedVisible: entry.observedState.isVisible,
                    onScreen: onScreen,
                    wsVisible: wsVisible,
                    appFrontmost: appFrontmost,
                    appFocusedWindowId: appFocusedWindowId
                )
            )
        )
    }

    private func recentManagedWorkspaceId(for pid: pid_t) -> WorkspaceDescriptor.ID? {
        pruneRecentManagedWorkspaces()
        guard let recent = recentManagedWorkspaceByPid[pid],
              controller?.workspaceManager.descriptor(for: recent.workspaceId) != nil
        else {
            return nil
        }
        return recent.workspaceId
    }

    private func pruneRecentManagedWorkspaces(now: TimeInterval? = nil) {
        let now = now ?? managedReplacementCurrentUptime()
        recentManagedWorkspaceByPid = recentManagedWorkspaceByPid.filter { _, recent in
            now - recent.recordedAt <= Self.recentManagedAdmissionTTL &&
                controller?.workspaceManager.descriptor(for: recent.workspaceId) != nil
        }
    }

    private func recordRecentAppActivation(pid: pid_t) {
        pruneRecentAppActivations()
        recentAppActivationByPid[pid] = managedReplacementCurrentUptime()
    }

    private func hasRecentAppActivation(for pid: pid_t) -> Bool {
        pruneRecentAppActivations()
        return recentAppActivationByPid[pid] != nil
    }

    private func pruneRecentAppActivations(now: TimeInterval? = nil) {
        let now = now ?? managedReplacementCurrentUptime()
        recentAppActivationByPid = recentAppActivationByPid.filter { _, recordedAt in
            now - recordedAt <= Self.recentAppActivationTTL
        }
    }

    private func recentManagedAdmissionWorkspaceId(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        pruneRecentManagedAdmissions()
        guard let admission = recentManagedAdmissionByToken[token],
              controller?.workspaceManager.descriptor(for: admission.workspaceId) != nil
        else {
            return nil
        }
        return admission.workspaceId
    }

    private func pruneRecentManagedAdmissions(now: TimeInterval? = nil) {
        let now = now ?? managedReplacementCurrentUptime()
        recentManagedAdmissionByToken = recentManagedAdmissionByToken.filter { _, admission in
            now - admission.recordedAt <= Self.recentManagedAdmissionTTL &&
                controller?.workspaceManager.descriptor(for: admission.workspaceId) != nil
        }
    }

    private func managedReplacementCorrelationPolicy(
        for metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementCorrelationPolicy? {
        guard metadata.role != nil,
              metadata.subrole != nil,
              managedReplacementHasStructuralAnchor(metadata)
        else { return nil }
        return .structural
    }

    private func managedReplacementMetadataMatches(
        oldToken: WindowToken,
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        if managedReplacementIsDirectFloatingChild(oldToken: oldToken, new: new, newFacts: newFacts) {
            return false
        }

        guard managedReplacementCorrelationPolicy(for: old) != nil,
              managedReplacementCorrelationPolicy(for: new) != nil,
              managedReplacementBundleIdsMatch(old.bundleId, new.bundleId),
              old.workspaceId == new.workspaceId,
              old.role == new.role,
              old.subrole == new.subrole,
              managedReplacementWindowLevelsMatch(old.windowLevel, new.windowLevel)
        else {
            return false
        }

        return managedReplacementStructuralAnchorsMatch(oldToken: oldToken, old: old, new: new)
    }

    private func managedReplacementIsDirectFloatingChild(
        oldToken: WindowToken,
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        guard new.mode == .floating,
              let oldWindowId = UInt32(exactly: oldToken.windowId),
              new.parentWindowId == oldWindowId
        else {
            return false
        }

        if managedReplacementHasAXChildEvidence(new) {
            return true
        }

        if new.degradedWindowServerChildEvidence {
            return true
        }

        return newFacts?.degradedWindowServerChildEvidence == true
    }

    private func managedReplacementHasAXChildEvidence(_ metadata: ManagedReplacementMetadata) -> Bool {
        if metadata.role == kAXSheetRole as String {
            return true
        }

        guard let subrole = metadata.subrole else {
            return false
        }

        return subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
            || subrole != kAXStandardWindowSubrole as String
    }

    private func managedReplacementHasStructuralAnchor(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        metadata.parentWindowId != nil || metadata.frame != nil
    }

    private func managedReplacementBundleIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs?.lowercased(), rhs?.lowercased()) {
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return true
        }
    }

    private func managedReplacementWindowLevelsMatch(_ lhs: Int32?, _ rhs: Int32?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    private func managedReplacementStructuralAnchorsMatch(
        oldToken: WindowToken,
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        let framesClose = framesAreCloseForManagedReplacement(old.frame, new.frame)
        let hasFrameEvidence = old.frame != nil && new.frame != nil

        switch (old.parentWindowId, new.parentWindowId) {
        case let (oldParentWindowId?, newParentWindowId?) where oldParentWindowId == newParentWindowId:
            return hasFrameEvidence ? framesClose : true
        case let (_, newParentWindowId?) where UInt32(exactly: oldToken.windowId) == newParentWindowId:
            return framesClose
        case (_?, _?):
            return false
        default:
            return framesClose
        }
    }

    private func framesAreCloseForManagedReplacement(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return false }

        return abs(lhs.midX - rhs.midX) <= 96
            && abs(lhs.midY - rhs.midY) <= 96
            && abs(lhs.width - rhs.width) <= 64
            && abs(lhs.height - rhs.height) <= 64
    }

    private func refreshBorderAfterManagedRekey(entry: WindowModel.Entry) {
        guard let controller else { return }
        guard controller.currentBorderTarget()?.token == entry.token else { return }

        let preferredFrame = controller.focusCoordinator.preferredFrame(for: entry.token)
            ?? frameProvider?(entry.axRef)
        if let preferredFrame {
            _ = controller.focusBorderController.updateFrameHint(for: entry.token, frame: preferredFrame)
        } else {
            _ = controller.focusBorderController.refresh()
        }
    }

    private func resetNativeFullscreenReplacementState() {
        for (_, task) in pendingNativeFullscreenFollowupTasks {
            task.cancel()
        }
        pendingNativeFullscreenFollowupTasks.removeAll()
        for (_, task) in pendingNativeFullscreenStaleCleanupTasks {
            task.cancel()
        }
        pendingNativeFullscreenStaleCleanupTasks.removeAll()
    }

    private func scheduleNativeFullscreenFollowup(for originalToken: WindowToken) {
        cancelNativeFullscreenLifecycleTasks(for: originalToken)
        pendingNativeFullscreenFollowupTasks[originalToken] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.nativeFullscreenFollowupDelay)
            guard !Task.isCancelled, let self, let controller = self.controller else { return }
            defer { self.pendingNativeFullscreenFollowupTasks.removeValue(forKey: originalToken) }
            guard let record = controller.workspaceManager.nativeFullscreenRecord(for: originalToken),
                  record.originalToken == originalToken,
                  record.availability == .temporarilyUnavailable
            else {
                return
            }
            controller.layoutRefreshController.requestRefresh(reason: .activeSpaceChanged)
            self.cleanupClosedNativeFullscreenPlaceholderIfNeeded(record)
        }
        pendingNativeFullscreenStaleCleanupTasks[originalToken] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.nativeFullscreenStaleCleanupDelay)
            guard !Task.isCancelled, let self, let controller = self.controller else { return }
            defer { self.pendingNativeFullscreenStaleCleanupTasks.removeValue(forKey: originalToken) }
            guard let record = controller.workspaceManager.nativeFullscreenRecord(for: originalToken),
                  record.originalToken == originalToken,
                  record.availability == .temporarilyUnavailable
            else {
                return
            }
            let removedEntries = controller.workspaceManager.expireStaleTemporarilyUnavailableNativeFullscreenRecords()
            guard !removedEntries.isEmpty else { return }
            for entry in removedEntries {
                controller.nativeFullscreenPlaceholderManager.remove(entry.token)
            }
            controller.layoutRefreshController.requestRefresh(reason: .activeSpaceChanged)
        }
    }

    private func cleanupClosedNativeFullscreenPlaceholderIfNeeded(
        _ record: WorkspaceManager.NativeFullscreenRecord
    ) {
        guard let controller,
              !controller.workspaceManager.isAppFullscreenActive,
              resolveAXWindowRef(windowId: UInt32(record.currentToken.windowId), pid: record.currentToken.pid) == nil
        else {
            return
        }

        let removedEntries = controller.workspaceManager.expireStaleTemporarilyUnavailableNativeFullscreenRecords(
            staleInterval: 0
        )
        guard !removedEntries.isEmpty else { return }
        for entry in removedEntries {
            controller.nativeFullscreenPlaceholderManager.remove(entry.token)
        }
        controller.layoutRefreshController.requestRefresh(reason: .activeSpaceChanged)
    }

    func cancelNativeFullscreenLifecycleTasks(for originalToken: WindowToken) {
        pendingNativeFullscreenFollowupTasks.removeValue(forKey: originalToken)?.cancel()
        pendingNativeFullscreenStaleCleanupTasks.removeValue(forKey: originalToken)?.cancel()
    }

    func cancelNativeFullscreenLifecycleTasks(containing token: WindowToken) {
        if let controller,
           let originalToken = controller.workspaceManager.nativeFullscreenRecord(for: token)?.originalToken
        {
            cancelNativeFullscreenLifecycleTasks(for: originalToken)
            return
        }
        cancelNativeFullscreenLifecycleTasks(for: token)
    }

    private func managedReplacementGraceDelay(for policy: ManagedReplacementCorrelationPolicy) -> Duration {
        switch policy {
        case .structural:
            Self.managedReplacementGraceDelay
        }
    }

    private func managedReplacementGraceDelayMillis(for policy: ManagedReplacementCorrelationPolicy) -> Int {
        switch policy {
        case .structural:
            150
        }
    }

    private func scheduleManagedReplacementFlush(
        for key: ManagedReplacementKey,
        policy: ManagedReplacementCorrelationPolicy,
        resetExistingDeadline: Bool
    ) {
        let existingTask = pendingManagedReplacementTasks[key]
        let burst = pendingManagedReplacementBursts[key]
        if resetExistingDeadline {
            existingTask?.cancel()
        } else if existingTask != nil {
            recordManagedReplacementTrace(
                key: key,
                kind: .scheduleManagedReplacementFlush(
                    policy: managedReplacementPolicyName(policy),
                    delayMillis: managedReplacementGraceDelayMillis(for: policy),
                    deadlineReset: false,
                    reusedExistingDeadline: true,
                    createCount: burst?.creates.count ?? 0,
                    destroyCount: burst?.destroys.count ?? 0
                )
            )
            return
        }

        recordManagedReplacementTrace(
            key: key,
            kind: .scheduleManagedReplacementFlush(
                policy: managedReplacementPolicyName(policy),
                delayMillis: managedReplacementGraceDelayMillis(for: policy),
                deadlineReset: resetExistingDeadline,
                reusedExistingDeadline: false,
                createCount: burst?.creates.count ?? 0,
                destroyCount: burst?.destroys.count ?? 0
            )
        )
        let delay = managedReplacementGraceDelay(for: policy)
        pendingManagedReplacementTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushManagedReplacementBurst(for: key)
        }
    }

    private func flushManagedReplacementBurst(for key: ManagedReplacementKey) {
        pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        guard let burst = pendingManagedReplacementBursts.removeValue(forKey: key) else { return }
        let elapsedMillis = max(
            0,
            Int(((managedReplacementCurrentUptime() - burst.firstEventUptime) * 1000).rounded())
        )
        let policyName = managedReplacementPolicyName(burst.policy)
        recordManagedReplacementTrace(
            key: key,
            kind: .flushed(
                policy: policyName,
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                elapsedMillis: elapsedMillis
            )
        )

        if let pair = matchedManagedReplacementPair(in: burst) {
            let rekeyed = completeManagedReplacement(destroy: pair.destroy, create: pair.create)
            let replayedEvents = rekeyed
                ? burst.orderedEvents(excludingSequences: pair.excludedSequences)
                : burst.orderedEvents
            recordManagedReplacementTrace(
                key: key,
                kind: .flushManagedReplacementBurst(
                    policy: policyName,
                    createCount: burst.creates.count,
                    destroyCount: burst.destroys.count,
                    elapsedMillis: elapsedMillis,
                    matched: true,
                    rekeyed: rekeyed,
                    replayedCount: replayedEvents.count
                )
            )
            if rekeyed {
                recordManagedReplacementTrace(
                    key: key,
                    kind: .matched(
                        policy: policyName,
                        elapsedMillis: elapsedMillis
                    )
                )
            }
            replayManagedReplacementEvents(
                replayedEvents,
                key: key,
                reason: rekeyed ? "matched_rekeyed_remainder" : "matched_rekey_failed"
            )
            return
        }

        recordManagedReplacementTrace(
            key: key,
            kind: .flushManagedReplacementBurst(
                policy: policyName,
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                elapsedMillis: elapsedMillis,
                matched: false,
                rekeyed: false,
                replayedCount: burst.orderedEvents.count
            )
        )
        replayManagedReplacementEvents(burst.orderedEvents, key: key, reason: "no_match")
    }

    private func nextManagedReplacementSequence() -> UInt64 {
        defer { nextManagedReplacementEventSequence += 1 }
        return nextManagedReplacementEventSequence
    }

    private func updateManagedReplacementFrame(_ frame: CGRect, for entry: WindowModel.Entry) {
        guard let controller else { return }
        _ = controller.workspaceManager.updateManagedReplacementFrame(frame, for: entry.token)
    }

    private func updateManagedReplacementTitle(windowId: UInt32, token: WindowToken) {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              let title = resolveWindowInfo(windowId)?.title ?? AXWindowService.titlePreferFast(windowId: windowId)
        else {
            return
        }
        _ = controller.workspaceManager.updateManagedReplacementTitle(title, for: entry.token)
    }

    private func scheduleWindowStabilizationRetryIfNeeded(
        token: WindowToken,
        decision: WindowDecision
    ) {
        guard decision.disposition == .undecided,
              decision.deferredReason != nil
        else {
            return
        }

        pendingWindowStabilizationTasks[token]?.cancel()
        pendingWindowStabilizationTasks[token] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled, let self, let controller = self.controller else { return }
            self.pendingWindowStabilizationTasks.removeValue(forKey: token)
            _ = await controller.reevaluateWindowRules(for: [.window(token)])
        }
    }

    private func cancelWindowStabilizationRetry(for token: WindowToken) {
        pendingWindowStabilizationTasks.removeValue(forKey: token)?.cancel()
    }

    private func scheduleCreatedWindowRetryIfNeeded(
        windowId: UInt32,
        pid: pid_t
    ) -> Bool {
        guard let controller else { return false }
        let token = WindowToken(pid: pid, windowId: Int(windowId))
        guard controller.workspaceManager.entry(for: token) == nil else {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            return false
        }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            return false
        }
        guard resolveAXWindowRef(windowId: windowId, pid: pid) == nil else {
            return false
        }

        let attempt = createdWindowRetryCountById[windowId, default: 0] + 1
        guard attempt <= Self.createdWindowRetryLimit else {
            discardCreatePlacementContext(windowId: windowId)
            return false
        }

        enqueueCreatedWindowRetry(
            windowId: windowId,
            attempt: attempt,
            traceKind: .createRetryScheduled(
                windowId: windowId,
                pid: pid,
                attempt: attempt
            )
        )
        return true
    }

    private func scheduleCreatedWindowInfoRetryIfNeeded(windowId: UInt32) -> Bool {
        guard let controller else { return false }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            return false
        }

        let attempt = createdWindowRetryCountById[windowId, default: 0] + 1
        guard attempt <= Self.createdWindowRetryLimit else {
            discardCreatePlacementContext(windowId: windowId)
            return false
        }

        enqueueCreatedWindowRetry(windowId: windowId, attempt: attempt, traceKind: nil)
        return true
    }

    private func enqueueCreatedWindowRetry(
        windowId: UInt32,
        attempt: Int,
        traceKind: NiriCreateFocusTraceEvent.Kind?
    ) {
        createdWindowRetryCountById[windowId] = attempt
        pendingCreatedWindowRetryTasks.removeValue(forKey: windowId)?.cancel()
        if let traceKind {
            recordNiriCreateFocusTrace(.init(kind: traceKind))
        }
        pendingCreatedWindowRetryTasks[windowId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingCreatedWindowRetryTasks.removeValue(forKey: windowId)
            self.processCreatedWindow(windowId: windowId)
        }
    }

    private func cancelCreatedWindowRetry(windowId: UInt32) {
        pendingCreatedWindowRetryTasks.removeValue(forKey: windowId)?.cancel()
        createdWindowRetryCountById.removeValue(forKey: windowId)
    }

    private func resetCreatedWindowRetryState() {
        for (_, task) in pendingCreatedWindowRetryTasks {
            task.cancel()
        }
        pendingCreatedWindowRetryTasks.removeAll()
        createdWindowRetryCountById.removeAll()
    }

    private func captureCreatePlacementContext(windowId: UInt32, spaceId: UInt64) {
        pruneExpiredCreatePlacementContexts()
        guard createPlacementContextsByWindowId[windowId] == nil,
              let controller
        else {
            return
        }

        createPlacementContextsByWindowId[windowId] = makeCreatePlacementContext(
            nativeSpaceMonitorId: resolveNativeSpacePlacementMonitorId(spaceId: spaceId, controller: controller),
            fallbackFocusedWorkspaceId: nil,
            source: "cgs_created",
            controller: controller
        )
    }

    private func ensureCreatePlacementContextForFocusedAdmission(
        windowId: UInt32,
        pid: pid_t
    ) -> WindowCreatePlacementContext? {
        pruneExpiredCreatePlacementContexts()
        if let context = createPlacementContextsByWindowId[windowId] {
            return context
        }
        guard let controller else { return nil }

        let recentPidWorkspaceId = recentManagedWorkspaceId(for: pid)
        let context = makeCreatePlacementContext(
            nativeSpaceMonitorId: nil,
            fallbackFocusedWorkspaceId: recentPidWorkspaceId,
            source: "ax_focused_admission_synthesized",
            recentPidWorkspaceId: recentPidWorkspaceId,
            controller: controller
        )
        createPlacementContextsByWindowId[windowId] = context
        return context
    }

    private func makeCreatePlacementContext(
        nativeSpaceMonitorId: Monitor.ID?,
        fallbackFocusedWorkspaceId: WorkspaceDescriptor.ID?,
        source: String,
        recentPidWorkspaceId: WorkspaceDescriptor.ID? = nil,
        controller: WMController
    ) -> WindowCreatePlacementContext {
        let confirmedFocusedWorkspaceId = resolveFocusedPlacementWorkspaceId(controller: controller)
        let focusedWorkspaceId = confirmedFocusedWorkspaceId ?? fallbackFocusedWorkspaceId
        let focusedWorkspaceSource: String? = if confirmedFocusedWorkspaceId != nil {
            "confirmed_focus"
        } else if fallbackFocusedWorkspaceId != nil {
            "recent_pid"
        } else {
            nil
        }
        return WindowCreatePlacementContext(
            nativeSpaceMonitorId: nativeSpaceMonitorId,
            activeFocusRequestWorkspaceId: controller.workspaceManager.activeFocusRequestWorkspaceId,
            activeFocusRequestMonitorId: resolveActiveFocusRequestPlacementMonitorId(controller: controller),
            focusedWorkspaceId: focusedWorkspaceId,
            focusedMonitorId: focusedWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            },
            interactionMonitorId: controller.workspaceManager.interactionMonitorId,
            source: source,
            focusedWorkspaceSource: focusedWorkspaceSource,
            recentPidWorkspaceId: recentPidWorkspaceId,
            createdAt: Date()
        )
    }

    private func resolveActiveFocusRequestPlacementMonitorId(
        controller: WMController
    ) -> Monitor.ID? {
        controller.workspaceManager.activeFocusRequestMonitorId
            ?? controller.workspaceManager.activeFocusRequestWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            }
    }

    private func resolveFocusedPlacementWorkspaceId(
        controller: WMController
    ) -> WorkspaceDescriptor.ID? {
        guard let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
              let workspaceId = controller.workspaceManager.workspace(for: focusedToken)
        else {
            return nil
        }
        return workspaceId
    }

    private func resolveNativeSpacePlacementMonitorId(
        spaceId: UInt64,
        controller: WMController
    ) -> Monitor.ID? {
        let monitors = controller.workspaceManager.monitors
        let displayId: CGDirectDisplayID?
        if let spaceDisplayResolver {
            displayId = spaceDisplayResolver(spaceId, monitors)
        } else {
            displayId = SkyLight.shared.displayId(forSpaceId: spaceId, among: monitors)
        }
        guard let displayId,
              let monitor = monitors.first(where: { $0.displayId == displayId })
        else {
            return nil
        }

        return monitor.id
    }

    private func discardCreatePlacementContext(windowId: UInt32) {
        createPlacementContextsByWindowId.removeValue(forKey: windowId)
    }

    private func resetCreatePlacementContextState() {
        createPlacementContextsByWindowId.removeAll()
    }

    private func pruneExpiredCreatePlacementContexts(now: Date = Date()) {
        createPlacementContextsByWindowId = createPlacementContextsByWindowId.filter { _, context in
            now.timeIntervalSince(context.createdAt) < Self.createPlacementContextTTL
        }
    }

    private func removeExistingEntryIfCurrentDecisionIsUntracked(
        _ entry: WindowModel.Entry,
        axRef: AXWindowRef,
        appFullscreen: Bool,
        source: ActivationEventSource
    ) -> Bool {
        guard let controller else { return false }
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: entry.pid,
            appFullscreen: appFullscreen,
            traceContext: "activation_existing",
            existingModeForTrace: entry.mode
        )
        guard controller.trackedModePreservingAutomaticFallbackState(
            decision: evaluation.decision,
            existingEntry: entry,
            context: .automatic
        ) == nil else {
            return false
        }

        cleanupTrackedWindowBeforeUnmanagedDemotion(entry)
        _ = controller.workspaceManager.removeWindow(pid: entry.pid, windowId: entry.windowId)
        controller.layoutRefreshController.requestRefresh(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [entry.workspaceId]
        )
        cancelActivationRetry()
        _ = controller.workspaceManager.enterNonManagedFocus(
            appFullscreen: appFullscreenForFallbackLifecyclePreservation(observedAppFullscreen: appFullscreen),
            preserveFocusedToken: true
        )
        recordNonManagedFallbackEntered(pid: entry.pid, source: source)
        return true
    }

    private func cleanupTrackedWindowBeforeUnmanagedDemotion(_ entry: WindowModel.Entry) {
        guard let controller else { return }
        controller.cleanupScratchpadWindowResourcesIfNeeded(for: entry.token)
        controller.nativeFullscreenPlaceholderManager.remove(entry.token)
        controller.clearKeyboardFocusTarget(matching: entry.token, restoreCurrentBorder: true)
    }

    private func handleMissingFocusedWindow(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        requestDisposition: ActivationRequestDisposition
    ) {
        guard let controller else { return }

        switch requestDisposition {
        case let .matchesActiveRequest(request),
             let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                source: source,
                origin: origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                break
            }
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .missingFocusedWindow
            )
            return
        case .unrelatedNoRequest:
            break
        }

        // Dropdown/quick-terminal close paths can report focused-window=nil
        // without destroying the managed window. Reuse close recovery so the
        // native successor activation does not pull us to another workspace.
        let focusedTokenBeforeFallback = controller.workspaceManager.confirmedManagedFocusToken
        var precursorWorkspaceId: WorkspaceDescriptor.ID?
        if source == .focusedWindowChanged,
           let focusedTokenBeforeFallback,
           focusedTokenBeforeFallback.pid == pid,
           let workspaceId = controller.workspaceManager.workspace(for: focusedTokenBeforeFallback)
        {
            recordFocusedWindowLossClosePrecursor(
                pid: pid,
                workspaceId: workspaceId,
                preservedToken: focusedTokenBeforeFallback
            )
            precursorWorkspaceId = workspaceId
        } else if source == .focusedWindowChanged,
                  controller.workspaceManager.isNonManagedFocusActive,
                  let workspaceId = controller.interactionWorkspace()?.id
        {
            recordFocusedWindowLossClosePrecursor(
                pid: pid,
                workspaceId: workspaceId,
                preservedToken: focusedTokenBeforeFallback
            )
            precursorWorkspaceId = workspaceId
        }
        armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded(
            pid: pid,
            source: source,
            preservedToken: focusedTokenBeforeFallback
        )
        if let traceWorkspaceId = precursorWorkspaceId ?? controller.interactionWorkspace()?.id {
            controller.diagnostics.recordRuntimeViewportTrace(
                workspaceId: traceWorkspaceId,
                reason: "close_recovery_focused_window_nil",
                details: [
                    "pid=\(pid)",
                    "source=\(source.rawValue)",
                    "origin=\(origin.rawValue)",
                    "requestDisposition=\(requestDisposition)",
                    "preservedToken=\(focusedTokenBeforeFallback.map(String.init(describing:)) ?? "nil")",
                    "precursorArmed=\(precursorWorkspaceId != nil)",
                    "recoveryWorkspace=\(activeWindowCloseFocusRecoveryContext()?.workspaceId.uuidString ?? "nil")"
                ]
            )
        }

        cancelActivationRetry()
        let fallbackFullscreen = appFullscreenForFallbackLifecyclePreservation(
            observedAppFullscreen: false
        )
        _ = controller.workspaceManager.enterNonManagedFocus(
            appFullscreen: fallbackFullscreen,
            preserveFocusedToken: false
        )
        recordNonManagedFallbackEntered(pid: pid, source: source)
        controller.focusBorderController.clear()
    }

    private func appFullscreenForFallbackLifecyclePreservation(
        observedAppFullscreen: Bool
    ) -> Bool {
        guard let controller else { return observedAppFullscreen }

        let hasLifecycleContext = controller.workspaceManager.hasNativeFullscreenLifecycleContext
        return observedAppFullscreen || hasLifecycleContext
    }

    private func activationRequestDisposition(
        for pid: pid_t,
        token: WindowToken?,
        activeRequest: ManagedFocusRequest?
    ) -> ActivationRequestDisposition {
        guard let activeRequest else { return .unrelatedNoRequest }
        guard activeRequest.token.pid == pid else {
            return .conflictsWithPendingRequest(activeRequest)
        }
        guard let token else {
            return .matchesActiveRequest(activeRequest)
        }
        return activeRequest.token == token
            ? .matchesActiveRequest(activeRequest)
            : .conflictsWithPendingRequest(activeRequest)
    }

    private func shouldHandleObservedManagedActivationWithoutPendingRequest(
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        isWorkspaceActive: Bool
    ) -> Bool {
        guard !isWorkspaceActive else { return true }

        switch source {
        case .focusedWindowChanged:
            return true
        case .workspaceDidActivateApplication,
             .cgsFrontAppChanged:
            return origin == .external || origin == .retry
        }
    }

    private func shouldHonorObservedFocusOverPendingRequest(
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        source.isAuthoritative && origin == .external
    }

    func cleanupFocusStateForTerminatedApp(pid: pid_t) {
        recentManagedWorkspaceByPid.removeValue(forKey: pid)
        recentAppActivationByPid.removeValue(forKey: pid)

        guard let controller else { return }

        let entries = controller.workspaceManager.entries(forPid: pid)
        for entry in entries {
            clearManagedFocusState(
                matching: entry.token,
                workspaceId: entry.workspaceId
            )
        }

        if let activeRequest = controller.focusBridge.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            clearManagedFocusState(
                matching: activeRequest.token,
                workspaceId: activeRequest.workspaceId
            )
        }

        controller.clearKeyboardFocusTarget(pid: pid, restoreCurrentBorder: false)
    }

    private func clearManagedFocusState(
        matching token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let controller else { return }

        controller.focusBridge.discardPendingFocus(token)
        let canceledRequest = controller.focusBridge.cancelManagedRequest(
            matching: token,
            workspaceId: workspaceId
        )
        _ = controller.workspaceManager.cancelManagedFocusRequest(
            matching: token,
            workspaceId: workspaceId
        )
        if let canceledRequest {
            cancelActivationRetry(requestId: canceledRequest.requestId)
        }
        controller.clearKeyboardFocusTarget(
            matching: token,
            restoreCurrentBorder: false
        )
    }

    private func continueManagedFocusRequest(
        _ request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        reason: ActivationRetryReason
    ) {
        if scheduleActivationRetryIfNeeded(
            request: request,
            source: source,
            origin: origin,
            reason: reason
        ) {
            return
        }
        guard origin != .probe else {
            return
        }
        handleActivationRetryExhausted(
            request: request,
            source: source,
            origin: origin
        )
    }

    private func scheduleActivationRetryIfNeeded(
        request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        reason: ActivationRetryReason
    ) -> Bool {
        guard let controller,
              let updatedRequest = controller.focusBridge.recordRetry(
                  requestId: request.requestId,
                  source: source,
                  retryLimit: Self.activationRetryLimit
              )
        else {
            return false
        }

        cancelActivationRetry()
        pendingActivationRetryRequestId = updatedRequest.requestId
        recordNiriCreateFocusTrace(
            .init(
                kind: .activationDeferred(
                    requestId: updatedRequest.requestId,
                    token: updatedRequest.token,
                    source: source,
                    reason: reason,
                    attempt: updatedRequest.retryCount
                )
            )
        )
        let retryOrigin: ActivationCallOrigin = origin == .probe ? .probe : .retry
        pendingActivationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled, let self else { return }
            let requestId = updatedRequest.requestId
            guard self.pendingActivationRetryRequestId == requestId else { return }
            self.pendingActivationRetryTask = nil
            self.pendingActivationRetryRequestId = nil
            guard let controller = self.controller,
                  let liveRequest = controller.focusBridge.activeManagedRequest(requestId: requestId)
            else {
                return
            }
            self.handleAppActivation(
                pid: liveRequest.token.pid,
                source: source,
                origin: retryOrigin
            )
        }
        return true
    }

    private func handleActivationRetryExhausted(
        request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) {
        guard let controller else { return }

        cancelActivationRetry(requestId: request.requestId)
        _ = controller.focusBridge.cancelManagedRequest(requestId: request.requestId)
        _ = controller.workspaceManager.cancelManagedFocusRequest(
            matching: request.token,
            workspaceId: request.workspaceId
        )

        if let target = controller.currentBorderTarget(),
           controller.focusBorderController.refresh(
               preferredFrame: controller.preferredKeyboardFocusFrame(for: target.token),
               forceOrdering: true
           )
        {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .borderReapplied(
                        token: target.token,
                        phase: .retryExhaustedFallback
                    )
                )
            )
        } else {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .nonManagedFallbackEntered(
                        pid: request.token.pid,
                        source: source
                    )
                )
            )
            controller.focusBorderController.hide()
        }
    }

    private func cancelActivationRetry() {
        pendingActivationRetryTask?.cancel()
        pendingActivationRetryTask = nil
        pendingActivationRetryRequestId = nil
    }

    private func cancelActivationRetry(requestId: UInt64) {
        guard pendingActivationRetryRequestId == requestId else { return }
        cancelActivationRetry()
    }

    private func resetActivationRetryState() {
        cancelActivationRetry()
    }

    private func deferCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.insert(windowId).inserted else { return }
        deferredCreatedWindowOrder.append(windowId)
    }

    private func removeDeferredCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.remove(windowId) != nil else { return }
        deferredCreatedWindowOrder.removeAll { $0 == windowId }
    }

    private func resolveWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        if let windowInfoProvider {
            if let info = windowInfoProvider(windowId) {
                return info
            }
            if windowInfoProviderIsAuthoritativeForTests {
                return nil
            }
        }
        return SkyLight.shared.queryWindowInfo(windowId)
    }

    private func resolveWindowToken(_ windowId: UInt32) -> WindowToken? {
        guard let windowInfo = resolveWindowInfo(windowId) else { return nil }
        return .init(pid: windowInfo.pid, windowId: Int(windowId))
    }

    private func resolveTrackedToken(
        _ windowId: UInt32,
        resolvedWindowToken: WindowToken? = nil
    ) -> WindowToken? {
        if let token = resolvedWindowToken ?? resolveWindowToken(windowId) {
            return token
        }
        guard let controller else { return nil }
        let matches = controller.workspaceManager.allEntries().filter { $0.windowId == Int(windowId) }
        guard matches.count == 1 else { return nil }
        return matches[0].token
    }

    private func resolveAXWindowRef(windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        axWindowRefProvider?(windowId, pid) ?? AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    private func resolveAXWindowRef(
        windowId: UInt32,
        pid: pid_t,
        matching windowInfo: WindowServerInfo?
    ) -> AXWindowRef? {
        if let provided = axWindowRefProvider?(windowId, pid) {
            return provided
        }
        return AXWindowService.axWindowRef(for: windowId, pid: pid, matching: windowInfo)
    }

    private func subscribeToWindows(_ windowIds: [UInt32]) {
        if let windowSubscriptionHandler {
            windowSubscriptionHandler(windowIds)
            return
        }
        CGSEventObserver.shared.subscribeToWindows(windowIds)
    }

    private func resolveFocusedWindowValue(pid: pid_t) -> CFTypeRef? {
        if let focusedWindowValueProvider {
            return focusedWindowValueProvider(pid)
        }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success else { return nil }
        return focusedWindow
    }

    private func resolveFocusedAXWindowRef(pid: pid_t) -> AXWindowRef? {
        if let focusedWindowRefProvider {
            return focusedWindowRefProvider(pid)
        }
        guard let windowElement = resolveFocusedWindowValue(pid: pid) else {
            return nil
        }
        guard CFGetTypeID(windowElement) == AXUIElementGetTypeID() else {
            return nil
        }
        let axElement = unsafeDowncast(windowElement, to: AXUIElement.self)
        return try? AXWindowRef(element: axElement)
    }

    private func resolveBundleId(_ pid: pid_t) -> String? {
        guard let controller else { return nil }
        if let bundleIdProvider {
            return bundleIdProvider(pid)
        }
        return controller.appInfoCache.bundleId(for: pid) ?? NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier
    }
}
