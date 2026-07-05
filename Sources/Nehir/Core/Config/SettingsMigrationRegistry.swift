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

enum RevealPartialMigrationKeys {
    static let legacySection = "niri"
    static let legacyKey = "revealPartial"
    static let newKey = "revealStyle"

    static var legacyKeyPath: String {
        "\(legacySection).\(legacyKey)"
    }
}

enum OverrideModifierMigrationKeys {
    static let section = "gestures"
    static let legacyKey = "mouseResizeModifierKey"
    static let newKey = "overrideModifier"

    static var legacyKeyPath: String {
        "\(section).\(legacyKey)"
    }
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

    static let revealPartialToRevealStyle = SettingsMigrationDescriptor(
        id: "reveal-partial-to-reveal-style",
        title: "Update reveal setting",
        fileName: SettingsFilePersistence.fileName,
        oldFormatSummary: "[\(RevealPartialMigrationKeys.legacySection)].\(RevealPartialMigrationKeys.legacyKey)",
        newFormatSummary: "[\(RevealPartialMigrationKeys.legacySection)].\(RevealPartialMigrationKeys.newKey)",
        warningBody: "settings.toml uses the old revealPartial key. Nehir now uses revealStyle for placement and Viewport Scroll Lock for suppressing background automatic reveals.",
        enforcementWarning: "A future Nehir update may require the new key."
    )

    static let mouseResizeModifierToOverrideModifier = SettingsMigrationDescriptor(
        id: "mouse-resize-modifier-to-override-modifier",
        title: "Update mouse modifier setting",
        fileName: SettingsFilePersistence.fileName,
        oldFormatSummary: "[\(OverrideModifierMigrationKeys.section)].\(OverrideModifierMigrationKeys.legacyKey)",
        newFormatSummary: "[\(OverrideModifierMigrationKeys.section)].\(OverrideModifierMigrationKeys.newKey)",
        warningBody: "settings.toml uses the old mouseResizeModifierKey key. Nehir now uses overrideModifier for the Manual Override modifier.",
        enforcementWarning: "A future Nehir update may require the new key."
    )

    static let all: [SettingsMigrationDescriptor] = [
        workspacesArrayToKeyedTables,
        revealPartialToRevealStyle,
        mouseResizeModifierToOverrideModifier
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
        var migrations: [PendingSettingsMigration] = []

        let workspaceDescriptor = SettingsMigrationRegistry.workspacesArrayToKeyedTables
        let workspacesURL = configDirectory.appendingPathComponent(workspaceDescriptor.fileName, isDirectory: false)
        if WorkspacesConfigMigration.needsMigration(fileURL: workspacesURL) {
            migrations.append(PendingSettingsMigration(descriptor: workspaceDescriptor, fileURL: workspacesURL))
        }

        let revealDescriptor = SettingsMigrationRegistry.revealPartialToRevealStyle
        let settingsURL = configDirectory.appendingPathComponent(revealDescriptor.fileName, isDirectory: false)
        if RevealPartialSettingsMigration.needsMigration(fileURL: settingsURL) {
            migrations.append(PendingSettingsMigration(descriptor: revealDescriptor, fileURL: settingsURL))
        }

        let overrideModifierDescriptor = SettingsMigrationRegistry.mouseResizeModifierToOverrideModifier
        if MouseResizeModifierSettingsMigration.needsMigration(fileURL: settingsURL) {
            migrations.append(PendingSettingsMigration(descriptor: overrideModifierDescriptor, fileURL: settingsURL))
        }

        return migrations
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

        let backupURL = try createTimestampedSettingsMigrationBackup(for: fileURL)
        let decoded = WorkspacesTOMLCodec.decode(
            data,
            defaults: BuiltInSettingsDefaults.workspaceConfigurations
        )
        let encoded = WorkspacesTOMLCodec.encode(decoded)
        try encoded.write(to: fileURL, options: .atomic)
        return backupURL
    }
}

enum RevealPartialSettingsMigration {
    static let migrationID = SettingsMigrationRegistry.revealPartialToRevealStyle.id

    static func needsMigration(fileURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return needsMigration(data: data)
    }

    static func needsMigration(data: Data) -> Bool {
        guard let string = String(data: data, encoding: .utf8) else { return false }
        return settingsTOMLValue(
            for: RevealPartialMigrationKeys.legacyKey,
            in: string,
            section: RevealPartialMigrationKeys.legacySection
        ) != nil
    }

