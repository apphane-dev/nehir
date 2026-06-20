// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct Planner {
    func plan(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor]
    ) -> ActionPlan {
        StateReducer.reduce(
            event: event,
            existingEntry: existingEntry,
            currentSnapshot: currentSnapshot,
            monitors: monitors
        )
    }
}
