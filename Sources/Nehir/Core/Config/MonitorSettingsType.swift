// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation

protocol MonitorSettingsType: Codable, Identifiable, Equatable {
    var monitorName: String { get set }
    var monitorDisplayId: CGDirectDisplayID? { get set }
    /// Top-left anchor of the monitor when the override was saved. Used as a position fallback
    /// when matching ignores monitor identity. Optional for backward compatibility.
    var monitorAnchorPoint: CGPoint? { get set }
}

enum MonitorSettingsResolver {
    static func activeSetting<T: MonitorSettingsType>(
        for monitor: Monitor,
        in settings: [T],
        connectedMonitors: [Monitor],
        ignoreIdentity: Bool
    ) -> T? {
        let monitors = connectedMonitors.isEmpty ? [monitor] : connectedMonitors
        guard let index = activeAssignmentIndices(
            settings: settings,
            connectedMonitors: monitors,
            ignoreIdentity: ignoreIdentity
        )[monitor.id] else {
            return nil
        }
        return settings[index]
    }

    static func activeAssignments<T: MonitorSettingsType>(
        settings: [T],
        connectedMonitors: [Monitor],
        ignoreIdentity: Bool
    ) -> [T.ID: Monitor.ID] {
        activeAssignmentIndices(
            settings: settings,
            connectedMonitors: connectedMonitors,
            ignoreIdentity: ignoreIdentity
        )
        .reduce(into: [:]) { result, assignment in
            result[settings[assignment.value].id] = assignment.key
        }
    }

    static func inactiveSettings<T: MonitorSettingsType>(
        _ settings: [T],
        connectedMonitors: [Monitor],
        ignoreIdentity: Bool
    ) -> [T] {
        let activeIndices = Set(activeAssignmentIndices(
            settings: settings,
            connectedMonitors: connectedMonitors,
            ignoreIdentity: ignoreIdentity
        ).values)
        return settings.enumerated().compactMap { index, setting in
            activeIndices.contains(index) ? nil : setting
        }
    }

    private static func activeAssignmentIndices<T: MonitorSettingsType>(
        settings: [T],
        connectedMonitors: [Monitor],
        ignoreIdentity: Bool
    ) -> [Monitor.ID: Int] {
        guard !settings.isEmpty, !connectedMonitors.isEmpty else { return [:] }
        if ignoreIdentity {
            return positionAssignmentIndices(settings: settings, connectedMonitors: connectedMonitors)
        }
        return identityAssignmentIndices(settings: settings, connectedMonitors: connectedMonitors)
    }

    private static func identityAssignmentIndices<T: MonitorSettingsType>(
        settings: [T],
        connectedMonitors: [Monitor]
    ) -> [Monitor.ID: Int] {
        var assignments: [Monitor.ID: Int] = [:]

        for monitor in connectedMonitors {
            let candidates = settings.indices.filter {
                settings[$0].monitorName.caseInsensitiveCompare(monitor.name) == .orderedSame
            }
            guard !candidates.isEmpty else { continue }
            if candidates.count == 1 {
                let candidate = candidates[0]
                if let displayId = settings[candidate].monitorDisplayId,
                   displayId != monitor.displayId
                {
                    if let closest = uniqueClosestAnchorIndex(
                        among: candidates,
                        settings: settings,
                        monitor: monitor
                    ) {
                        assignments[monitor.id] = closest
                    }
                    continue
                }
                assignments[monitor.id] = candidate
                continue
            }

            let displayIdMatches = candidates.filter { settings[$0].monitorDisplayId == monitor.displayId }
            if displayIdMatches.count == 1 {
                assignments[monitor.id] = displayIdMatches[0]
                continue
            }
            if displayIdMatches.count > 1 {
                if let closest = uniqueClosestAnchorIndex(
                    among: displayIdMatches,
                    settings: settings,
                    monitor: monitor
                ) {
                    assignments[monitor.id] = closest
                }
                continue
            }

            if let closest = uniqueClosestAnchorIndex(among: candidates, settings: settings, monitor: monitor) {
                assignments[monitor.id] = closest
            }
        }

        return assignments
    }

