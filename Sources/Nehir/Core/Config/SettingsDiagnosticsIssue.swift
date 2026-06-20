// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct UnknownSettingsKeysIssue: Identifiable, Equatable {
    let fileURL: URL
    let keyPaths: [String]

    var id: String {
        Self.postponeID(fileURL: fileURL)
    }

    static func postponeID(fileURL: URL) -> String {
        "unknown-settings-keys:\(fileURL.path)"
    }
}

enum SettingsDiagnosticsIssue: Identifiable, Equatable {
    case softMigration(PendingSettingsMigration)
    case unknownKeys(UnknownSettingsKeysIssue)

    var id: String {
        switch self {
        case .softMigration(let migration):
            return "migration:\(migration.id)"
        case .unknownKeys(let issue):
            return issue.id
        }
    }
}

enum SettingsDiagnosticsDetector {
    static func applicableIssues(
        configDirectory: URL = SettingsFilePersistence.defaultDirectoryURL
    ) -> [SettingsDiagnosticsIssue] {
        var issues = SettingsMigrationDetector.applicableMigrations(configDirectory: configDirectory)
            .map(SettingsDiagnosticsIssue.softMigration)

        let settingsURL = configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        let unknownKeys = detectUnknownKeys(in: settingsURL)
        if !unknownKeys.isEmpty {
            issues.append(.unknownKeys(UnknownSettingsKeysIssue(fileURL: settingsURL, keyPaths: unknownKeys)))
        }
        return issues
    }

    static func pendingIssues(
        configDirectory: URL = SettingsFilePersistence.defaultDirectoryURL,
        stateStore: SettingsMigrationStateStore = SettingsMigrationStateStore(),
        appVersion: String = Bundle.main.appVersion ?? "dev"
    ) -> [SettingsDiagnosticsIssue] {
        applicableIssues(configDirectory: configDirectory).filter { issue in
            !stateStore.isPostponed(migrationID: postponeID(for: issue), currentAppVersion: appVersion)
        }
    }

    static func postponeID(for issue: SettingsDiagnosticsIssue) -> String {
        switch issue {
        case .softMigration(let migration):
            return migration.id
        case .unknownKeys(let issue):
            return issue.id
        }
    }
}
