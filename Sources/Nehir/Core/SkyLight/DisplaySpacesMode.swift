// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Whether macOS "Displays have separate Spaces" is enabled, as observed by Nehir.
///
/// Stage 1 (M4) uses this only for diagnostics: with Separate Spaces **ON**, each
/// display's surfaces are isolated, so the side-by-side parked-window bleed that
/// motivates Nehir's vertical-arrangement recommendation does not occur, and an
/// experimental-support notice is surfaced instead. Mode detection lives on
/// `SkyLight.displaySpacesMode(monitors:)`; see
/// `discovery/20260618-displays-separate-spaces-mode-detection.md`.
public enum DisplaySpacesMode: String, Sendable, Equatable {
    /// "Displays have separate Spaces" is ON: each display has its own set of Spaces.
    case enabled
    /// Separate Spaces is OFF: displays share a single space set (the default macOS mode).
    case disabled
    /// The mode could not be determined (private symbol missing, single display,
    /// or indeterminate managed-display-spaces shape). Callers should keep their
    /// current conservative behavior.
    case unavailable

    var displayName: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .enabled: "rectangle.connected.to.line.below"
        case .disabled: "rectangle.on.rectangle"
        case .unavailable: "questionmark.circle"
        }
    }
}
