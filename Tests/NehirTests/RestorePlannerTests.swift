// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir
import Testing

private func makeRestorePlannerMetadata(
    bundleId: String? = "com.example.editor",
    workspaceId: WorkspaceDescriptor.ID = WorkspaceDescriptor.ID(),
    mode: TrackedWindowMode = .tiling,
    title: String? = "Document",
    frame: CGRect? = nil
) -> ManagedReplacementMetadata {
    ManagedReplacementMetadata(
        bundleId: bundleId,
        workspaceId: workspaceId,
        mode: mode,
        role: "AXWindow",
        subrole: "AXStandardWindow",
        title: title,
        windowLevel: 0,
        parentWindowId: nil,
        frame: frame
    )
}

private func makeRestorePlannerCatalogEntry(
    token: WindowToken,
    metadata: ManagedReplacementMetadata,
    workspaceName: String,
    monitor: Monitor,
    includeIdentity: Bool = true,
    floatingFrame: CGRect? = CGRect(x: 120, y: 140, width: 900, height: 600),
    restoreToFloating: Bool = true
) -> PersistedWindowRestoreEntry {
    PersistedWindowRestoreEntry(
        key: PersistedWindowRestoreKey(metadata: metadata)!,
        identity: includeIdentity ? PersistedWindowRestoreIdentity(token: token, metadata: metadata) : nil,
        restoreIntent: PersistedRestoreIntent(
            workspaceName: workspaceName,
            topologyProfile: TopologyProfile(monitors: [monitor]),
            preferredMonitor: DisplayFingerprint(monitor: monitor),
            floatingFrame: floatingFrame,
            normalizedFloatingOrigin: CGPoint(x: 0.1, y: 0.2),
            restoreToFloating: restoreToFloating,
            rescueEligible: true
        )
    )
}

struct RestorePlannerTests {
    @Test func monitorConfigurationMigrationDoesNotOverwriteFocusedWorkspaceAssignment() {
        let planner = RestorePlanner()
        let survivingMonitor = makeLayoutPlanTestMonitor(
            displayId: 710,
            name: "Built-in",
            x: 0,
            y: 0,
            width: 1728,
            height: 1117
        )
        let removedMonitor = makeLayoutPlanTestMonitor(
            displayId: 711,
            name: "External",
            x: 1728,
            y: 0,
            width: 1920,
            height: 1080
        )
        let focusedWorkspaceId = WorkspaceDescriptor.ID()
        let migratedWorkspaceId = WorkspaceDescriptor.ID()
        let focusedToken = WindowToken(pid: 710, windowId: 1)
        let snapshot = ReconcileSnapshot(
            topologyProfile: TopologyProfile(monitors: [survivingMonitor, removedMonitor]),
            focusSession: FocusSessionSnapshot(
                focusedToken: focusedToken,
                pendingManagedFocus: .empty,
                focusLease: nil,
                isNonManagedFocusActive: false,
                isAppFullscreenActive: false,
                interactionMonitorId: survivingMonitor.id,
                previousInteractionMonitorId: nil
            ),
            windows: [
                ReconcileWindowSnapshot(
                    token: focusedToken,
                    workspaceId: focusedWorkspaceId,
                    mode: .tiling,
                    lifecyclePhase: .tiled,
                    observedState: .initial(workspaceId: focusedWorkspaceId, monitorId: survivingMonitor.id),
                    desiredState: .initial(
                        workspaceId: focusedWorkspaceId,
                        monitorId: survivingMonitor.id,
                        disposition: .tiling
                    ),
                    restoreIntent: nil,
                    replacementCorrelation: nil
                )
            ]
        )

        let plan = planner.planMonitorConfigurationChange(
            .init(
                snapshot: snapshot,
                previousMonitors: [survivingMonitor, removedMonitor],
                newMonitors: [survivingMonitor],
                visibleWorkspaceMap: [
                    survivingMonitor.id: focusedWorkspaceId,
                    removedMonitor.id: migratedWorkspaceId
                ],
                disconnectedVisibleWorkspaceCache: [:],
                interactionMonitorId: survivingMonitor.id,
                previousInteractionMonitorId: nil,
                workspaceExists: { $0 == focusedWorkspaceId || $0 == migratedWorkspaceId },
                homeMonitorId: { workspaceId, _ in
                    workspaceId == focusedWorkspaceId ? survivingMonitor.id : nil
                },
                effectiveMonitorId: { _, _ in survivingMonitor.id }
            )
        )

        #expect(plan.visibleAssignments[survivingMonitor.id] == focusedWorkspaceId)
        #expect(plan.disconnectedVisibleWorkspaceCache.values.contains(migratedWorkspaceId))
    }

    @Test func hardIdentityHydrationWinsWhenSemanticKeyIsDuplicated() throws {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 700, name: "Main")
        let originalWorkspaceId = WorkspaceDescriptor.ID()
        let restoredWorkspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(workspaceId: originalWorkspaceId, title: "Shared")
        let firstToken = WindowToken(pid: 701, windowId: 11)
        let secondToken = WindowToken(pid: 702, windowId: 22)
        let firstEntry = makeRestorePlannerCatalogEntry(
            token: firstToken,
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor
        )
        let secondEntry = makeRestorePlannerCatalogEntry(
            token: secondToken,
            metadata: metadata,
            workspaceName: "2",
            monitor: monitor
        )

