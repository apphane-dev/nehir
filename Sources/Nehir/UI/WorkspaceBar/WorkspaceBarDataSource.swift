// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

@MainActor
enum WorkspaceBarDataSource {
    private struct WorkspaceSnapshot {
        let workspace: WorkspaceDescriptor
        let tiledEntries: [WindowModel.Entry]
        let floatingEntries: [WindowModel.Entry]
        let hasBarOccupancy: Bool
    }

    static func workspaceBarItems(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        niriEngine: NiriLayoutEngine?,
        focusedToken: WindowToken?,
        viewportSelectedToken: WindowToken? = nil,
        settings: SettingsStore
    ) -> [WorkspaceBarItem] {
        workspaceItems(
            for: monitor,
            options: options,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            niriEngine: niriEngine,
            focusedToken: focusedToken,
            viewportSelectedToken: viewportSelectedToken,
            settings: settings
        )
    }

    static func workspaceBarProjection(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        niriEngine: NiriLayoutEngine?,
        focusedToken: WindowToken?,
        viewportSelectedToken: WindowToken? = nil,
        settings: SettingsStore,
        moveTargets: [WorkspaceBarWindowMoveTarget]? = nil
    ) -> WorkspaceBarProjection {
        WorkspaceBarProjection(
            items: workspaceItems(
                for: monitor,
                options: options,
                workspaceManager: workspaceManager,
                appInfoCache: appInfoCache,
                niriEngine: niriEngine,
                focusedToken: focusedToken,
                viewportSelectedToken: viewportSelectedToken,
                settings: settings
            ),
            sticky: stickyItem(
                for: monitor,
                workspaceManager: workspaceManager,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken,
                viewportSelectedToken: viewportSelectedToken
            ),
            scratchpad: scratchpadItem(
                workspaceManager: workspaceManager,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken,
                viewportSelectedToken: viewportSelectedToken,
                settings: settings
            ),
            isViewportScrollLocked: activeWorkspaceScrollLockState(
                for: monitor,
                workspaceManager: workspaceManager
            ),
            moveTargets: moveTargets ?? moveTargetItems(workspaceManager: workspaceManager, settings: settings)
        )
    }

    private static func activeWorkspaceScrollLockState(
        for monitor: Monitor,
        workspaceManager: WorkspaceManager
    ) -> Bool {
        guard let workspaceId = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id else { return false }
        return workspaceManager.niriViewportState(for: workspaceId).isScrollLocked
    }

    private static func workspaceItems(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        niriEngine: NiriLayoutEngine?,
        focusedToken: WindowToken?,
        viewportSelectedToken: WindowToken?,
        settings: SettingsStore
    ) -> [WorkspaceBarItem] {
        var items = localWorkspaceItems(
            for: monitor,
            options: options,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            niriEngine: niriEngine,
            focusedToken: focusedToken,
            viewportSelectedToken: viewportSelectedToken,
            settings: settings
        )

        if options.showWorkspacesFromOtherDisplays {
            items.append(
                contentsOf: foreignWorkspaceItems(
                    for: monitor,
                    options: options,
                    workspaceManager: workspaceManager,
                    settings: settings
                )
            )
        }

        return items
    }

    private static func localWorkspaceItems(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        niriEngine: NiriLayoutEngine?,
        focusedToken: WindowToken?,
        viewportSelectedToken: WindowToken?,
        settings: SettingsStore
    ) -> [WorkspaceBarItem] {
        var workspaces = workspaceManager.workspaces(on: monitor.id).map { workspace in
            let projectedEntries = workspaceManager.barVisibleEntries(
                in: workspace.id,
                showFloatingWindows: options.showFloatingWindows
            ).filter { !workspaceManager.isStickyWindow($0.token) }
            return WorkspaceSnapshot(
                workspace: workspace,
                tiledEntries: projectedEntries.filter { $0.mode == .tiling },
                floatingEntries: projectedEntries.filter { $0.mode == .floating },
                hasBarOccupancy: !projectedEntries.isEmpty
            )
        }

        if options.hideEmptyWorkspaces {
            workspaces = workspaces.filter(\.hasBarOccupancy)
        }

        let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id

        return workspaces.map { snapshot in
            let orderedTiledEntries = WorkspaceEntryOrdering.orderedEntries(
                snapshot.tiledEntries,
                in: snapshot.workspace.id,
                engine: niriEngine
            )
            let orderedFloatingEntries = WorkspaceEntryOrdering.orderedEntries(
                snapshot.floatingEntries,
                in: snapshot.workspace.id,
                engine: niriEngine
            )
            let useLayoutOrder = niriEngine.map { !$0.columns(in: snapshot.workspace.id).isEmpty } ?? false
            let tiledWindows = createWindowItems(
                entries: orderedTiledEntries,
                deduplicate: options.deduplicateAppIcons,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken,
                viewportSelectedToken: viewportSelectedToken
            )
            let floatingWindows = createWindowItems(
                entries: orderedFloatingEntries,
                deduplicate: options.deduplicateAppIcons,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken,
                viewportSelectedToken: viewportSelectedToken
            )

            return WorkspaceBarItem(
                id: snapshot.workspace.id,
                name: settings.displayName(for: snapshot.workspace.name),
                rawName: snapshot.workspace.name,
                isFocused: snapshot.workspace.id == activeWorkspaceId,
                tiledWindows: tiledWindows,
                floatingWindows: floatingWindows
            )
        }
    }

