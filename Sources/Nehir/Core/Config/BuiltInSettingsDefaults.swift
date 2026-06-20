// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum BuiltInSettingsDefaults {
    static let niriColumnWidthPresets: [Double] = [
        0.35,
        0.50,
        0.65,
        0.95
    ]

    static let workspaceConfigurations: [WorkspaceConfiguration] = [
        WorkspaceConfiguration(
            name: "1",
            monitorAssignment: .main
        ),
        WorkspaceConfiguration(
            name: "2",
            monitorAssignment: .main
        ),
        WorkspaceConfiguration(
            name: "3",
            monitorAssignment: .main
        ),
        WorkspaceConfiguration(
            name: "4",
            monitorAssignment: .main
        ),
        WorkspaceConfiguration(
            name: "5",
            monitorAssignment: .main
        ),
        WorkspaceConfiguration(
            name: "6",
            displayName: "\u{2764}\u{FE0F}",
            monitorAssignment: .secondary
        ),
        WorkspaceConfiguration(
            name: "7",
            displayName: "\u{1F680}",
            monitorAssignment: .secondary
        )
    ]

    // No bundled size rules: minimum window dimensions are now inferred at runtime
    // by `LayoutRefreshController.inferredResizeMinimumSize` (see `LayoutRefreshController.swift`),
    // which learns each window's actual resize floor when the app refuses a size write.
    // Users can still add their own rules via Settings → App Rules or `apprules.d/`.
    static let appRules: [AppRule] = []

    private static func uuid(_ value: String) -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("Invalid built-in settings UUID: \(value)")
        }
        return uuid
    }

    static func canonicalDefaults() -> CanonicalTOMLConfig {
        CanonicalTOMLConfig(export: SettingsExport.defaults())
    }
}
