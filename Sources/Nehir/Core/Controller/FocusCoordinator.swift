// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

/// The explicit seam for interactive-mode cancellation and focus-dependent
/// read queries, so handlers do not reach into the live `niriEngine` directly.
///
/// This is the boundary a *new* interactive mode (a gesture-driven mode, or a
/// non-Niri layout's focus model) would implement. Today the sole conformer is
/// `WMController`, which forwards to `niriEngine`.
///
/// The member set is the interactive-cancel surface (the two ops
/// `MouseEventHandler` pokes the engine with) plus the focus-fullscreen read
/// consumed by focus-dependent UI (`FocusBorderController`). Broader engine
/// reads — whole-layout snapshots, refresh-pipeline relayout, lifecycle /
/// topology sync, rendered-frame lookups — are assessed in Phase 4 and
/// deliberately stay off this protocol; they are infrastructure, not the
/// interactive-mode boundary.
@MainActor protocol FocusCoordinator: AnyObject {
    /// Cancel an in-flight interactive move (mouse drag).
    func interactiveMoveCancel()
    /// Tear down any active interactive resize session.
    func clearInteractiveResize()
    /// Read-only focus query: the layout node backing a window token, if any.
    func focusedNode(for token: WindowToken) -> NiriNode?
    /// Whether the window backing `token` is currently laid out fullscreen.
    func isFocusedWindowFullscreen(_ token: WindowToken) -> Bool
}

// Adaptor: `WMController` forwards to the live `niriEngine`. Reads stay
// optional-safe — a missing engine reports no node / not-fullscreen, matching
// the previous `controller.niriEngine?.` reach-through behavior exactly.
extension WMController: FocusCoordinator {
    func interactiveMoveCancel() {
        niriEngine?.interactiveMoveCancel()
    }

    func clearInteractiveResize() {
        niriEngine?.clearInteractiveResize()
    }

    // `NiriLayoutEngine.findNode(for:)` returns `NiriWindow?`; returning it as
    // `NiriNode?` is a covariant upcast (`NiriWindow: NiriNode`).
    func focusedNode(for token: WindowToken) -> NiriNode? {
        niriEngine?.findNode(for: token)
    }

    func isFocusedWindowFullscreen(_ token: WindowToken) -> Bool {
        niriEngine?.findNode(for: token)?.isFullscreen ?? false
    }
}
