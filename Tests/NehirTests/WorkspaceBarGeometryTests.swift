// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir
import Testing

/// Characterization tests for Nehir #68 — workspace bar must sit below an
/// auto-hidden menu bar. `frame()` now anchors `.belowMenuBar` to the physical
/// top edge minus an explicit, always-≥24 menu-bar reservation instead of the
/// auto-hide-sensitive `visibleFrame.maxY`. See
/// `planned/20260619-nehir-68-workspace-bar-autohidden-menu-bar.md`.
@MainActor
@Suite
struct WorkspaceBarGeometryTests {
    private let barHeight: CGFloat = 28

    /// Synthetic monitor: `inset` is `frame.maxY - visibleFrame.maxY`.
    /// `inset == 0` simulates "Automatically hide and show the menu bar" (AppKit
    /// no longer reserves the menu bar in visibleFrame); `inset == 24` simulates
    /// a visible menu bar; `inset == 32` simulates a notched display.
    private func monitor(
        width: CGFloat = 1600,
        height: CGFloat = 1000,
        inset: CGFloat,
        hasNotch: Bool = false
    ) -> Monitor {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let visibleFrame = CGRect(x: 0, y: 0, width: width, height: height - inset)
        return Monitor(
            id: Monitor.ID(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: visibleFrame,
            hasNotch: hasNotch,
            name: "Test"
        )
    }

    private func resolved(position: WorkspaceBarPosition, reserveLayoutSpace: Bool = true) -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            showTraceButton: false,
            showScrollLockButton: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            reserveLayoutSpace: reserveLayoutSpace,
            notchAware: true,
            position: position,
            windowLevel: .popup,
            height: Double(barHeight),
            backgroundOpacity: 0.1,
            xOffset: 0.0,
            yOffset: 0.0,
            accentColor: nil,
            textColor: nil
        )
    }

    // MARK: - standardMenuBarHeight / additionalMenuBarTopStrut

    @Test func standardMenuBarHeightFloorsAt24UnderAutoHide() {
        // inset 0 (auto-hide) -> 24, not 0.
        #expect(WorkspaceBarGeometry.standardMenuBarHeight(for: monitor(inset: 0)) == 24)
    }

    @Test func standardMenuBarHeightUsesInferredWhenLarger() {
        // visible menu bar (inset 24) -> 24; notch (inset 32) -> 32.
        #expect(WorkspaceBarGeometry.standardMenuBarHeight(for: monitor(inset: 24)) == 24)
        #expect(WorkspaceBarGeometry.standardMenuBarHeight(for: monitor(inset: 32, hasNotch: true)) == 32)
    }

    @Test func additionalMenuBarTopStrutIsZeroWhenInsetAlreadyPresent() {
        // No extra strut when the menu bar / notch inset is already in visibleFrame.
        #expect(WorkspaceBarGeometry.additionalMenuBarTopStrut(for: monitor(inset: 24)) == 0)
        #expect(WorkspaceBarGeometry.additionalMenuBarTopStrut(for: monitor(inset: 32, hasNotch: true)) == 0)
    }

    @Test func additionalMenuBarTopStrutFillsAutoHideGap() {
        // Auto-hide (inset 0) -> 24pt extra strut so tiles clear the reveal region.
        #expect(WorkspaceBarGeometry.additionalMenuBarTopStrut(for: monitor(inset: 0)) == 24)
    }

    // MARK: - frame(): belowMenuBar anchoring

    @Test func belowMenuBarAnchoredBelowExplicitMenuBarInsetUnderAutoHide() {
        // The reported bug: auto-hide. The bar must drop below the 24pt reveal strip,
        // NOT sit at the very top edge (frame.maxY - barHeight).
        let m = monitor(inset: 0)
        let geometry = WorkspaceBarGeometry.resolve(
            monitor: m,
            resolved: resolved(position: .belowMenuBar),
            isVisible: true
        )
        let frame = geometry.frame(fittingWidth: 400, monitor: m, resolved: resolved(position: .belowMenuBar))
        // Bar bottom = frame.maxY - 24 - barHeight; bar occupies the 28pt above that.
        #expect(frame.maxY == m.frame.maxY - 24)
        #expect(frame.minY == m.frame.maxY - 24 - barHeight)
        // Critical: it must NOT occupy the top reveal strip.
        #expect(frame.maxY < m.frame.maxY)
    }

    @Test func belowMenuBarUnchangedForVisibleMenuBar() {
        // Idempotency: with a visible menu bar (inset 24) the bar placement must
        // equal the pre-fix `visibleFrame.maxY - barHeight` result.
        let m = monitor(inset: 24)
        let geometry = WorkspaceBarGeometry.resolve(
            monitor: m,
            resolved: resolved(position: .belowMenuBar),
            isVisible: true
        )
        let frame = geometry.frame(fittingWidth: 400, monitor: m, resolved: resolved(position: .belowMenuBar))
        let preFixBottom = m.visibleFrame.maxY - barHeight
        #expect(frame.minY == preFixBottom)
    }

    @Test func belowMenuBarUnchangedForNotchedDisplay() {
        // A notched display already has a >24 inset; the reservation must match it.
        let m = monitor(inset: 32, hasNotch: true)
        let geometry = WorkspaceBarGeometry.resolve(
            monitor: m,
            resolved: resolved(position: .belowMenuBar),
            isVisible: true
        )
        let frame = geometry.frame(fittingWidth: 400, monitor: m, resolved: resolved(position: .belowMenuBar))
        #expect(frame.minY == m.visibleFrame.maxY - barHeight)
        #expect(frame.maxY == m.frame.maxY - 32)
    }

    @Test func overlappingMenuBarAnchoredToVisibleFrameUnchanged() {
        // Overlap mode is intentionally unchanged: bar bottom at visibleFrame.maxY,
        // extending upward into the menu-bar region.
        let m = monitor(inset: 24)
        let geometry = WorkspaceBarGeometry.resolve(
            monitor: m,
            resolved: resolved(position: .overlappingMenuBar),
            isVisible: true
        )
        let frame = geometry.frame(fittingWidth: 400, monitor: m, resolved: resolved(position: .overlappingMenuBar))
        #expect(frame.minY == m.visibleFrame.maxY)
    }
}
