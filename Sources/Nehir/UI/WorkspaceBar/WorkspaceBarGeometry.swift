// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics

struct WorkspaceBarGeometry: Equatable {
    let effectivePosition: WorkspaceBarPosition
    let menuBarHeight: CGFloat
    let barHeight: CGFloat
    let reservedTopInset: CGFloat

    static func resolve(
        monitor: Monitor,
        resolved: ResolvedBarSettings,
        isVisible: Bool,
        menuBarHeight: CGFloat? = nil
    ) -> WorkspaceBarGeometry {
        let resolvedMenuBarHeight = menuBarHeight ?? self.menuBarHeight(for: monitor)
        let effectivePosition = effectivePosition(for: monitor, resolved: resolved)
        let barHeight = max(0, CGFloat(resolved.height))
        let reservedTopInset = isVisible && resolved.reserveLayoutSpace ? barHeight : 0

        return WorkspaceBarGeometry(
            effectivePosition: effectivePosition,
            menuBarHeight: resolvedMenuBarHeight,
            barHeight: barHeight,
            reservedTopInset: reservedTopInset
        )
    }

    func frame(
        fittingWidth: CGFloat,
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> CGRect {
        let width = max(fittingWidth, 300)
        var x = monitor.frame.midX - width / 2
        // Anchor "below menu bar" to the physical top edge minus an explicit,
        // always-≥24 menu-bar reservation. `visibleFrame` no longer carries the
        // menu-bar inset under "Automatically hide and show the menu bar", so
        // anchoring to `visibleFrame.maxY` would otherwise land the bar in the
        // ~24pt strip the menu bar slides into. Idempotent when the menu bar is
        // visible (there `frame.maxY - visibleFrame.maxY == 24`), and also
        // correct for notched displays (whose inset already exceeds 24).
        var y = effectivePosition == .belowMenuBar
            ? monitor.frame.maxY - Self.standardMenuBarHeight(for: monitor) - barHeight
            : monitor.visibleFrame.maxY

        x += CGFloat(resolved.xOffset)
        y += CGFloat(resolved.yOffset)

        return CGRect(x: x, y: y, width: width, height: barHeight)
    }

    static func effectivePosition(
        for monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarPosition {
        if monitor.hasNotch,
           resolved.notchAware,
           resolved.position == .overlappingMenuBar
        {
            return .belowMenuBar
        }
        return resolved.position
    }

    static func menuBarHeight(for monitor: Monitor) -> CGFloat {
        let height = monitor.frame.maxY - monitor.visibleFrame.maxY
        return height > 0 ? height : 28
    }

    /// Explicit, always-≥24 menu-bar height used to anchor the workspace bar
    /// below the menu bar even when macOS auto-hides it. Unlike `visibleFrame`,
    /// this is immune to auto-hide dropping the top inset. Idempotent for a
    /// visible menu bar (inferred == 24) and for notched displays (inferred > 24).
    static func standardMenuBarHeight(for monitor: Monitor) -> CGFloat {
        max(monitor.frame.maxY - monitor.visibleFrame.maxY, 24)
    }

    /// Extra top strut the tile working area must reserve so managed windows
    /// do not underlap the auto-hidden menu bar's reveal region. Zero (no change)
    /// whenever the menu bar inset is already present in `visibleFrame` (visible
    /// menu bar or notch); 24 - inferred under auto-hide.
    static func additionalMenuBarTopStrut(for monitor: Monitor) -> CGFloat {
        max(0, 24 - (monitor.frame.maxY - monitor.visibleFrame.maxY))
    }
}
