// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
@testable import Nehir
import Testing

private func makeMonitorTabTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

@Suite struct MonitorSettingsTabTests {
    @Test func normalizedSelectionFallsBackToFirstEffectiveOrderEntryWhenSelectionIsMissing() {
        let right = makeMonitorTabTestMonitor(displayId: 2, name: "Right", x: 1920, y: 0)
        let left = makeMonitorTabTestMonitor(displayId: 1, name: "Left", x: 0, y: 0)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [right, left],
            orderedNames: ["Right", "Left"]
        )

        let selection = MonitorSettingsTabModel.normalizedSelection(nil, entries: entries)

        #expect(selection == right.id)
    }

    @Test func normalizedSelectionClearsWhenNoMonitorsRemain() {
        let missing = Monitor.ID(displayId: 42)

        let selection = MonitorSettingsTabModel.normalizedSelection(
            missing,
            entries: [MonitorOrderEntry]()
        )

        #expect(selection == nil)
    }

    @Test func displayLabelsDisambiguateDuplicateMonitorNamesByPhysicalOrder() {
        let first = makeMonitorTabTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let second = makeMonitorTabTestMonitor(displayId: 2, name: "Studio Display", x: 1920, y: 0)
        let labels = MonitorSettingsTabModel.displayLabels(for: [second, first])

        #expect(labels[first.id] == MonitorDisplayLabel(name: "Studio Display", duplicateIndex: 1))
        #expect(labels[second.id] == MonitorDisplayLabel(name: "Studio Display", duplicateIndex: 2))
    }

    @Test func displayLabelsDisambiguateDuplicateMonitorNamesByVerticalOrder() {
        let bottom = makeMonitorTabTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let top = makeMonitorTabTestMonitor(displayId: 2, name: "Studio Display", x: 320, y: 1080)
        let labels = MonitorSettingsTabModel.displayLabels(for: [bottom, top], axis: .vertical)

        #expect(labels[top.id] == MonitorDisplayLabel(name: "Studio Display", duplicateIndex: 1))
        #expect(labels[bottom.id] == MonitorDisplayLabel(name: "Studio Display", duplicateIndex: 2))
    }

    @Test func canMoveDisablesLeftAndRightAtSequenceEdges() {
        let left = makeMonitorTabTestMonitor(displayId: 1, name: "Left", x: 0, y: 0)
        let center = makeMonitorTabTestMonitor(displayId: 2, name: "Center", x: 1920, y: 0)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [left, center],
            orderedNames: ["Left", "Center"]
        )

        #expect(MonitorSettingsTabModel.canMove(entries: entries, moving: left.id, direction: .left) == false)
        #expect(MonitorSettingsTabModel.canMove(entries: entries, moving: center.id, direction: .right) == false)
        #expect(MonitorSettingsTabModel.canMove(entries: entries, moving: center.id, direction: .left))
    }

    @Test func reorderedNamesMoveSelectedMonitorLeftAndRight() {
        let left = makeMonitorTabTestMonitor(displayId: 1, name: "Left", x: 0, y: 0)
        let center = makeMonitorTabTestMonitor(displayId: 2, name: "Center", x: 1920, y: 0)
        let right = makeMonitorTabTestMonitor(displayId: 3, name: "Right", x: 3840, y: 0)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [left, center, right],
            orderedNames: ["Left", "Center", "Right"]
        )

        let movedLeft = MonitorSettingsTabModel.reorderedNames(
            entries: entries,
            moving: center.id,
            direction: .left
        )
        let movedRight = MonitorSettingsTabModel.reorderedNames(
            entries: entries,
            moving: center.id,
            direction: .right
        )

        #expect(movedLeft == ["Center", "Left", "Right"])
        #expect(movedRight == ["Left", "Right", "Center"])
    }

    @Test func duplicateNamedEntriesStayDistinctWhenReorderingByMonitorId() {
        let first = makeMonitorTabTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let middle = makeMonitorTabTestMonitor(displayId: 2, name: "Center", x: 1920, y: 0)
        let second = makeMonitorTabTestMonitor(displayId: 3, name: "Studio Display", x: 3840, y: 0)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [first, middle, second],
            orderedNames: ["Studio Display", "Center", "Studio Display"]
        )

        #expect(entries.map(\.id) == [first.id, middle.id, second.id])
        #expect(entries.first?.displayLabel.duplicateIndex == 1)
        #expect(entries.last?.displayLabel.duplicateIndex == 2)

        let reordered = MonitorSettingsTabModel.reorderedNames(
            entries: entries,
            moving: second.id,
            direction: .left
        )

        #expect(reordered == ["Studio Display", "Studio Display", "Center"])
    }

    @Test func orderEntriesUseVerticalAxisForDuplicateNameResolution() {
        let bottom = makeMonitorTabTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let center = makeMonitorTabTestMonitor(displayId: 2, name: "Center", x: 0, y: 1080)
        let top = makeMonitorTabTestMonitor(displayId: 3, name: "Studio Display", x: 320, y: 2160)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [bottom, center, top],
            orderedNames: ["Studio Display", "Center", "Studio Display"],
            axis: .vertical
        )

        #expect(entries.map(\.id) == [top.id, center.id, bottom.id])
        #expect(entries.first?.displayLabel.duplicateIndex == 1)
        #expect(entries.last?.displayLabel.duplicateIndex == 2)
    }
}
