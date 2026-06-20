// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum ExternalCommandResult: Equatable, Sendable, Error {
    case executed
    case ignoredDisabled
    case ignoredOverview
    case staleWindowId
    case notFound
    case invalidArguments
    case invalidState
    case requiresDeveloperMode
    case internalError
}