    /// Workspaces realized on other displays, projected as compact foreign pills
    /// after the local workspaces. Only monitor-assigned workspaces are included
    /// (matching `moveTargetItems`), so disconnected workspaces never appear.
    /// Foreign pills carry no window icons (a navigation aid, not a duplicate of
    /// the home bar); `hideEmptyWorkspaces` is still respected based on real
    /// workspace occupancy.
    private static func foreignWorkspaceItems(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        settings: SettingsStore
    ) -> [WorkspaceBarItem] {
        var seen = Set(workspaceManager.workspaces(on: monitor.id).map(\.id))
        var items: [WorkspaceBarItem] = []

        for (monitorIndex, otherMonitor) in workspaceManager.monitors.enumerated() where otherMonitor.id != monitor.id {
            let activeOnOther = workspaceManager.activeWorkspace(on: otherMonitor.id)?.id
            let monitorLabel = compactForeignMonitorLabel(for: otherMonitor, index: monitorIndex)
            for workspace in workspaceManager.workspaces(on: otherMonitor.id) {
                guard seen.insert(workspace.id).inserted else { continue }
                let projectedEntries = workspaceManager.barVisibleEntries(
                    in: workspace.id,
                    showFloatingWindows: options.showFloatingWindows
                ).filter { !workspaceManager.isStickyWindow($0.token) }
                if options.hideEmptyWorkspaces, projectedEntries.isEmpty { continue }
                items.append(
                    WorkspaceBarItem(
                        id: workspace.id,
                        name: settings.displayName(for: workspace.name),
                        rawName: workspace.name,
                        isFocused: false,
                        tiledWindows: [],
                        floatingWindows: [],
                        isForeign: true,
                        homeMonitorName: otherMonitor.name,
                        homeMonitorLabel: monitorLabel,
                        isActiveOnHomeDisplay: workspace.id == activeOnOther
                    )
                )
            }
        }
        return items
    }

    private static func compactForeignMonitorLabel(for _: Monitor, index: Int) -> String {
        // Full display names are often verbose and repeated across multiple
        // workspace pills. Use a stable compact visual tag in the bar; keep the
        // full name in accessibility/help text via `homeMonitorName`.
        "D\(index + 1)"
    }

    private static func stickyItem(
        for monitor: Monitor,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?,
        viewportSelectedToken: WindowToken?
    ) -> WorkspaceBarStickyItem? {
        var seen: Set<WindowToken> = []
        let entries = workspaceManager.workspaces(on: monitor.id).flatMap { workspace in
            workspaceManager.barVisibleEntries(
                in: workspace.id,
                showFloatingWindows: true
            )
        }.filter { entry in
            workspaceManager.isStickyWindow(entry.token) && seen.insert(entry.token).inserted
        }

        let windows = createWindowItems(
            entries: entries,
            deduplicate: false,
            useLayoutOrder: false,
            appInfoCache: appInfoCache,
            focusedToken: focusedToken,
            viewportSelectedToken: viewportSelectedToken
        )
        guard !windows.isEmpty else { return nil }
        return WorkspaceBarStickyItem(windows: windows)
    }

    private static func scratchpadItem(
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?,
        viewportSelectedToken: WindowToken?,
        settings: SettingsStore
    ) -> WorkspaceBarScratchpadItem? {
        guard let scratchpadToken = workspaceManager.scratchpadToken(),
              let entry = workspaceManager.entry(for: scratchpadToken),
              let window = createWindowItems(
                  entries: [entry],
                  deduplicate: false,
                  useLayoutOrder: false,
                  appInfoCache: appInfoCache,
                  focusedToken: focusedToken,
                  viewportSelectedToken: viewportSelectedToken
              ).first
        else {
            return nil
        }

        let descriptor = workspaceManager.descriptor(for: entry.workspaceId)
        let rawWorkspaceName = descriptor?.name ?? ""
        return WorkspaceBarScratchpadItem(
            window: window,
            isVisible: workspaceManager.hiddenState(for: scratchpadToken) == nil,
            workspaceId: entry.workspaceId,
            workspaceName: settings.displayName(for: rawWorkspaceName),
            rawWorkspaceName: rawWorkspaceName
        )
    }

    private static func createWindowItems(
        entries: [WindowModel.Entry],
        deduplicate: Bool,
        useLayoutOrder: Bool,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?,
        viewportSelectedToken: WindowToken?
    ) -> [WorkspaceBarWindowItem] {
        if deduplicate {
            return createDedupedWindowItems(
                entries: entries,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken,
                viewportSelectedToken: viewportSelectedToken
            )
        }

        return createIndividualWindowItems(
            entries: entries,
            appInfoCache: appInfoCache,
            focusedToken: focusedToken,
            viewportSelectedToken: viewportSelectedToken
        )
    }

