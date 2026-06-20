// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// One curated Nehir default hotkey that is known to overlap common macOS system
/// shortcuts (or another launcher). macOS resolves such chords system-wide, so the
/// system handler fires alongside Nehir even though Nehir's Carbon registration
/// succeeds — meaning `HotkeyCenter.registrationFailures` cannot capture it. These
/// advisories make the co-fire case self-diagnosing.
///
/// Advisories are consulted by `SettingsDiagnosticsDetector` and surface only while
/// the user remains on the default chord; reassigning or unassigning the hotkey
/// suppresses the advisory (no false positives on custom chords).
struct CuratedHotkeyAdvisory: Equatable {
    let actionID: String
    let command: HotkeyCommand
    let advisoryText: String
}

enum HotkeyAdvisoryCatalog {
    /// Hand-maintained list of Nehir default chords known to co-fire with macOS.
    /// Add new entries here when a default is found to collide with a common system
    /// shortcut; keep the list small and default-chord-scoped to avoid crying wolf.
    static let knownSystemConflicts: [CuratedHotkeyAdvisory] = [
        CuratedHotkeyAdvisory(
            actionID: "openCommandPalette",
            command: .openCommandPalette,
            advisoryText: "Your Command Palette shortcut (Option+Command+Space) can also be claimed by a macOS system shortcut (e.g. Input Sources) or another launcher, which will fire alongside Nehir. If pressing it also opens another app, reassign this Nehir hotkey in Hotkeys, or clear the conflicting shortcut in System Settings → Keyboard → Keyboard Shortcuts."
        )
    ]
}
