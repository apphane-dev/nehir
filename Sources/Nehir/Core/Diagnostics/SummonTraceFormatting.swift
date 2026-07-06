// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum SummonTraceFormatting {
    static func describe(_ monitorId: Monitor.ID?) -> String {
        monitorId.map { String(describing: $0) } ?? "nil"
    }

    static func describe(_ workspaceId: WorkspaceDescriptor.ID?) -> String {
        workspaceId?.uuidString ?? "nil"
    }

    static func describe(_ token: WindowToken?) -> String {
        token.map { String(describing: $0) } ?? "nil"
    }

    static func describe(_ anchor: CommandPaletteSummonAnchor?) -> String {
        guard let anchor else { return "nil" }
        return "token=\(describe(anchor.token)),workspace=\(anchor.workspaceId.uuidString)"
    }
}
