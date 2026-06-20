// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

extension Notification.Name {
    static let settingsMigrationStateDidChange = Notification.Name("NehirSettingsMigrationStateDidChange")
}

struct SettingsMigrationDescriptor: Identifiable, Equatable {
    let id: String
    let title: String
    let fileName: String
    let oldFormatSummary: String
    let newFormatSummary: String
    let warningBody: String
    let enforcementWarning: String
}

enum SettingsMigrationRegistry {
    static let workspacesArrayToKeyedTables = SettingsMigrationDescriptor(
        id: "workspaces-array-to-keyed-tables",
        title: "Update workspace config",
        fileName: SettingsFilePersistence.workspacesFileName,
        oldFormatSummary: "[[workspace]] entries",
        newFormatSummary: "[1], [2], [6], etc.",
        warningBody: "workspaces.toml uses the old [[workspace]] style. Nehir can still read it, but the new format is shorter: [1], [2], [6], etc.",
        enforcementWarning: "A future Nehir update may require the new format."
    )

    static let all: [SettingsMigrationDescriptor] = [
        workspacesArrayToKeyedTables
    ]
}

struct PendingSettingsMigration: Identifiable, Equatable {
    let descriptor: SettingsMigrationDescriptor
    let fileURL: URL

    var id: String {
        descriptor.id
    }
}

enum SettingsMigrationDetector {
    static func applicableMigrations(
        configDirectory: URL = SettingsFilePersistence.defaultDirectoryURL
    ) -> [PendingSettingsMigration] {
        let workspaceDescriptor = SettingsMigrationRegistry.workspacesArrayToKeyedTables
        let workspacesURL = configDirectory.appendingPathComponent(workspaceDescriptor.fileName, isDirectory: false)

        guard WorkspacesConfigMigration.needsMigration(fileURL: workspacesURL) else {
            return []
        }

        return [PendingSettingsMigration(descriptor: workspaceDescriptor, fileURL: workspacesURL)]
    }

    static func pendingMigrations(
        configDirectory: URL = SettingsFilePersistence.defaultDirectoryURL,
        stateStore: SettingsMigrationStateStore = SettingsMigrationStateStore(),
        appVersion: String = Bundle.main.appVersion ?? "dev"
    ) -> [PendingSettingsMigration] {
        applicableMigrations(configDirectory: configDirectory).filter {
            !stateStore.isPostponed(migrationID: $0.id, currentAppVersion: appVersion)
        }
    }
}

enum WorkspacesConfigMigration {
    static let migrationID = SettingsMigrationRegistry.workspacesArrayToKeyedTables.id

    static func needsMigration(fileURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return needsMigration(data: data)
    }

    static func needsMigration(data: Data) -> Bool {
        guard let string = String(data: data, encoding: .utf8) else { return false }
        return WorkspacesTOMLCodec.containsLegacyWorkspaceArray(string: string)
    }

    @discardableResult
    static func migrate(fileURL: URL) throws -> URL {
        let data = try Data(contentsOf: fileURL)
        guard needsMigration(data: data) else {
            throw SettingsMigrationError.migrationNotNeeded
        }

        let backupURL = try createTimestampedBackup(for: fileURL)
        let decoded = WorkspacesTOMLCodec.decode(
            data,
            defaults: BuiltInSettingsDefaults.workspaceConfigurations
        )
        let encoded = WorkspacesTOMLCodec.encode(decoded)
        try encoded.write(to: fileURL, options: .atomic)
        return backupURL
    }

    private static func createTimestampedBackup(for fileURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension
        let backupName = fileExtension.isEmpty
            ? "\(baseName)-\(stamp).backup"
            : "\(baseName)-\(stamp).\(fileExtension).backup"

        var backupURL = directory.appendingPathComponent(backupName, isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: backupURL.path) {
            let suffixedName = fileExtension.isEmpty
                ? "\(baseName)-\(stamp)-\(suffix).backup"
                : "\(baseName)-\(stamp)-\(suffix).\(fileExtension).backup"
            backupURL = directory.appendingPathComponent(suffixedName, isDirectory: false)
            suffix += 1
        }

        try fileManager.copyItem(at: fileURL, to: backupURL)
        return backupURL
    }
}

enum SettingsMigrationError: LocalizedError, Equatable {
    case migrationNotNeeded

    var errorDescription: String? {
        switch self {
        case .migrationNotNeeded:
            return "The config file does not use a migratable old format."
        }
    }
}
