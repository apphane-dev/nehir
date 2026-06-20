// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import NehirIPC
import Testing

@Suite struct IPCSocketPathTests {
    @Test func environmentOverrideWins() {
        let path = "/tmp/nehir-custom.sock"

        #expect(IPCSocketPath.resolvedPath(environment: [IPCSocketPath.environmentKey: path]) == path)
    }

    @Test func defaultPathUsesOmniWMCachesLocation() {
        let path = IPCSocketPath.resolvedPath(environment: [:], fileManager: .default)

        #expect(path.hasSuffix("/dev.guria.nehir/ipc.sock"))
    }

    @Test func secretPathLivesBesideSocketPath() {
        #expect(
            IPCSocketPath.secretPath(forSocketPath: "/tmp/nehir.sock") == "/tmp/nehir.sock.secret"
        )
    }
}
