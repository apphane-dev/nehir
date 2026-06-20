// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import NehirIPC

enum WorkspaceTargetResolutionError: Equatable, Error {
    case invalidTarget
    case ambiguousDisplayName
    case notFound
}

@MainActor
struct WorkspaceTargetResolver {
    let settings: SettingsStore
    let workspaceManager: WorkspaceManager

    func resolve(_ target: WorkspaceTarget) -> Result<String, WorkspaceTargetResolutionError> {
        switch target {
        case let .rawID(rawID):
            guard WorkspaceIDPolicy.normalizeRawID(rawID) != nil else {
                return .failure(.invalidTarget)
            }
            guard workspaceManager.workspaceId(for: rawID, createIfMissing: false) != nil else {
                return .failure(.notFound)
            }
            return .success(rawID)
        case let .displayName(displayName):
            guard !displayName.isEmpty else {
                return .failure(.invalidTarget)
            }

            let matches = settings.workspaceConfigurations.filter {
                $0.effectiveDisplayName.caseInsensitiveCompare(displayName) == .orderedSame
            }

            guard !matches.isEmpty else {
                return .failure(.notFound)
            }
            guard matches.count == 1, let match = matches.first else {
                return .failure(.ambiguousDisplayName)
            }
            guard workspaceManager.workspaceId(for: match.name, createIfMissing: false) != nil else {
                return .failure(.notFound)
            }
            return .success(match.name)
        }
    }
}
