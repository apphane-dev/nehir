// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct WMCommandTarget: Equatable {
    enum Source: Equatable {
        case layoutSelection
        case confirmedManagedFocus
        case frontmostManagedFallback
        case samePidFloatingFallback
    }

    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let source: Source
}
