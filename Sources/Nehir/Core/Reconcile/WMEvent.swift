// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation

enum WMEventSource: String, Equatable {
    case ax
    case workspaceManager
    case service
    case command
    case mouse
    case focusPolicy
}

/// Why a `windowAdmitted` event fired — diagnostic only, does not affect
/// admission decisions. Added to confirm/refute the hypothesis (see
/// `plans/discovery/20260701-startup-full-rescan-under-enumerates-multi-window-app.md`
/// and `plans/discovery/20260630-visible-unmanaged-windows-admitted-late-as-columns.md`)
/// that a multi-window app's first per-app AX windows query can under-report
/// its windows, leaving the rest to be admitted late by an incidental event.
enum WindowAdmissionContext: String, Equatable {
    /// Admitted by the startup/full-rescan path
    /// (`AXManager.fullRescanEnumerationSnapshot()`).
    case startupFullRescan = "startup_full_rescan"
    /// Admitted by `WMController.reevaluateWindowRules`'s `.pid` target —
    /// a fresh whole-pid AX windows query swept this token in.
    case pidReevaluation = "pid_reevaluation"
    /// Admitted by `WMController.reevaluateWindowRules`'s `.window` target —
    /// single-token rule reevaluation, not a pid-wide re-query.
    case windowRuleReevaluation = "window_rule_reevaluation"
    /// Admitted via `admitFocusedWindowBeforeNonManagedFallback` — the window
    /// took AX focus before Nehir otherwise knew about it.
    case focusedAdmission = "focused_admission"
    /// Admitted via the normal CGS-create pipeline (`trackPreparedCreate`'s
    /// default path — a real `.created` event, deferred-create replay, or a
    /// managed-replacement-delayed create).
    case windowCreate = "window_create"
    /// Reserved for the Phase 2-3 confirm-after-admission re-query
    /// (see the plan above) — not yet emitted by any code path.
    case axContextConfirmation = "ax_context_confirmation"
    /// Call sites (mostly tests) that have not been threaded with a specific
    /// admission context.
    case unspecified
}

