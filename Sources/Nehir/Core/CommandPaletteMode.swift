// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum CommandPaletteMode: String, CaseIterable, Codable {
    case windows
    case menu
    case commands

    var displayName: String {
        switch self {
        case .windows: "Windows"
        case .menu: "Menu"
        case .commands: "Commands"
        }
    }
}
