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
/// `MouseEventHandler` pokes the engine with) plus the focus-dependent reads
/// consumed by focus UI (`FocusBorderController`, keyboard-focus border
/// rendering): the fullscreen check and the on-screen frame query. Broader
/// engine reads — whole-layout snapshots, refresh-pipeline relayout,
/// lifecycle / topology sync — deliberately stay off this protocol; they are
/// infrastructure, not the interactive-mode boundary.
@MainActor protocol FocusCoordinator: AnyObject {
    /// Cancel an in-flight interactive move (mouse drag).
    func interactiveMoveCancel()
    /// Tear down any active interactive resize session.
    func clearInteractiveResize()
    /// Where the window backing `token` is on screen right now: the in-flight
    /// rendered frame during animation, else the committed layout frame.
    func preferredFrame(for token: WindowToken) -> CGRect?
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

    func preferredFrame(for token: WindowToken) -> CGRect? {
        niriEngine?.findNode(for: token)?.preferredFrame
    }

    func isFocusedWindowFullscreen(_ token: WindowToken) -> Bool {
        niriEngine?.findNode(for: token)?.isFullscreen ?? false
    }
}
