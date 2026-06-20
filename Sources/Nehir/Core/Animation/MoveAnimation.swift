// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct MoveAnimation {
    let animation: SpringAnimation
    let fromOffset: CGFloat

    func currentOffset(at time: TimeInterval) -> CGFloat {
        fromOffset * CGFloat(animation.value(at: time))
    }

    func currentVelocity(at time: TimeInterval) -> Double {
        animation.velocity(at: time)
    }

    func isComplete(at time: TimeInterval) -> Bool {
        animation.isComplete(at: time)
    }
}

struct CubicMoveAnimation {
    let animation: CubicAnimation
    let fromOffset: CGFloat

    func currentOffset(at time: TimeInterval) -> CGFloat {
        fromOffset * CGFloat(animation.value(at: time))
    }

    func currentVelocity(at time: TimeInterval) -> CGFloat {
        CGFloat(animation.velocity(at: time)) * fromOffset
    }

    func isComplete(at time: TimeInterval) -> Bool {
        animation.isComplete(at: time)
    }
}
