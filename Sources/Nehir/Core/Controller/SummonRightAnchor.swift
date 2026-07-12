// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct SummonRightAnchor: Equatable {
    let token: WindowToken?
    let workspaceId: WorkspaceDescriptor.ID
}

extension WMController {
    /// Resolves the destination and insertion anchor shared by every Summon
    /// Right UI surface. A supplied monitor owns the destination; interaction
    /// workspace is only a fallback when that monitor has no workspace.
    func summonRightAnchor(on monitorId: Monitor.ID?) -> SummonRightAnchor? {
        let activeWorkspace: WorkspaceDescriptor
        if let monitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            activeWorkspace = workspace
        } else if let workspace = interactionWorkspace() {
            activeWorkspace = workspace
        } else {
            return nil
        }

        let anchorToken = if let focusedToken = workspaceManager.confirmedManagedFocusToken,
                             let entry = workspaceManager.entry(for: focusedToken),
                             entry.workspaceId == activeWorkspace.id
        {
            focusedToken
        } else {
            workspaceManager.preferredWorkspaceFocusToken(in: activeWorkspace.id)
        }

        let validatedToken = anchorToken.flatMap { token -> WindowToken? in
            guard let entry = workspaceManager.entry(for: token),
                  entry.workspaceId == activeWorkspace.id
            else {
                return nil
            }
            return token
        }

        return SummonRightAnchor(token: validatedToken, workspaceId: activeWorkspace.id)
    }
}
