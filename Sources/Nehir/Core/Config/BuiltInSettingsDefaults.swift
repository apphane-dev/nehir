import Foundation

enum BuiltInSettingsDefaults {
    static let niriColumnWidthPresets: [Double] = [
        0.33333333333333331,
        0.5,
        0.66666666666666663
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

    static let appRules: [AppRule] = [
        AppRule(
            bundleId: "com.openai.codex",
            minWidth: 800,
            minHeight: 600
        ),
        AppRule(
            bundleId: "com.eltima.cmd1.pro.mas",
            minWidth: 950,
            minHeight: 550
        ),
        AppRule(
            bundleId: "com.google.Chrome",
            minWidth: 500,
            minHeight: 375
        ),
        AppRule(
            bundleId: "dev.zed.Zed",
            minWidth: 360,
            minHeight: 240
        ),
        AppRule(
            bundleId: "com.apple.Safari",
            minWidth: 574,
            minHeight: 220
        ),
        AppRule(
            bundleId: "app.zen-browser.zen",
            minWidth: 500,
            minHeight: 495
        ),
        AppRule(
            bundleId: "org.mozilla.firefox",
            minWidth: 500,
            minHeight: 120
        ),
        AppRule(
            bundleId: "company.thebrowser.dia",
            minWidth: 500,
            minHeight: 420
        ),
        AppRule(
            bundleId: "com.spotify.client",
            minWidth: 800,
            minHeight: 600
        ),
        AppRule(
            bundleId: "com.hnc.Discord",
            minWidth: 800,
            minHeight: 500
        ),
        AppRule(
            bundleId: "com.microsoft.Outlook",
            minWidth: 930,
            minHeight: 650
        ),
        AppRule(
            bundleId: "com.apple.MobileSMS",
            minWidth: 660,
            minHeight: 320
        )
    ]

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
