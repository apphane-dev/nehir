// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation

struct SpaceTopology: Equatable, Sendable {
    let mode: DisplaySpacesMode
    let activeSpaceIdsByDisplayId: [CGDirectDisplayID: UInt64]
    let knownSpaceIds: Set<UInt64>
    let spaceIdsByWindowId: [UInt32: [UInt64]]

    static let empty = SpaceTopology(mode: .unavailable)

    init(
        mode: DisplaySpacesMode,
        activeSpaceIdsByDisplayId: [CGDirectDisplayID: UInt64] = [:],
        knownSpaceIds: Set<UInt64> = [],
        spaceIdsByWindowId: [UInt32: [UInt64]] = [:]
    ) {
        self.mode = mode
        self.activeSpaceIdsByDisplayId = activeSpaceIdsByDisplayId
        self.knownSpaceIds = knownSpaceIds
        self.spaceIdsByWindowId = spaceIdsByWindowId
    }

    var isEnabledAndPopulated: Bool {
        mode == .enabled && !activeSpaceIdsByDisplayId.isEmpty && !knownSpaceIds.isEmpty
    }

    func isWindowOnKnownInactiveSpace(windowId: UInt32) -> Bool {
        guard isEnabledAndPopulated,
              let candidates = spaceIdsByWindowId[windowId],
              !candidates.isEmpty
        else { return false }

        let activeIds = Set(activeSpaceIdsByDisplayId.values)
        if candidates.contains(where: activeIds.contains) {
            return false
        }

        let knownCandidates = candidates.filter(knownSpaceIds.contains)
        return !knownCandidates.isEmpty
    }

    @MainActor
    static func current(monitors: [Monitor], windowIds: [UInt32]) -> SpaceTopology {
        let skyLight = SkyLight.shared
        let mode = skyLight.displaySpacesMode(monitors: monitors)
        guard mode == .enabled else { return SpaceTopology(mode: mode) }

        let snapshots = skyLight.managedDisplaySpaces(monitors: monitors)
        var activeSpaceIdsByDisplayId: [CGDirectDisplayID: UInt64] = [:]
        var knownSpaceIds = Set<UInt64>()
        for snapshot in snapshots {
            if snapshot.currentSpaceId != 0 {
                activeSpaceIdsByDisplayId[snapshot.displayId] = snapshot.currentSpaceId
                knownSpaceIds.insert(snapshot.currentSpaceId)
            }
            knownSpaceIds.formUnion(snapshot.spaceIds.filter { $0 != 0 })
        }

        guard !activeSpaceIdsByDisplayId.isEmpty, !knownSpaceIds.isEmpty else {
            return SpaceTopology(mode: mode)
        }

        var spaceIdsByWindowId: [UInt32: [UInt64]] = [:]
        for windowId in Set(windowIds).filter({ $0 != 0 }) {
            let spaceIds = skyLight.spacesForWindow(windowId).filter { $0 != 0 }
            if !spaceIds.isEmpty {
                spaceIdsByWindowId[windowId] = spaceIds
            }
        }

        return SpaceTopology(
            mode: mode,
            activeSpaceIdsByDisplayId: activeSpaceIdsByDisplayId,
            knownSpaceIds: knownSpaceIds,
            spaceIdsByWindowId: spaceIdsByWindowId
        )
    }

    var debugSummary: String {
        "mode=\(mode.rawValue) activeSpaces=\(activeSpaceIdsByDisplayId.count) knownSpaces=\(knownSpaceIds.count) windowRecords=\(spaceIdsByWindowId.count)"
    }
}