    @discardableResult
    static func migrate(fileURL: URL) throws -> URL {
        let data = try Data(contentsOf: fileURL)
        guard let string = String(data: data, encoding: .utf8), needsMigration(data: data) else {
            throw SettingsMigrationError.migrationNotNeeded
        }

        let backupURL = try createTimestampedSettingsMigrationBackup(for: fileURL)
        var export = try SettingsTOMLCodec.decode(data)

        if settingsTOMLValue(
            for: RevealPartialMigrationKeys.newKey,
            in: string,
            section: RevealPartialMigrationKeys.legacySection
        ) == nil,
            let oldValue = settingsTOMLValue(
                for: RevealPartialMigrationKeys.legacyKey,
                in: string,
                section: RevealPartialMigrationKeys.legacySection
            )
        {
            export.revealStyle = migratedRevealStyle(from: oldValue)
        }
        export.settingsTOMLUnknownFields[RevealPartialMigrationKeys.legacySection]?
            .removeValue(forKey: RevealPartialMigrationKeys.legacyKey)
        if export.settingsTOMLUnknownFields[RevealPartialMigrationKeys.legacySection]?.isEmpty == true {
            export.settingsTOMLUnknownFields.removeValue(forKey: RevealPartialMigrationKeys.legacySection)
        }

        let encoded = try SettingsTOMLCodec.encode(export)
        try encoded.write(to: fileURL, options: .atomic)
        return backupURL
    }

    private static func migratedRevealStyle(from revealPartial: String) -> String {
        switch revealPartial {
        case "snapClosest": RevealStyle.closest.rawValue
        case "snapCenter": RevealStyle.center.rawValue
        case "default",
             "off": RevealStyle.auto.rawValue
        default: RevealStyle.auto.rawValue
        }
    }
}

enum MouseResizeModifierSettingsMigration {
    static let migrationID = SettingsMigrationRegistry.mouseResizeModifierToOverrideModifier.id

    static func needsMigration(fileURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return needsMigration(data: data)
    }

    static func needsMigration(data: Data) -> Bool {
        guard let string = String(data: data, encoding: .utf8) else { return false }
        return settingsTOMLValue(
            for: OverrideModifierMigrationKeys.legacyKey,
            in: string,
            section: OverrideModifierMigrationKeys.section
        ) != nil
    }

    @discardableResult
    static func migrate(fileURL: URL) throws -> URL {
        let data = try Data(contentsOf: fileURL)
        guard let string = String(data: data, encoding: .utf8), needsMigration(data: data) else {
            throw SettingsMigrationError.migrationNotNeeded
        }

        let backupURL = try createTimestampedSettingsMigrationBackup(for: fileURL)
        var export = try SettingsTOMLCodec.decode(data)

        if settingsTOMLValue(
            for: OverrideModifierMigrationKeys.newKey,
            in: string,
            section: OverrideModifierMigrationKeys.section
        ) == nil,
            let oldValue = settingsTOMLValue(
                for: OverrideModifierMigrationKeys.legacyKey,
                in: string,
                section: OverrideModifierMigrationKeys.section
            )
        {
            export.overrideModifier = oldValue
        }
        export.settingsTOMLUnknownFields[OverrideModifierMigrationKeys.section]?
            .removeValue(forKey: OverrideModifierMigrationKeys.legacyKey)
        if export.settingsTOMLUnknownFields[OverrideModifierMigrationKeys.section]?.isEmpty == true {
            export.settingsTOMLUnknownFields.removeValue(forKey: OverrideModifierMigrationKeys.section)
        }

        let encoded = try SettingsTOMLCodec.encode(export)
        try encoded.write(to: fileURL, options: .atomic)
        return backupURL
    }
}

private func settingsTOMLValue(for key: String, in toml: String, section: String) -> String? {
    var isInTargetSection = false
    for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { continue }
        if line.hasPrefix("[") {
            isInTargetSection = line == "[\(section)]"
            continue
        }
        guard isInTargetSection,
              line.hasPrefix(key),
              let equalsIndex = line.firstIndex(of: "=")
        else { continue }

        let lhs = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard lhs == key else { continue }
        let rhs = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return unquotedString(rhs)
    }
    return nil
}

private func stripComment(_ line: String) -> String {
    var result = ""
    var quote: Character?
    var isEscaped = false
    for character in line {
        if character == "\\", quote == "\"" {
            result.append(character)
            isEscaped.toggle()
            continue
        }
        if (character == "\"" || character == "'"), !isEscaped {
            quote = quote == character ? nil : (quote ?? character)
        }
        if character == "#", quote == nil {
            break
        }
        result.append(character)
        isEscaped = false
    }
    return result
}

private func unquotedString(_ value: String) -> String? {
    guard value.count >= 2,
          let first = value.first,
          (first == "\"" || first == "'"),
          value.last == first
    else { return nil }
    return String(value.dropFirst().dropLast())
}

private func createTimestampedSettingsMigrationBackup(for fileURL: URL) throws -> URL {
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

enum SettingsMigrationError: LocalizedError, Equatable {
    case migrationNotNeeded

    var errorDescription: String? {
        switch self {
        case .migrationNotNeeded:
            return "The config file does not use a migratable old format."
        }
    }
}
