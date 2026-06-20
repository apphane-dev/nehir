// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum NiriSizeChange: Codable, Equatable, Hashable {
    case setFixed(CGFloat)
    case setProportion(CGFloat)
    case adjustFixed(CGFloat)
    case adjustProportion(CGFloat)

    static let maxPixels: CGFloat = 100_000
    static let maxProportion: CGFloat = 10_000
}
