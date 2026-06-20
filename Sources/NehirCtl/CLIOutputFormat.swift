// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import NehirIPC

enum CLIOutputFormat: String, Equatable {
    case json
    case table
    case tsv
    case text

    var prefersJSON: Bool {
        self == .json
    }

    static func defaultFormat(for command: String?) -> CLIOutputFormat {
        switch command {
        case "query",
             "subscribe":
            .json
        default:
            .text
        }
    }
}

enum CLILocalAction: Equatable {
    case help
    case legalNotice
    case completion(CLIShell)
}

enum CLIInvocation: Equatable {
    case remote(IPCRequest)
    case local(CLILocalAction)
}

enum CLIShell: String, CaseIterable, Equatable {
    case zsh
    case bash
    case fish
}
