// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import ApplicationServices
import CoreGraphics
import Foundation

struct WindowToken: Hashable, Sendable {
    let pid: pid_t
    let windowId: Int
}

final class WindowHandle: Hashable {
    var id: WindowToken

    var token: WindowToken {
        id
    }

    var pid: pid_t {
        id.pid
    }

    var windowId: Int {
        id.windowId
    }

    init(id: WindowToken) {
        self.id = id
    }

    init(id: WindowToken, pid _: pid_t, axElement _: AXUIElement) {
        self.id = id
    }

    static func == (lhs: WindowHandle, rhs: WindowHandle) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
