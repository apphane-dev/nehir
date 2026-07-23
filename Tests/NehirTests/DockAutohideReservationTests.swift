// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir
import Testing

/// Regression coverage for the #163 auto-hide Dock gate. The gate itself reads the
/// persistent `com.apple.dock autohide` preference and the Dock AX bar — unmocked OS
/// boundaries validated at runtime — so these tests exercise the two pure seams that
/// carry the policy: the memo TTL/fallback rules and the Dock-axis reclaim geometry.
@Suite struct DockAutohideReservationTests {
    // MARK: resolveAutohideMemo — TTL and last-value fallback

    @Test func freshMemoWithinTTLIsReusedAndFreshReadIgnored() {
        // A burst of Monitor.current() rebuilds within the TTL must reuse the cached
        // value and NOT adopt a differing fresh read (it would not have been synced).
        let cached = (uptime: 100.0, value: true)
        let result = DockReservation.resolveAutohideMemo(
            now: 100.5, ttl: 1.0, cached: cached, fresh: false
        )
        #expect(result.value == true)
        #expect(result.memo?.uptime == 100.0)
        #expect(result.memo?.value == true)
    }

    @Test func expiredMemoReprobesAndAdoptsFreshRead() {
        // Past the TTL, a readable fresh value is adopted and the memo re-timed.
        let cached = (uptime: 100.0, value: true)
        let result = DockReservation.resolveAutohideMemo(
            now: 102.0, ttl: 1.0, cached: cached, fresh: false
        )
        #expect(result.value == false)
        #expect(result.memo?.uptime == 102.0)
        #expect(result.memo?.value == false)
    }

    @Test func unreadableReadPreservesLastAuthoritativeValueWithoutOverwritingMemo() {
        // The #163 reconnect-churn case: a transient-nil read after the TTL expired must
        // fall back to the last authoritative value and leave the memo untouched, so the
        // fixed-Dock learn cannot momentarily re-arm.
        let cached = (uptime: 100.0, value: true)
        let result = DockReservation.resolveAutohideMemo(
            now: 103.0, ttl: 1.0, cached: cached, fresh: nil
        )
        #expect(result.value == true)
        #expect(result.memo?.uptime == 100.0)
        #expect(result.memo?.value == true)
    }

    @Test func unreadableReadWithNoPriorValueReportsNil() {
        // Cold start with an unreadable preference → nil, treated conservatively as fixed.
        let result = DockReservation.resolveAutohideMemo(
            now: 10.0, ttl: 1.0, cached: nil, fresh: nil
        )
        #expect(result.value == nil)
        #expect(result.memo == nil)
    }

    @Test func firstReadableValueSeedsTheMemo() {
        let result = DockReservation.resolveAutohideMemo(
            now: 10.0, ttl: 1.0, cached: nil, fresh: true
        )
        #expect(result.value == true)
        #expect(result.memo?.uptime == 10.0)
        #expect(result.memo?.value == true)
    }

    // MARK: reclaimedDockAxis — the auto-hide reclaim geometry

    @Test func bottomAutohideReclaimRestoresFullDockAxisAndKeepsMenuBarEdge() {
        // A mid-reveal AX sample would leave a positive bottom band (e.g. 78 pt). When the
        // auto-hide gate fires it reclaims the Dock (y) axis: origin.y back to frame.minY
        // and height extended to the previous top edge, while the 39-pt menu-bar band at
        // the top (maxY) is preserved.
        let frame = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        let banded = CGRect(x: 0, y: 78, width: 2056, height: 1212) // top edge = 1290
        let reclaimed = DockReservation.reclaimedDockAxis(from: banded, frame: frame, orientation: "bottom")
        #expect(reclaimed.origin.y == 0)
        #expect(reclaimed.maxY == 1290) // menu-bar edge untouched
        #expect(reclaimed.height == 1290)
        #expect(reclaimed.origin.x == banded.origin.x) // orthogonal axis untouched
        #expect(reclaimed.width == banded.width)
    }

    @Test func bottomReclaimIsIdempotentWhenNoBandPresent() {
        // An already-full working area (no reserved band) is unchanged on the Dock axis.
        let frame = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        let full = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        let reclaimed = DockReservation.reclaimedDockAxis(from: full, frame: frame, orientation: "bottom")
        #expect(reclaimed == full)
    }

    @Test func sideAutohideReclaimRestoresTheHorizontalAxis() {
        // A left auto-hide Dock reclaims the x axis to the physical left edge; the vertical
        // (menu-bar) extent is preserved.
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let banded = CGRect(x: 64, y: 0, width: 2496, height: 1415)
        let reclaimed = DockReservation.reclaimedDockAxis(from: banded, frame: frame, orientation: "left")
        #expect(reclaimed.origin.x == 0)
        #expect(reclaimed.maxX == 2560)
        #expect(reclaimed.origin.y == banded.origin.y)
        #expect(reclaimed.height == banded.height)
    }
}
