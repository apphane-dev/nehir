// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir
import Testing

/// Tests for `NiriMonitor` orientation handling.
///
/// Covers the leaf hardening in `updateOutputSize` (preserve a stored override
/// when no explicit orientation argument is supplied) and the `init` fallback
/// regression guard. See P3 in the upstream-port patch track.
@Suite struct NiriMonitorTests {
    /// Portrait (900×1600) fixture: `autoOrientation == .vertical`.
    private func portraitMonitor() -> Monitor {
        makeLayoutPlanTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(42),
            name: "Portrait",
            width: 900,
            height: 1600
        )
    }

    /// Landscape (1920×1080) fixture: `autoOrientation == .horizontal`.
    private func landscapeMonitor() -> Monitor {
        makeLayoutPlanTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(43),
            name: "Landscape",
            width: 1920,
            height: 1080
        )
    }

    @Test func updateOutputSizePreservesExistingOrientationWhenCalledWithNil() {
        let monitor = portraitMonitor()
        let niri = NiriMonitor(monitor: monitor, orientation: .horizontal)
        #expect(niri.orientation == .horizontal)

        // Reconfigure with a new frame but no explicit orientation argument.
        // The stored `.horizontal` override must survive; auto would be `.vertical`.
        let refreshedMonitor = Monitor(
            id: monitor.id,
            displayId: monitor.displayId,
            frame: CGRect(x: 0, y: 0, width: 901, height: 1601),
            visibleFrame: CGRect(x: 0, y: 0, width: 901, height: 1601),
            hasNotch: false,
            name: monitor.name
        )
        niri.updateOutputSize(monitor: refreshedMonitor, orientation: nil)

        #expect(niri.orientation == .horizontal)
        #expect(niri.frame == refreshedMonitor.frame)
        #expect(niri.visibleFrame == refreshedMonitor.visibleFrame)
    }

    @Test func updateOutputSizeAppliesExplicitOrientationOverride() {
        let monitor = portraitMonitor()
        // Construct with the auto orientation (no override).
        let niri = NiriMonitor(monitor: monitor, orientation: nil)
        #expect(niri.orientation == .vertical)

        // Supplying an explicit orientation still wins.
        niri.updateOutputSize(monitor: monitor, orientation: .horizontal)
        #expect(niri.orientation == .horizontal)
    }

    @Test func initFallsBackToAutoOrientationWhenNoOverride() {
        #expect(NiriMonitor(monitor: portraitMonitor(), orientation: nil).orientation == .vertical)
        #expect(NiriMonitor(monitor: landscapeMonitor(), orientation: nil).orientation == .horizontal)
    }
}
