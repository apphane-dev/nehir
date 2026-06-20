// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

extension NiriLayoutEngine {
    func ensureMonitor(
        for monitorId: Monitor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation? = nil
    ) -> NiriMonitor {
        if let existing = monitors[monitorId] {
            if let orientation {
                existing.updateOrientation(orientation)
            }
            return existing
        }
        let niriMonitor = NiriMonitor(monitor: monitor, orientation: orientation)
        monitors[monitorId] = niriMonitor
        return niriMonitor
    }

    func monitor(for monitorId: Monitor.ID) -> NiriMonitor? {
        monitors[monitorId]
    }

    func updateMonitors(_ newMonitors: [Monitor], orientations: [Monitor.ID: Monitor.Orientation] = [:]) {
        for monitor in newMonitors {
            if let niriMonitor = monitors[monitor.id] {
                let orientation = orientations[monitor.id]
                niriMonitor.updateOutputSize(monitor: monitor, orientation: orientation)
            }
        }

        let newIds = Set(newMonitors.map(\.id))
        monitors = monitors.filter { newIds.contains($0.key) }
        workspaceMonitorIndex = workspaceMonitorIndex.filter { newIds.contains($0.value) }
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        monitors.removeValue(forKey: monitorId)
        workspaceMonitorIndex = workspaceMonitorIndex.filter { $0.value != monitorId }
    }

    func updateMonitorOrientations(_ orientations: [Monitor.ID: Monitor.Orientation]) {
        for (monitorId, orientation) in orientations {
            monitors[monitorId]?.updateOrientation(orientation)
        }
    }

    func updateMonitorSettings(_ settings: ResolvedNiriSettings, for monitorId: Monitor.ID) {
        monitors[monitorId]?.resolvedSettings = settings
    }

    func globalResolvedSettings() -> ResolvedNiriSettings {
        ResolvedNiriSettings(
            defaultColumnWidth: defaultColumnWidth.map { .custom(fraction: Double($0)) }
                ?? .balanced(columns: balancedColumnCount),
            loneWindowPolicy: loneWindowPolicy,
            infiniteLoop: infiniteLoop
        )
    }

    func effectiveSettings(for monitorId: Monitor.ID) -> ResolvedNiriSettings {
        monitors[monitorId]?.resolvedSettings ?? globalResolvedSettings()
    }

    func effectiveSettings(in workspaceId: WorkspaceDescriptor.ID) -> ResolvedNiriSettings {
        guard let monitorId = monitorContaining(workspace: workspaceId) else {
            return globalResolvedSettings()
        }
        return effectiveSettings(for: monitorId)
    }

    func displayScale(in workspaceId: WorkspaceDescriptor.ID) -> CGFloat {
        monitorForWorkspace(workspaceId)?.scale ?? 2.0
    }

    func effectiveDefaultColumnWidth(for monitorId: Monitor.ID) -> DefaultColumnWidth {
        effectiveSettings(for: monitorId).defaultColumnWidth
    }

    func effectiveDefaultColumnWidth(in workspaceId: WorkspaceDescriptor.ID) -> DefaultColumnWidth {
        effectiveSettings(in: workspaceId).defaultColumnWidth
    }

    func effectiveLoneWindowPolicy(for monitorId: Monitor.ID) -> LoneWindowPolicy {
        effectiveSettings(for: monitorId).loneWindowPolicy
    }

    func effectiveLoneWindowPolicy(in workspaceId: WorkspaceDescriptor.ID) -> LoneWindowPolicy {
        effectiveSettings(in: workspaceId).loneWindowPolicy
    }

    func effectiveInfiniteLoop(for monitorId: Monitor.ID) -> Bool {
        effectiveSettings(for: monitorId).infiniteLoop
    }

    func effectiveInfiniteLoop(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        effectiveSettings(in: workspaceId).infiniteLoop
    }

