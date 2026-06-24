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

    func isKnownInactiveSpace(_ spaceId: UInt64) -> Bool {
        guard isEnabledAndPopulated, spaceId != 0 else { return false }
        return knownSpaceIds.contains(spaceId)
            && !Set(activeSpaceIdsByDisplayId.values).contains(spaceId)
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

    func isWindowOnKnownInactiveNativeSpace(windowId: UInt32, preferredSpaceId: UInt64?) -> Bool {
        if let preferredSpaceId, isKnownInactiveSpace(preferredSpaceId) {
            return true
        }
        return isWindowOnKnownInactiveSpace(windowId: windowId)
    }

    /// True when a window appears on every known macOS Space.
    ///
    /// A window whose `collectionBehavior` includes `.canJoinAllSpaces` (for example a
    /// browser Picture-in-Picture mini-window) is placed by macOS on every Space, so
    /// the Space IDs it reports cover all of `knownSpaceIds`. A normal
    /// workspace-bound window appears on exactly one Space.
    ///
    /// This is the correct discriminator for exempting a global window from
    /// workspace-switch parking — unlike `isWindowOnKnownInactiveSpace`, which
    /// Nehir's virtual workspaces (simulated within one macOS Space by parking
    /// windows) make return `false` for both normal and global windows.
    ///
    /// It only discriminates when there is more than one known Space (multi-display
    /// "Displays have separate Spaces", the reporter's setup). On a single display
    /// `knownSpaceIds.count == 1`, so both a global and a normal window report that
    /// one active Space and are indistinguishable by Space membership alone; that
    /// case is left for a future user-declared `sticky` rule.
    func isWindowOnAllKnownSpaces(windowId: UInt32) -> Bool {
        guard isEnabledAndPopulated, knownSpaceIds.count > 1 else { return false }
        guard let candidates = spaceIdsByWindowId[windowId] else { return false }
        // A `canJoinAllSpaces` window may also report Space IDs Nehir does not track;
        // what matters is that it covers every Space Nehir knows about.
        return knownSpaceIds.isSubset(of: Set(candidates))
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
