// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Observation

struct MotionSnapshot: Equatable, Sendable {
    let animationsEnabled: Bool

    static let enabled = MotionSnapshot(animationsEnabled: true)
    static let disabled = MotionSnapshot(animationsEnabled: false)
}

@MainActor @Observable
final class MotionPolicy {
    func snapshot() -> MotionSnapshot {
        .enabled
    }
}
