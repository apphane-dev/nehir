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

    // MARK: - MonitorSettingsStore

    @Test func monitorSettingsResolveByPositionWhenIdentityIgnored() {
        let leftSetting = MonitorBarSettings(
            monitorName: "Left",
            monitorAnchorPoint: CGPoint(x: 0, y: 1080),
            enabled: true
        )
        let rightSetting = MonitorBarSettings(
            monitorName: "Right",
            monitorAnchorPoint: CGPoint(x: 1920, y: 1080),
            enabled: false
        )
        let settings = [leftSetting, rightSetting]

        let rightMonitor = makeIdentityTestMonitor(displayId: 900, name: "BrandNew", x: 1920)
        let leftMonitor = makeIdentityTestMonitor(displayId: 901, name: "AlsoNew", x: 0)

        #expect(MonitorSettingsStore.get(for: rightMonitor, in: settings, ignoreIdentity: true)?.id == rightSetting.id)
        #expect(MonitorSettingsStore.get(for: leftMonitor, in: settings, ignoreIdentity: true)?.id == leftSetting.id)
        // Without ignoring identity, an unrelated name/displayId does not match.
        #expect(MonitorSettingsStore.get(for: rightMonitor, in: settings) == nil)
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
