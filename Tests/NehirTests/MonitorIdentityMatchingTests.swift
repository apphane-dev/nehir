// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir
import Testing

private func makeIdentityTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat,
    y: CGFloat = 0,
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

@Suite struct MonitorIdentityMatchingTests {
    // MARK: - OutputId

    @Test func outputIdEqualityIgnoresAnchorPoint() {
        let withAnchor = OutputId(displayId: 1, name: "Display", anchorPoint: CGPoint(x: 10, y: 20))
        let withoutAnchor = OutputId(displayId: 1, name: "Display")
        #expect(withAnchor == withoutAnchor)
        #expect(withAnchor.hashValue == withoutAnchor.hashValue)
    }

    @Test func outputIdResolvesByNameWhenIdentityKept() {
        let saved = OutputId(from: makeIdentityTestMonitor(displayId: 100, name: "Shared", x: 1920))
        let leftSameName = makeIdentityTestMonitor(displayId: 1, name: "Shared", x: 0)
        let rightDifferentName = makeIdentityTestMonitor(displayId: 200, name: "Office", x: 1920)

        let resolved = saved.resolveMonitor(in: [leftSameName, rightDifferentName])
        #expect(resolved?.id == leftSameName.id)
    }

    @Test func outputIdResolvesByPositionWhenIdentityIgnored() {
        let saved = OutputId(from: makeIdentityTestMonitor(displayId: 100, name: "Shared", x: 1920))
        let leftSameName = makeIdentityTestMonitor(displayId: 1, name: "Shared", x: 0)
        let rightDifferentName = makeIdentityTestMonitor(displayId: 200, name: "Office", x: 1920)

        let resolved = saved.resolveMonitor(in: [leftSameName, rightDifferentName], ignoreIdentity: true)
        #expect(resolved?.id == rightDifferentName.id)
    }

    @Test func outputIdStillPrefersExactDisplayIdWhenIgnoringIdentity() {
        let exact = makeIdentityTestMonitor(displayId: 100, name: "Renamed", x: 0)
        let saved = OutputId(displayId: 100, name: "Original", anchorPoint: CGPoint(x: 5000, y: 5000))
        let resolved = saved.resolveMonitor(in: [exact], ignoreIdentity: true)
        #expect(resolved?.id == exact.id)
    }

    @Test @MainActor func workspaceConfigurationsRebindByPositionWhenIdentityIgnored() {
        let savedOutput = OutputId(from: makeIdentityTestMonitor(displayId: 100, name: "Shared", x: 1920))
        let config = WorkspaceConfiguration(name: "1", monitorAssignment: .specificDisplay(savedOutput))
        let leftSameName = makeIdentityTestMonitor(displayId: 1, name: "Shared", x: 0)
        let rightDifferentName = makeIdentityTestMonitor(displayId: 200, name: "Office", x: 1920)

        let rebound = SettingsStore.normalizedWorkspaceConfigurations(
            [config],
            monitors: [leftSameName, rightDifferentName],
            ignoreIdentity: true
        )

        guard case let .specificDisplay(output) = rebound.first?.monitorAssignment else {
            Issue.record("Expected a specificDisplay assignment")
            return
        }
        #expect(output.displayId == rightDifferentName.displayId)
    }

    // MARK: - MonitorSettingsStore

    @Test func monitorSettingsStoreRejectsCrossNameDisplayIdMatches() {
        let setting = MonitorBarSettings(
            monitorName: "Right",
            monitorAnchorPoint: CGPoint(x: 1920, y: 1080),
            enabled: false
        )
        let rightMonitor = makeIdentityTestMonitor(displayId: 900, name: "BrandNew", x: 1920)
        let rebound = MonitorBarSettings(
            monitorName: setting.monitorName,
            monitorDisplayId: rightMonitor.displayId,
            monitorAnchorPoint: setting.monitorAnchorPoint,
            enabled: setting.enabled
        )

        #expect(MonitorSettingsStore.get(for: rightMonitor, in: [setting]) == nil)
        #expect(MonitorSettingsStore.get(for: rightMonitor, in: [rebound]) == nil)
    }

    @Test func monitorSettingsStoreFallsBackToAnchorWhenDisplayIdDoesNotMatch() {
        let setting = MonitorBarSettings(
            monitorName: "Shared",
            monitorDisplayId: 111,
            monitorAnchorPoint: CGPoint(x: 1920, y: 1080),
            enabled: false
        )
        let monitor = makeIdentityTestMonitor(displayId: 900, name: "Shared", x: 1920)

        #expect(MonitorSettingsStore.get(for: monitor, in: [setting])?.id == setting.id)
    }

    // MARK: - WorkspacesTOMLCodec anchor persistence

    @Test func workspaceAssignmentAnchorRoundTrips() {
        let output = OutputId(displayId: 42, name: "HP E27m G4", anchorPoint: CGPoint(x: 1920, y: 1080))
        let config = WorkspaceConfiguration(name: "1", monitorAssignment: .specificDisplay(output))

        let data = WorkspacesTOMLCodec.encode([config])
        let decoded = WorkspacesTOMLCodec.decode(data, defaults: [])

        guard case let .specificDisplay(decodedOutput) = decoded.first?.monitorAssignment else {
            Issue.record("Expected a specificDisplay assignment")
            return
        }
        #expect(decodedOutput.displayId == 42)
        #expect(decodedOutput.anchorPoint == CGPoint(x: 1920, y: 1080))
    }

    @Test func workspaceAssignmentWithoutAnchorDecodesAsNil() {
        let toml = """
        [1]
        monitor = "specific"
        monitorName = "Legacy"
        monitorDisplayId = 7
        """
        let decoded = WorkspacesTOMLCodec.decode(string: toml)

        guard case let .specificDisplay(output) = decoded.first?.monitorAssignment else {
            Issue.record("Expected a specificDisplay assignment")
            return
        }
        #expect(output.displayId == 7)
        #expect(output.anchorPoint == nil)
    }
}
