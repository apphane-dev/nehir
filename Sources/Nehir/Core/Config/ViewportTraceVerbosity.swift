// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Controls how much a Niri viewport runtime trace capture records. A single
/// concept with three presets instead of a sprawl of independent toggles, so a
/// user picks "how detailed" rather than reasoning about flag combinations.
///
/// - `lean`: viewport flow/decision events and state only. No per-line column
///   layout dump, no per-animation-frame gesture updates, no per-mutation
///   provenance. Smallest captures; use when you only need the event sequence.
/// - `standard` (default): adds the per-line column layout dump, which is what
///   most viewport/position diagnostics need to interpret snaps and offsets.
///   Still skips the per-frame gesture-update firehose and the heavy audit.
/// - `verbose`: adds per-animation-frame `touch_scroll_gesture_update` records
///   and the `lastViewportMutation*` audit fields, for gesture-snap and
///   unrecorded-mutation attribution. Largest captures.
enum ViewportTraceVerbosity: String, CaseIterable, Codable, Identifiable {
    case lean
    case standard
    case verbose

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .lean: "Lean"
        case .standard: "Standard"
        case .verbose: "Verbose"
        }
    }

    var includesLayoutDump: Bool {
        self != .lean
    }

    var includesGestureFrameUpdates: Bool {
        self == .verbose
    }

    var includesMutationAudit: Bool {
        self == .verbose
    }
}
