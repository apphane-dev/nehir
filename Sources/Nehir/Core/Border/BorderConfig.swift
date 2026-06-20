// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

struct BorderConfig: Equatable {
    var enabled: Bool
    var width: CGFloat
    var color: NSColor

    init(
        enabled: Bool = false,
        width: CGFloat = 4.0,
        color: NSColor = .systemBlue
    ) {
        self.enabled = enabled
        self.width = width
        self.color = color
    }

    @MainActor static func from(settings: SettingsStore) -> BorderConfig {
        let color = NSColor(
            red: CGFloat(settings.borderColorRed),
            green: CGFloat(settings.borderColorGreen),
            blue: CGFloat(settings.borderColorBlue),
            alpha: CGFloat(settings.borderColorAlpha)
        )
        return BorderConfig(
            enabled: settings.bordersEnabled,
            width: CGFloat(settings.borderWidth),
            color: color
        )
    }
}
