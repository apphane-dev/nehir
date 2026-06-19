import Foundation

struct PureLayoutInvariantViolation: Equatable, CustomStringConvertible {
    var message: String

    var description: String { message }
}

enum PureLayoutInvariants {
    static func validate<WSID: Hashable, ID: Hashable>(
        _ world: CoreWorld<WSID, ID>
    ) -> [PureLayoutInvariantViolation] {
        var violations: [PureLayoutInvariantViolation] = []

        if !world.workspaces.isEmpty, !world.workspaces.indices.contains(world.activeWorkspaceIndex) {
            violations.append(.init(message: "activeWorkspaceIndex is out of bounds"))
        }

        var windowIDs = Set<ID>()
        var maxColumnID = Int.min

        for (workspaceIndex, workspace) in world.workspaces.enumerated() {
            if workspace.columns.isEmpty {
                if workspace.activeColumnIndex != nil {
                    violations.append(.init(message: "empty workspace at index \(workspaceIndex) has activeColumnIndex"))
                }
            } else {
                if workspace.activeColumnIndex == nil || !workspace.columns.indices.contains(workspace.activeColumnIndex!) {
                    violations.append(.init(message: "workspace at index \(workspaceIndex) has invalid activeColumnIndex"))
                }
            }

            var columnIDs = Set<CoreColumnID>()
            for (columnIndex, column) in workspace.columns.enumerated() {
                if !columnIDs.insert(column.id).inserted {
                    violations.append(.init(message: "duplicate column id \(column.id.rawValue) in workspace index \(workspaceIndex)"))
                }
                maxColumnID = max(maxColumnID, column.id.rawValue)

                if column.windows.isEmpty {
                    violations.append(.init(message: "empty column at workspace index \(workspaceIndex), column index \(columnIndex)"))
                } else if !column.windows.indices.contains(column.activeWindowIndex) {
                    violations.append(.init(message: "column at workspace index \(workspaceIndex), column index \(columnIndex) has invalid activeWindowIndex"))
                }

                for window in column.windows {
                    if !windowIDs.insert(window.id).inserted {
                        violations.append(.init(message: "duplicate window id \(window.id)"))
                    }
                }
            }
        }

        if maxColumnID != Int.min, world.nextColumnID <= maxColumnID {
            violations.append(.init(message: "nextColumnID must be greater than existing column ids"))
        }

        return violations
    }
}
