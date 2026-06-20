// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Kinds of derived projections that can be invalidated by state mutations.
///
/// Routing status:
/// - `workspaceProjection`: triggers coalesced workspace bar + IPC refresh.
/// - `focusProjection`: triggers coalesced status bar refresh.
/// - `settingsProjection`: triggers coalesced status bar refresh.
/// - `displayProjection`: tracked for debug observability; co-emitted with
///   `workspaceProjection` so the actual refresh is covered by the companion
///   invalidation. Reserved for future status bar geometry updates.
/// - `layoutProjection`: tracked for debug observability; not yet emitted.
///   Tabbed overlay and focus border updates use direct calls because they
///   require immediate frame-precise updates or specific ordering context
///   (e.g. `forceOrdering: true` after rekey, pre-transition activation)
///   that cannot be coalesced on a later main-actor turn.
enum ProjectionInvalidation: Hashable {
    case workspaceProjection
    case focusProjection
    case layoutProjection
    case displayProjection
    case settingsProjection
}

struct ProjectionInvalidationRequest: Hashable {
    var kind: ProjectionInvalidation
    var reason: String

    init(_ kind: ProjectionInvalidation, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}