    private static func positionAssignmentIndices<T: MonitorSettingsType>(
        settings: [T],
        connectedMonitors: [Monitor]
    ) -> [Monitor.ID: Int] {
        var assignments: [Monitor.ID: Int] = [:]
        var usedSettingIndices = Set<Int>()
        var usedMonitorIds = Set<Monitor.ID>()

        let anchorMatches = settings.indices.flatMap { index -> [MonitorSettingsAnchorMatch] in
            guard let anchor = settings[index].monitorAnchorPoint else { return [] }
            return connectedMonitors.map {
                MonitorSettingsAnchorMatch(
                    settingIndex: index,
                    monitor: $0,
                    distance: anchor.distanceSquared(to: $0.workspaceAnchorPoint)
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.settingIndex != rhs.settingIndex { return lhs.settingIndex < rhs.settingIndex }
            return monitorSortKey(lhs.monitor) < monitorSortKey(rhs.monitor)
        }

        for match in anchorMatches {
            guard !usedSettingIndices.contains(match.settingIndex),
                  !usedMonitorIds.contains(match.monitor.id)
            else { continue }
            assignments[match.monitor.id] = match.settingIndex
            usedSettingIndices.insert(match.settingIndex)
            usedMonitorIds.insert(match.monitor.id)
        }

        let remainingNoAnchorIndices = settings.indices.filter {
            settings[$0].monitorAnchorPoint == nil && !usedSettingIndices.contains($0)
        }
        let remainingMonitors = connectedMonitors.filter { !usedMonitorIds.contains($0.id) }
        let monitorIndicesByName = Dictionary(grouping: remainingMonitors.indices) { index in
            remainingMonitors[index].name.lowercased()
        }
        let settingIndicesByName = Dictionary(grouping: remainingNoAnchorIndices) { index in
            settings[index].monitorName.lowercased()
        }

        for (name, settingIndices) in settingIndicesByName {
            guard settingIndices.count == 1,
                  let settingIndex = settingIndices.first,
                  let monitorIndices = monitorIndicesByName[name],
                  monitorIndices.count == 1,
                  let monitorIndex = monitorIndices.first
            else { continue }
            let monitor = remainingMonitors[monitorIndex]
            assignments[monitor.id] = settingIndex
        }

        return assignments
    }

    private static func uniqueClosestAnchorIndex<T: MonitorSettingsType>(
        among indices: [Int],
        settings: [T],
        monitor: Monitor
    ) -> Int? {
        let scored = indices.compactMap { index -> (index: Int, distance: CGFloat)? in
            guard let anchor = settings[index].monitorAnchorPoint else { return nil }
            return (index, anchor.distanceSquared(to: monitor.workspaceAnchorPoint))
        }
        guard let best = scored.min(by: { $0.distance < $1.distance }) else { return nil }
        let ties = scored.filter { $0.distance == best.distance }
        return ties.count == 1 ? best.index : nil
    }

    private static func monitorSortKey(_ monitor: Monitor) -> (CGFloat, CGFloat, UInt32) {
        (monitor.frame.minX, -monitor.frame.maxY, monitor.displayId)
    }
}

private struct MonitorSettingsAnchorMatch {
    let settingIndex: Int
    let monitor: Monitor
    let distance: CGFloat
}

enum MonitorSettingsStore {
    static func get<T: MonitorSettingsType>(
        for monitor: Monitor,
        in settings: [T]
    ) -> T? {
        MonitorSettingsResolver.activeSetting(
            for: monitor,
            in: settings,
            connectedMonitors: [monitor],
            ignoreIdentity: false
        )
    }

    static func get<T: MonitorSettingsType>(for monitorName: String, in settings: [T]) -> T? {
        settings.first { $0.monitorDisplayId == nil && $0.monitorName == monitorName } ??
            settings.first { $0.monitorName == monitorName }
    }

    static func update<T: MonitorSettingsType>(_ item: T, in settings: inout [T]) {
        if let displayId = item.monitorDisplayId,
           let index = settings.firstIndex(where: { $0.monitorDisplayId == displayId })
        {
            settings[index] = item
            return
        }

        if let index = settings.firstIndex(where: {
            $0.monitorDisplayId == nil && item.monitorDisplayId == nil && $0.monitorName == item.monitorName
        }) {
            settings[index] = item
            return
        }

        if item.monitorDisplayId != nil,
           let index = settings
           .firstIndex(where: { $0.monitorDisplayId == nil && $0.monitorName == item.monitorName })
        {
            settings[index] = item
            return
        }

        settings.append(item)
    }

    static func remove<T: MonitorSettingsType>(for monitor: Monitor, from settings: inout [T]) {
        guard let active = get(for: monitor, in: settings) else { return }
        settings.removeAll { $0.id == active.id }
    }

    static func remove<T: MonitorSettingsType>(for monitorName: String, from settings: inout [T]) {
        settings.removeAll { $0.monitorName == monitorName }
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