    private static func createDedupedWindowItems(
        entries: [WindowModel.Entry],
        useLayoutOrder: Bool,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?,
        viewportSelectedToken: WindowToken?
    ) -> [WorkspaceBarWindowItem] {
        if useLayoutOrder {
            var groupedByApp: [String: [WindowModel.Entry]] = [:]
            var orderedAppNames: [String] = []

            for entry in entries {
                let appName = appInfoCache.name(for: entry.handle.pid) ?? "Unknown"

                if groupedByApp[appName] == nil {
                    groupedByApp[appName] = []
                    orderedAppNames.append(appName)
                }

                groupedByApp[appName]?.append(entry)
            }

            return orderedAppNames.compactMap { appName -> WorkspaceBarWindowItem? in
                guard let appEntries = groupedByApp[appName], let firstEntry = appEntries.first else { return nil }
                let appInfo = appInfoCache.info(for: firstEntry.handle.pid)
                let anyFocused = appEntries.contains { $0.handle.id == focusedToken }
                let anySelected = appEntries.contains { $0.handle.id == viewportSelectedToken }

                let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: windowTitle(for: entry) ?? appName,
                        isFocused: entry.handle.id == focusedToken,
                        isSelected: entry.handle.id == viewportSelectedToken
                    )
                }

                return WorkspaceBarWindowItem(
                    id: firstEntry.handle.id,
                    windowId: firstEntry.windowId,
                    appName: appName,
                    icon: appInfo?.icon,
                    isFocused: anyFocused,
                    isSelected: anySelected,
                    windowCount: appEntries.count,
                    allWindows: windowInfos
                )
            }
        }

        let groupedByApp = Dictionary(grouping: entries) { entry -> String in
            appInfoCache.name(for: entry.handle.pid) ?? "Unknown"
        }

        return groupedByApp.map { appName, appEntries -> WorkspaceBarWindowItem in
            let firstEntry = appEntries.first!
            let appInfo = appInfoCache.info(for: firstEntry.handle.pid)
            let anyFocused = appEntries.contains { $0.handle.id == focusedToken }
            let anySelected = appEntries.contains { $0.handle.id == viewportSelectedToken }

            let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                WorkspaceBarWindowInfo(
                    id: entry.handle.id,
                    windowId: entry.windowId,
                    title: windowTitle(for: entry) ?? appName,
                    isFocused: entry.handle.id == focusedToken,
                    isSelected: entry.handle.id == viewportSelectedToken
                )
            }

            return WorkspaceBarWindowItem(
                id: firstEntry.handle.id,
                windowId: firstEntry.windowId,
                appName: appName,
                icon: appInfo?.icon,
                isFocused: anyFocused,
                isSelected: anySelected,
                windowCount: appEntries.count,
                allWindows: windowInfos
            )
        }.sorted { $0.appName < $1.appName }
    }

    private static func createIndividualWindowItems(
        entries: [WindowModel.Entry],
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?,
        viewportSelectedToken: WindowToken?
    ) -> [WorkspaceBarWindowItem] {
        entries.map { entry in
            let appInfo = appInfoCache.info(for: entry.handle.pid)
            let appName = appInfo?.name ?? "Unknown"
            let title = windowTitle(for: entry) ?? appName

            return WorkspaceBarWindowItem(
                id: entry.handle.id,
                windowId: entry.windowId,
                appName: appName,
                icon: appInfo?.icon,
                isFocused: entry.handle.id == focusedToken,
                isSelected: entry.handle.id == viewportSelectedToken,
                windowCount: 1,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: title,
                        isFocused: entry.handle.id == focusedToken,
                        isSelected: entry.handle.id == viewportSelectedToken
                    )
                ]
            )
        }
    }

    private static func windowTitle(for entry: WindowModel.Entry) -> String? {
        guard let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
              !title.isEmpty else { return nil }
        return title
    }

    static func workspaceBarMoveTargets(
        workspaceManager: WorkspaceManager,
        settings: SettingsStore
    ) -> [WorkspaceBarWindowMoveTarget] {
        moveTargetItems(workspaceManager: workspaceManager, settings: settings)
    }

    /// Every realized (monitor-assigned) workspace across all monitors, for the
    /// flat *Move to Workspace ▸* submenu.
    private static func moveTargetItems(
        workspaceManager: WorkspaceManager,
        settings: SettingsStore
    ) -> [WorkspaceBarWindowMoveTarget] {
        var seen: Set<WorkspaceDescriptor.ID> = []
        var targets: [WorkspaceBarWindowMoveTarget] = []
        for monitor in workspaceManager.monitors {
            for workspace in workspaceManager.workspaces(on: monitor.id) {
                guard seen.insert(workspace.id).inserted else { continue }
                targets.append(
                    WorkspaceBarWindowMoveTarget(
                        id: workspace.id,
                        name: settings.displayName(for: workspace.name)
                    )
                )
            }
        }
        return targets
    }
}
