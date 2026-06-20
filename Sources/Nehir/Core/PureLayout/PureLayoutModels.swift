// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct PureLayoutConfig: Equatable {
    var infiniteLoop: Bool = false
}

struct CoreColumnID: Hashable, Equatable {
    var rawValue: Int
}

struct CoreWindow<ID: Hashable>: Equatable {
    var id: ID
}

struct CoreColumn<ID: Hashable>: Equatable {
    var id: CoreColumnID

    /// Storage order, not visual order. Index 0 is visual bottom.
    var windows: [CoreWindow<ID>]

    /// Storage index of the active/focused tile within this column.
    var activeWindowIndex: Int
}

struct CoreWorkspace<WSID: Hashable, ID: Hashable>: Equatable {
    var id: WSID
    var columns: [CoreColumn<ID>]

    /// Nil only when the workspace has zero columns/windows.
    var activeColumnIndex: Int?
}

struct CoreWorld<WSID: Hashable, ID: Hashable>: Equatable {
    var workspaces: [CoreWorkspace<WSID, ID>]
    var activeWorkspaceIndex: Int
    var nextColumnID: Int
    var config: PureLayoutConfig
}

extension CoreWorkspace {
    var activeColumn: CoreColumn<ID>? {
        guard let activeColumnIndex, columns.indices.contains(activeColumnIndex) else { return nil }
        return columns[activeColumnIndex]
    }

    var focusedWindowID: ID? {
        guard let activeColumn else { return nil }
        guard activeColumn.windows.indices.contains(activeColumn.activeWindowIndex) else { return nil }
        return activeColumn.windows[activeColumn.activeWindowIndex].id
    }
}

extension CoreWorld {
    var activeWorkspace: CoreWorkspace<WSID, ID>? {
        guard workspaces.indices.contains(activeWorkspaceIndex) else { return nil }
        return workspaces[activeWorkspaceIndex]
    }
}