enum WMEvent: Equatable {
    case windowAdmitted(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode,
        source: WMEventSource,
        admissionContext: WindowAdmissionContext
    )
    case windowRekeyed(
        from: WindowToken,
        to: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        reason: ReplacementCorrelation.Reason,
        source: WMEventSource
    )
    case windowRemoved(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?,
        source: WMEventSource
    )
    case workspaceAssigned(
        token: WindowToken,
        from: WorkspaceDescriptor.ID?,
        to: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        source: WMEventSource
    )
    case windowModeChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode,
        source: WMEventSource
    )
    case floatingGeometryUpdated(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        referenceMonitorId: Monitor.ID?,
        frame: CGRect,
        restoreToFloating: Bool,
        source: WMEventSource
    )
    case hiddenStateChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        hiddenState: WindowModel.HiddenState?,
        source: WMEventSource
    )
    case nativeFullscreenTransition(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        isActive: Bool,
        source: WMEventSource
    )
    case managedReplacementMetadataChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        source: WMEventSource
    )
    case topologyChanged(
        displays: [DisplayFingerprint],
        source: WMEventSource
    )
    case activeSpaceChanged(source: WMEventSource)
    case focusLeaseChanged(
        lease: FocusPolicyLease?,
        source: WMEventSource
    )
    case managedFocusRequested(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        source: WMEventSource
    )
    case managedFocusConfirmed(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        appFullscreen: Bool,
        source: WMEventSource
    )
    case managedFocusCancelled(
        token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        source: WMEventSource
    )
    case nonManagedFocusChanged(
        active: Bool,
        appFullscreen: Bool,
        preserveFocusedToken: Bool,
        preservePendingManagedFocus: Bool,
        source: WMEventSource
    )
    case systemSleep(source: WMEventSource)
    case systemWake(source: WMEventSource)

    var token: WindowToken? {
        switch self {
        case let .windowAdmitted(token, _, _, _, _, _),
             let .windowRemoved(token, _, _),
             let .workspaceAssigned(token, _, _, _, _),
             let .windowModeChanged(token, _, _, _, _),
             let .floatingGeometryUpdated(token, _, _, _, _, _),
             let .hiddenStateChanged(token, _, _, _, _),
             let .nativeFullscreenTransition(token, _, _, _, _),
             let .managedReplacementMetadataChanged(token, _, _, _),
             let .managedFocusRequested(token, _, _, _),
             let .managedFocusConfirmed(token, _, _, _, _):
            token
        case let .windowRekeyed(_, to, _, _, _, _):
            to
        case let .managedFocusCancelled(token, _, _):
            token
        case .topologyChanged,
             .activeSpaceChanged,
             .focusLeaseChanged,
             .nonManagedFocusChanged,
             .systemSleep,
             .systemWake:
            nil
        }
    }

    var source: WMEventSource {
        switch self {
        case let .windowAdmitted(_, _, _, _, source, _),
             let .windowRekeyed(_, _, _, _, _, source),
             let .windowRemoved(_, _, source),
             let .workspaceAssigned(_, _, _, _, source),
             let .windowModeChanged(_, _, _, _, source),
             let .floatingGeometryUpdated(_, _, _, _, _, source),
             let .hiddenStateChanged(_, _, _, _, source),
             let .nativeFullscreenTransition(_, _, _, _, source),
             let .managedReplacementMetadataChanged(_, _, _, source),
             let .topologyChanged(_, source),
             let .activeSpaceChanged(source),
             let .focusLeaseChanged(_, source),
             let .managedFocusRequested(_, _, _, source),
             let .managedFocusConfirmed(_, _, _, _, source),
             let .managedFocusCancelled(_, _, source),
             let .nonManagedFocusChanged(_, _, _, _, source),
             let .systemSleep(source),
             let .systemWake(source):
            source
        }
    }

    var summary: String {
        switch self {
        case let .windowAdmitted(token, workspaceId, _, mode, _, admissionContext):
            "window_admitted token=\(token) workspace=\(workspaceId.uuidString) mode=\(mode) context=\(admissionContext.rawValue)"
        case let .windowRekeyed(from, to, workspaceId, _, reason, _):
            "window_rekeyed from=\(from) to=\(to) workspace=\(workspaceId.uuidString) reason=\(reason.rawValue)"
        case let .windowRemoved(token, workspaceId, _):
            "window_removed token=\(token) workspace=\(workspaceId?.uuidString ?? "nil")"
        case let .workspaceAssigned(token, from, to, _, _):
            "workspace_assigned token=\(token) from=\(from?.uuidString ?? "nil") to=\(to.uuidString)"
        case let .windowModeChanged(token, workspaceId, _, mode, _):
            "window_mode_changed token=\(token) workspace=\(workspaceId.uuidString) mode=\(mode)"
        case let .floatingGeometryUpdated(token, workspaceId, _, frame, restoreToFloating, _):
            "floating_geometry_updated token=\(token) workspace=\(workspaceId.uuidString) frame=\(frame.debugDescription) restore=\(restoreToFloating)"
        case let .hiddenStateChanged(token, workspaceId, _, hiddenState, _):
            "hidden_state_changed token=\(token) workspace=\(workspaceId.uuidString) hidden=\(hiddenState != nil)"
        case let .nativeFullscreenTransition(token, workspaceId, _, isActive, _):
            "native_fullscreen token=\(token) workspace=\(workspaceId.uuidString) active=\(isActive)"
        case let .managedReplacementMetadataChanged(token, workspaceId, monitorId, _):
            "managed_replacement_metadata_changed token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId))"
        case let .topologyChanged(displays, _):
            "topology_changed displays=\(displays.count)"
        case .activeSpaceChanged:
            "active_space_changed"
        case let .focusLeaseChanged(lease, _):
            "focus_lease_changed owner=\(lease?.owner.rawValue ?? "nil") reason=\(lease?.reason ?? "")"
        case let .managedFocusRequested(token, workspaceId, monitorId, _):
            "managed_focus_requested token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId))"
        case let .managedFocusConfirmed(token, workspaceId, monitorId, appFullscreen, _):
            "managed_focus_confirmed token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId)) fullscreen=\(appFullscreen)"
        case let .managedFocusCancelled(token, workspaceId, _):
            "managed_focus_cancelled token=\(token.map(String.init(describing:)) ?? "nil") workspace=\(workspaceId?.uuidString ?? "nil")"
        case let .nonManagedFocusChanged(active, appFullscreen, preserveFocusedToken, preservePendingManagedFocus, _):
            "non_managed_focus_changed active=\(active) fullscreen=\(appFullscreen) preserve=\(preserveFocusedToken) preserve_pending=\(preservePendingManagedFocus)"
        case .systemSleep:
            "system_sleep"
        case .systemWake:
            "system_wake"
        }
    }
}