    /// Reassign a single workspace without pruning unrelated workspaces
    /// that are omitted from the request.
    func moveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        to monitorId: Monitor.ID,
        monitor: Monitor
    ) {
        let targetMonitor = ensureMonitor(for: monitorId, monitor: monitor)
        removeWorkspaceRootCopies(workspaceId, keepingMonitorId: targetMonitor.id)
        attachWorkspaceRootIfNeeded(workspaceId, to: targetMonitor)
    }

    /// Reconcile the authoritative full workspace-to-monitor assignment set
    /// during monitor sync and prune stale duplicate roots.
    func syncWorkspaceAssignments(
        _ assignments: [(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)],
        orientations: [Monitor.ID: Monitor.Orientation] = [:]
    ) {
        let validMonitorIds = orientations.isEmpty ? nil : Set(orientations.keys)
        let validAssignments = assignments.filter { assignment in
            validMonitorIds?.contains(assignment.monitor.id) ?? true
        }

        var desiredOwners: [WorkspaceDescriptor.ID: Monitor.ID] = [:]
        desiredOwners.reserveCapacity(validAssignments.count)

        for assignment in validAssignments {
            _ = ensureMonitor(
                for: assignment.monitor.id,
                monitor: assignment.monitor,
                orientation: orientations[assignment.monitor.id]
            )
            desiredOwners[assignment.workspaceId] = assignment.monitor.id
        }

        pruneStaleWorkspaceRootCopies(desiredOwners: desiredOwners)

        for assignment in validAssignments where desiredOwners[assignment.workspaceId] == assignment.monitor.id {
            let targetMonitor = monitors[assignment.monitor.id] ?? ensureMonitor(
                for: assignment.monitor.id,
                monitor: assignment.monitor,
                orientation: orientations[assignment.monitor.id]
            )
            attachWorkspaceRootIfNeeded(assignment.workspaceId, to: targetMonitor)
        }
    }

    func monitorContaining(workspace workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        guard let monitorId = workspaceMonitorIndex[workspaceId],
              monitors[monitorId]?.containsWorkspace(workspaceId) == true
        else {
            workspaceMonitorIndex.removeValue(forKey: workspaceId)
            return nil
        }
        return monitorId
    }

    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> NiriMonitor? {
        guard let monitorId = monitorContaining(workspace: workspaceId) else { return nil }
        return monitors[monitorId]
    }

    private func attachWorkspaceRootIfNeeded(
        _ workspaceId: WorkspaceDescriptor.ID,
        to targetMonitor: NiriMonitor
    ) {
        // The root is a per-workspace singleton, so a no-op attach (target monitor
        // already holds the same root) must still refresh the ownership index: callers
        // like syncWorkspaceAssignments/moveWorkspace rely on this to rebuild the
        // cache after updateMonitors/cleanupRemovedMonitor clear an entry for a
        // disconnected monitor while a surviving duplicate root keeps workspaceRoots
        // correct. Without this, monitorContaining returns nil for an attached
        // workspace, breaking monitor-scoped settings, display scale, and reveal.
        let root = ensureRoot(for: workspaceId)
        if targetMonitor.workspaceRoots[workspaceId] !== root {
            targetMonitor.workspaceRoots[workspaceId] = root
        }
        workspaceMonitorIndex[workspaceId] = targetMonitor.id
    }

    private func pruneStaleWorkspaceRootCopies(
        desiredOwners: [WorkspaceDescriptor.ID: Monitor.ID]
    ) {
        for niriMonitor in monitors.values {
            let staleWorkspaceIds = Array(
                niriMonitor.workspaceRoots.keys.filter { workspaceId in
                    desiredOwners[workspaceId] != niriMonitor.id
                }
            )
            for workspaceId in staleWorkspaceIds {
                niriMonitor.workspaceRoots.removeValue(forKey: workspaceId)
                if workspaceMonitorIndex[workspaceId] == niriMonitor.id {
                    workspaceMonitorIndex.removeValue(forKey: workspaceId)
                }
            }
        }
    }

    private func removeWorkspaceRootCopies(
        _ workspaceId: WorkspaceDescriptor.ID,
        keepingMonitorId: Monitor.ID? = nil
    ) {
        for niriMonitor in monitors.values where niriMonitor.id != keepingMonitorId {
            niriMonitor.workspaceRoots.removeValue(forKey: workspaceId)
        }
        if keepingMonitorId == nil || workspaceMonitorIndex[workspaceId] != keepingMonitorId {
            workspaceMonitorIndex.removeValue(forKey: workspaceId)
        }
    }
}
