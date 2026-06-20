// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

struct InteractiveMove {
    let windowId: NodeId
    let windowHandle: WindowHandle
    let workspaceId: WorkspaceDescriptor.ID
    let startMouseLocation: CGPoint
    let originalColumnIndex: Int
    let originalFrame: CGRect
    let isInsertMode: Bool

    var currentHoverTarget: MoveHoverTarget?
}

enum MoveHoverTarget: Equatable {
    case window(nodeId: NodeId, handle: WindowHandle, insertPosition: InsertPosition)
    case columnGap(columnIndex: Int, insertPosition: InsertPosition)
    case workspaceEdge(side: HorizontalSide)
}

enum InsertPosition: Equatable {
    case before
    case after
    case swap
}

enum HorizontalSide: Equatable {
    case left
    case right
}

struct MoveConfiguration {
    var dragThreshold: CGFloat = 10.0

    static let `default` = MoveConfiguration()
}
