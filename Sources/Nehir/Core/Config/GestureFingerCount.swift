// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

enum GestureFingerCount: Int, CaseIterable, Codable {
    case two = 2
    case three = 3
    case four = 4

    var displayName: String {
        switch self {
        case .two: "2 Fingers"
        case .three: "3 Fingers"
        case .four: "4 Fingers"
        }
    }
}