        let plan = try #require(
            planner.planPersistedHydration(
                .init(
                    token: secondToken,
                    metadata: metadata,
                    catalog: PersistedWindowRestoreCatalog(entries: [firstEntry, secondEntry]),
                    consumedEntries: [],
                    monitors: [monitor],
                    workspaceIdForName: { name in
                        ["1": originalWorkspaceId, "2": restoredWorkspaceId][name]
                    }
                )
            )
        )

        #expect(plan.persistedEntry == secondEntry)
        #expect(plan.workspaceId == restoredWorkspaceId)
        #expect(plan.consumedEntry == PersistedWindowRestoreConsumptionKey(entry: secondEntry))
    }

    @Test func ignoringMonitorIdentityRestoresWindowByPositionNotName() throws {
        let planner = RestorePlanner()
        // Saved on the right-hand monitor named "Shared".
        let savedMonitor = makeLayoutPlanTestMonitor(displayId: 100, name: "Shared", x: 1920, y: 0)
        // A different monitor now occupies the saved name on the LEFT, while the RIGHT position
        // is held by a differently-named display — the window must follow the position.
        let leftSameName = makeLayoutPlanTestMonitor(displayId: 1, name: "Shared", x: 0, y: 0)
        let rightDifferentName = makeLayoutPlanTestMonitor(displayId: 200, name: "Office", x: 1920, y: 0)
        let currentMonitors = [leftSameName, rightDifferentName]

        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 900, windowId: 90)
        let metadata = makeRestorePlannerMetadata(workspaceId: workspaceId, title: "Doc")
        let entry = makeRestorePlannerCatalogEntry(
            token: token,
            metadata: metadata,
            workspaceName: "1",
            monitor: savedMonitor
        )

        func planMonitor(ignoreIdentity: Bool) throws -> Monitor.ID? {
            let plan = try #require(
                planner.planPersistedHydration(
                    .init(
                        token: token,
                        metadata: metadata,
                        catalog: PersistedWindowRestoreCatalog(entries: [entry]),
                        consumedEntries: [],
                        monitors: currentMonitors,
                        ignoreMonitorIdentity: ignoreIdentity,
                        workspaceIdForName: { _ in workspaceId }
                    )
                )
            )
            return plan.preferredMonitorId
        }

        // Identity on: name match wins, sending the window to the wrong (left) monitor.
        #expect(try planMonitor(ignoreIdentity: false) == leftSameName.id)
        // Identity ignored: layout position wins, keeping the window on the right monitor.
        #expect(try planMonitor(ignoreIdentity: true) == rightDifferentName.id)
    }

    @Test func semanticHydrationReturnsNilWhenFallbackIsAmbiguous() {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 701, name: "Main")
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(workspaceId: workspaceId, title: "Shared")
        let firstEntry = makeRestorePlannerCatalogEntry(
            token: WindowToken(pid: 711, windowId: 11),
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor,
            includeIdentity: false
        )
        let secondEntry = makeRestorePlannerCatalogEntry(
            token: WindowToken(pid: 712, windowId: 22),
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor,
            includeIdentity: false
        )

        let plan = planner.planPersistedHydration(
            .init(
                token: WindowToken(pid: 713, windowId: 33),
                metadata: metadata,
                catalog: PersistedWindowRestoreCatalog(entries: [firstEntry, secondEntry]),
                consumedEntries: [],
                monitors: [monitor],
                workspaceIdForName: { _ in workspaceId }
            )
        )

        #expect(plan == nil)
    }

    @Test func consumedPersistedEntryBlocksReuseWithoutBlockingSameKeyIdentityMatch() throws {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 702, name: "Main")
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(workspaceId: workspaceId, title: "Shared")
        let firstToken = WindowToken(pid: 721, windowId: 11)
        let secondToken = WindowToken(pid: 722, windowId: 22)
        let firstEntry = makeRestorePlannerCatalogEntry(
            token: firstToken,
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor
        )
        let secondEntry = makeRestorePlannerCatalogEntry(
            token: secondToken,
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor
        )

        let reusedPlan = planner.planPersistedHydration(
            .init(
                token: firstToken,
                metadata: metadata,
                catalog: PersistedWindowRestoreCatalog(entries: [firstEntry, secondEntry]),
                consumedEntries: [PersistedWindowRestoreConsumptionKey(entry: firstEntry)],
                monitors: [monitor],
                workspaceIdForName: { _ in workspaceId }
            )
        )
        let secondPlan = try #require(
            planner.planPersistedHydration(
                .init(
                    token: secondToken,
                    metadata: metadata,
                    catalog: PersistedWindowRestoreCatalog(entries: [firstEntry, secondEntry]),
                    consumedEntries: [PersistedWindowRestoreConsumptionKey(entry: firstEntry)],
                    monitors: [monitor],
                    workspaceIdForName: { _ in workspaceId }
                )
            )
        )

        #expect(reusedPlan == nil)
        #expect(secondPlan.persistedEntry == secondEntry)
    }

    @Test func persistedHydrationReturnsNilWhenWorkspaceNameIsMissing() {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 703, name: "Main")
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(workspaceId: workspaceId, title: "Missing Workspace")
        let token = WindowToken(pid: 731, windowId: 31)
        let entry = makeRestorePlannerCatalogEntry(
            token: token,
            metadata: metadata,
            workspaceName: "2",
            monitor: monitor
        )

        let plan = planner.planPersistedHydration(
            .init(
                token: token,
                metadata: metadata,
                catalog: PersistedWindowRestoreCatalog(entries: [entry]),
                consumedEntries: [],
                monitors: [monitor],
                workspaceIdForName: { _ in nil }
            )
        )

        #expect(plan == nil)
    }
}
