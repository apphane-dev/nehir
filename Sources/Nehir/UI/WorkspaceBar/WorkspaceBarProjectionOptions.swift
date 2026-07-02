// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct WorkspaceBarProjectionOptions: Equatable {
    let deduplicateAppIcons: Bool
    let hideEmptyWorkspaces: Bool
    let showFloatingWindows: Bool
    let showWorkspacesFromOtherDisplays: Bool
}

extension ResolvedBarSettings {
    var projectionOptions: WorkspaceBarProjectionOptions {
        WorkspaceBarProjectionOptions(
            deduplicateAppIcons: deduplicateAppIcons,
            hideEmptyWorkspaces: hideEmptyWorkspaces,
            showFloatingWindows: showFloatingWindows,
            showWorkspacesFromOtherDisplays: showWorkspacesFromOtherDisplays
        )
    }
}
