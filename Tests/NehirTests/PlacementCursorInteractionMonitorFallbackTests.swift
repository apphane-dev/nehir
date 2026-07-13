// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation
@testable import Nehir
import Testing

/// Placement regression coverage for the reported bug: activating an app on the
/// external display (e.g. clicking its desktop and hitting ⌘N in Finder) admitted
/// the new window on the built-in display. macOS reports the new window's
/// WindowServer frame in an off-screen park zone, which `monitorApproximation`
/// snaps to the nearest (often built-in) display; placement then trusted that
/// snapped frame monitor over the signals that actually point at the display the
/// user is on — the cursor monitor and the interaction monitor.
@MainActor
struct PlacementCursorInteractionMonitorFallbackTests {
    /// Frame contained by neither monitor. Center `(800, -900)` sits above both
    /// displays (both start at y = 0); nearest-snap resolves it to the primary,
    /// which is the trap the cursor/interaction signals must override.
    private static let offScreenFrame = CGRect(x: 400, y: -1200, width: 800, height: 600)

    private func makeContext(
        cursorMonitorId: Monitor.ID?,
        interactionMonitorId: Monitor.ID?,
        nativeSpaceMonitorId: Monitor.ID? = nil
    ) -> WindowCreatePlacementContext {
        WindowCreatePlacementContext(
            nativeSpaceMonitorId: nativeSpaceMonitorId,
            activeFocusRequestWorkspaceId: nil,
            activeFocusRequestMonitorId: nil,
            focusedWorkspaceId: nil,
            focusedMonitorId: nil,
            interactionMonitorId: interactionMonitorId,
            cursorMonitorId: cursorMonitorId,
            source: "ax_focused_admission_synthesized",
            focusedWorkspaceSource: nil,
            recentPidWorkspaceId: nil,
            createdAt: Date()
        )
    }

    /// The cursor monitor wins over the mis-snapped off-screen frame monitor.
    @Test func offScreenFramePrefersCursorMonitor() async {
        await withAXFrameProviderIsolationForTests {
            let fixture = makeTwoMonitorLayoutPlanTestController()
            AXWindowService.fastFrameProviderForTests = { _ in nil }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            let resolved = fixture.controller.resolveWorkspaceForNewWindow(
                axRef: makeLayoutPlanTestWindow(windowId: 9001),
                pid: getpid(),
                createPlacementContext: makeContext(
                    cursorMonitorId: fixture.secondaryMonitor.id,
                    interactionMonitorId: nil
                ),
                windowFrame: Self.offScreenFrame,
                fallbackWorkspaceId: fixture.primaryWorkspaceId
            )

            #expect(resolved == fixture.secondaryWorkspaceId)
        }
    }

    /// The reported bug's core: the interaction monitor can be stale (it is written
    /// only by Nehir-managed actions, so a plain desktop click on another display
    /// leaves it pointing at the previous display). The cursor monitor reflects where
    /// the user actually is, so for an off-screen frame it must win over a stale
    /// interaction monitor pointing elsewhere.
    @Test func offScreenFramePrefersCursorOverStaleInteractionMonitor() async {
        await withAXFrameProviderIsolationForTests {
            let fixture = makeTwoMonitorLayoutPlanTestController()
            AXWindowService.fastFrameProviderForTests = { _ in nil }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            let resolved = fixture.controller.resolveWorkspaceForNewWindow(
                axRef: makeLayoutPlanTestWindow(windowId: 9002),
                pid: getpid(),
                createPlacementContext: makeContext(
                    cursorMonitorId: fixture.secondaryMonitor.id,
                    interactionMonitorId: fixture.primaryMonitor.id
                ),
                windowFrame: Self.offScreenFrame,
                fallbackWorkspaceId: fixture.primaryWorkspaceId
            )

            #expect(resolved == fixture.secondaryWorkspaceId)
        }
    }

    /// A claimed native space is authoritative and outranks the cursor branch: the
    /// cursor fallback is gated on `nativeSpaceMonitorId == nil`, so when the new
    /// window's space resolves to the primary display the placement must land there
    /// even for an off-screen frame with the cursor over the secondary display.
    @Test func nativeSpaceMonitorWinsOverCursorMonitor() async {
        await withAXFrameProviderIsolationForTests {
            let fixture = makeTwoMonitorLayoutPlanTestController()
            AXWindowService.fastFrameProviderForTests = { _ in nil }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            let resolved = fixture.controller.resolveWorkspaceForNewWindow(
                axRef: makeLayoutPlanTestWindow(windowId: 9004),
                pid: getpid(),
                createPlacementContext: makeContext(
                    cursorMonitorId: fixture.secondaryMonitor.id,
                    interactionMonitorId: nil,
                    nativeSpaceMonitorId: fixture.primaryMonitor.id
                ),
                windowFrame: Self.offScreenFrame,
                fallbackWorkspaceId: fixture.primaryWorkspaceId
            )

            #expect(resolved == fixture.primaryWorkspaceId)
        }
    }

    /// A window the user positioned on a specific display before admission — an
    /// on-screen WindowServer frame contained by exactly one monitor — is still
    /// honored by the frame monitor, not stolen by a cursor/interaction monitor
    /// that points elsewhere.
    @Test func onScreenFrameStillHonorsFrameMonitor() async {
        await withAXFrameProviderIsolationForTests {
            let fixture = makeTwoMonitorLayoutPlanTestController()
            AXWindowService.fastFrameProviderForTests = { _ in nil }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            // Center (2200, 250): inside the secondary monitor (1920…3840 × 0…1080).
            let onScreenSecondaryFrame = CGRect(x: 2000, y: 100, width: 400, height: 300)

            let resolved = fixture.controller.resolveWorkspaceForNewWindow(
                axRef: makeLayoutPlanTestWindow(windowId: 9003),
                pid: getpid(),
                createPlacementContext: makeContext(
                    cursorMonitorId: fixture.primaryMonitor.id,
                    interactionMonitorId: fixture.primaryMonitor.id
                ),
                windowFrame: onScreenSecondaryFrame,
                fallbackWorkspaceId: fixture.primaryWorkspaceId
            )

            #expect(resolved == fixture.secondaryWorkspaceId)
        }
    }
}
