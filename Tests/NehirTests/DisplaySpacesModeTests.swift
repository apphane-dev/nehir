import CoreGraphics
import Foundation
@testable import Nehir
import Testing

/// Stage 1 (M4) characterization tests for Displays-have-separate-Spaces mode
/// detection and display diagnostics. The runtime detection path depends on
/// private macOS symbols that cannot be exercised in CI, so these tests inject
/// `displaySpacesModeOverrideForTests` for deterministic coverage.
@MainActor
@Suite
struct DisplaySpacesModeTests {
    private func makeMonitor(name: String, displayId: CGDirectDisplayID, frame: CGRect) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func sideBySideMonitors() -> [Monitor] {
        [
            makeMonitor(name: "Primary", displayId: 101, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            makeMonitor(name: "Secondary", displayId: 202, frame: CGRect(x: 1440, y: 100, width: 1440, height: 900))
        ]
    }

    @Test func displaySpacesModeOverrideForTestsRoundTrips() {
        let resolved = SkyLight.shared.displaySpacesMode()
        #expect([.enabled, .disabled, .unavailable].contains(resolved))

        SkyLight.displaySpacesModeOverrideForTests = { .enabled }
        defer { SkyLight.displaySpacesModeOverrideForTests = nil }
        #expect(SkyLight.shared.displaySpacesMode() == .enabled)

        SkyLight.displaySpacesModeOverrideForTests = { .disabled }
        #expect(SkyLight.shared.displaySpacesMode() == .disabled)

        SkyLight.displaySpacesModeOverrideForTests = { .unavailable }
        #expect(SkyLight.shared.displaySpacesMode() == .unavailable)

        SkyLight.displaySpacesModeOverrideForTests = nil
        let afterClear = SkyLight.shared.displaySpacesMode()
        #expect([.enabled, .disabled, .unavailable].contains(afterClear))
    }

    @Test func separateSpacesModeDoesNotSuppressSupportedArrangementWarning() {
        let monitors = sideBySideMonitors()
        let enabled = DisplayEnvironmentDiagnostics.evaluate(monitors: monitors, spacesMode: .enabled)
        let disabled = DisplayEnvironmentDiagnostics.evaluate(monitors: monitors, spacesMode: .disabled)
        let unavailable = DisplayEnvironmentDiagnostics.evaluate(monitors: monitors, spacesMode: .unavailable)

        #expect(enabled.issues.map(\.id) == disabled.issues.map(\.id))
        #expect(unavailable.issues.map(\.id) == disabled.issues.map(\.id))
        #expect(enabled.issues.contains { issue in
            if case .horizontalDisplayArrangement = issue.kind { return true }
            return false
        })
    }

    @Test func singleMonitorHasNoArrangementWarningInAnyMode() {
        let single = [makeMonitor(name: "Only", displayId: 303, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))]

        #expect(!DisplayEnvironmentDiagnostics.evaluate(monitors: single, spacesMode: .enabled).hasWarnings)
        #expect(!DisplayEnvironmentDiagnostics.evaluate(monitors: single, spacesMode: .disabled).hasWarnings)
        #expect(!DisplayEnvironmentDiagnostics.evaluate(monitors: single, spacesMode: .unavailable).hasWarnings)
    }

    @Test func evaluateWithoutSpacesModeIsHistoricalBehavior() {
        let monitors = sideBySideMonitors()
        let legacy = DisplayEnvironmentDiagnostics.evaluate(monitors: monitors)
        let explicit = DisplayEnvironmentDiagnostics.evaluate(monitors: monitors, spacesMode: .enabled)

        #expect(legacy.issues.map(\.id) == explicit.issues.map(\.id))
    }

    @Test func displayModeLabelsAreUserReadable() {
        #expect(DisplaySpacesMode.enabled.displayName == "Enabled")
        #expect(DisplaySpacesMode.disabled.displayName == "Disabled")
        #expect(DisplaySpacesMode.unavailable.displayName == "Unavailable")
    }
}
