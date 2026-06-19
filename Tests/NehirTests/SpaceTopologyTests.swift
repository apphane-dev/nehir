// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
@testable import Nehir
import Testing

struct SpaceTopologyTests {
    @Test func emptyTopologyNeverExempts() {
        let disabled = SpaceTopology(
            mode: .disabled,
            activeSpaceIdsByDisplayId: [1: 10],
            knownSpaceIds: [10, 20],
            spaceIdsByWindowId: [100: [20]]
        )
        let unavailable = SpaceTopology(
            mode: .unavailable,
            activeSpaceIdsByDisplayId: [1: 10],
            knownSpaceIds: [10, 20],
            spaceIdsByWindowId: [100: [20]]
        )
        let emptyEnabled = SpaceTopology(mode: .enabled)

        #expect(!disabled.isWindowOnKnownInactiveSpace(windowId: 100))
        #expect(!unavailable.isWindowOnKnownInactiveSpace(windowId: 100))
        #expect(!emptyEnabled.isWindowOnKnownInactiveSpace(windowId: 100))
        #expect(!SpaceTopology.empty.isWindowOnKnownInactiveSpace(windowId: 100))
    }

    @Test func inactiveKnownSpaceExempts() {
        let topology = SpaceTopology(
            mode: .enabled,
            activeSpaceIdsByDisplayId: [1: 10],
            knownSpaceIds: [10, 20],
            spaceIdsByWindowId: [100: [20]]
        )

        #expect(topology.isWindowOnKnownInactiveSpace(windowId: 100))
    }

    @Test func activeCandidateDoesNotExempt() {
        let topology = SpaceTopology(
            mode: .enabled,
            activeSpaceIdsByDisplayId: [1: 10],
            knownSpaceIds: [10, 20],
            spaceIdsByWindowId: [101: [10]]
        )

        #expect(!topology.isWindowOnKnownInactiveSpace(windowId: 101))
    }

    @Test func mixedActiveAndInactiveDoesNotExempt() {
        let topology = SpaceTopology(
            mode: .enabled,
            activeSpaceIdsByDisplayId: [1: 10],
            knownSpaceIds: [10, 20],
            spaceIdsByWindowId: [102: [10, 20]]
        )

        #expect(!topology.isWindowOnKnownInactiveSpace(windowId: 102))
    }

    @Test func unknownCandidateDoesNotExempt() {
        let topology = SpaceTopology(
            mode: .enabled,
            activeSpaceIdsByDisplayId: [1: 10],
            knownSpaceIds: [10],
            spaceIdsByWindowId: [103: [999]]
        )

        #expect(!topology.isWindowOnKnownInactiveSpace(windowId: 103))
    }

    @Test func debugSummaryIsCompact() {
        let topology = SpaceTopology(
            mode: .enabled,
            activeSpaceIdsByDisplayId: [1: 10, 2: 30],
            knownSpaceIds: [10, 20, 30],
            spaceIdsByWindowId: [9_999: [20]]
        )

        let summary = topology.debugSummary
        #expect(summary.contains("mode=enabled"))
        #expect(summary.contains("activeSpaces=2"))
        #expect(summary.contains("knownSpaces=3"))
        #expect(summary.contains("windowRecords=1"))
        #expect(!summary.contains("9999"))
        #expect(!summary.contains("["))
    }
}
