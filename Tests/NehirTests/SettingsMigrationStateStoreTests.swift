// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
import Testing

@Suite struct SettingsMigrationStateStoreTests {
    @Test func postponeAppliesOnlyToSameVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-migration-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SettingsMigrationStateStore(directory: directory)
        try store.postpone(migrationID: "workspaces-array-to-keyed-tables", currentAppVersion: "1.2.3")

        #expect(store.isPostponed(migrationID: "workspaces-array-to-keyed-tables", currentAppVersion: "1.2.3"))
        #expect(store.isPostponed(migrationID: "workspaces-array-to-keyed-tables", currentAppVersion: "1.2.4") == false)

        let reloaded = SettingsMigrationStateStore(directory: directory)
        #expect(reloaded.isPostponed(migrationID: "workspaces-array-to-keyed-tables", currentAppVersion: "1.2.3"))
    }

    @Test func revealPartialMigrationRewritesSettingsToml() throws {
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-reveal-migration-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }

        let settingsURL = configDirectory.appendingPathComponent("settings.toml")
        try """
        [niri]
        revealPartial = "snapCenter"
        balancedColumnCount = 2
        infiniteLoop = false
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        let migrations = SettingsMigrationDetector.applicableMigrations(configDirectory: configDirectory)
        #expect(migrations.map(\.id).contains(SettingsMigrationRegistry.revealPartialToRevealStyle.id))

        let backupURL = try RevealPartialSettingsMigration.migrate(fileURL: settingsURL)
        let migrated = try String(contentsOf: settingsURL, encoding: .utf8)
        let backup = try String(contentsOf: backupURL, encoding: .utf8)
        let decoded = try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL))

        #expect(backup.contains("revealPartial = \"snapCenter\""))
        #expect(migrated.contains("revealStyle = \"center\""))
        #expect(!migrated.contains("revealPartial"))
        #expect(decoded.revealStyle == RevealStyle.center.rawValue)
        #expect(decoded.settingsTOMLUnknownFields["niri"]?["revealPartial"] == nil)
    }

    @Test func revealPartialDiagnosticsShowsMigrationInsteadOfUnknownKey() throws {
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-reveal-migration-config-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-reveal-migration-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: configDirectory)
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        let settingsURL = configDirectory.appendingPathComponent("settings.toml")
        try """
        [niri]
        revealPartial = "snapClosest"
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        let issues = SettingsDiagnosticsDetector.pendingIssues(
            configDirectory: configDirectory,
            stateStore: SettingsMigrationStateStore(directory: stateDirectory),
            appVersion: "1.2.3"
        )

        #expect(issues.contains { issue in
            guard case .softMigration(let migration) = issue else { return false }
            return migration.id == SettingsMigrationRegistry.revealPartialToRevealStyle.id
        })
        #expect(!issues.contains { issue in
            guard case .unknownKeys(let unknown) = issue else { return false }
            return unknown.keyPaths.contains("niri.revealPartial")
        })
    }

    @Test func revealPartialMigrationPreservesExplicitRevealStyleWhenBothKeysExist() throws {
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-reveal-migration-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }

        let settingsURL = configDirectory.appendingPathComponent("settings.toml")
        try """
        [niri]
        revealPartial = "snapCenter"
        revealStyle = "closest"
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        _ = try RevealPartialSettingsMigration.migrate(fileURL: settingsURL)
        let migrated = try String(contentsOf: settingsURL, encoding: .utf8)
        let decoded = try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL))

        #expect(migrated.contains("revealStyle = \"closest\""))
        #expect(!migrated.contains("revealPartial"))
        #expect(decoded.revealStyle == RevealStyle.closest.rawValue)
    }

    @Test func mouseResizeModifierMigrationNeedsMigrationDetectsLegacyKey() throws {
        #expect(MouseResizeModifierSettingsMigration.needsMigration(data: Data("""
        [gestures]
        mouseResizeModifierKey = "command"
        """.utf8)))
        #expect(!MouseResizeModifierSettingsMigration.needsMigration(data: Data("""
        [gestures]
        overrideModifier = "command"
        """.utf8)))
        #expect(!MouseResizeModifierSettingsMigration.needsMigration(data: Data("""
        [niri]
        revealPartial = "snapCenter"
        """.utf8)))
    }

    @Test func mouseResizeModifierMigrationRewritesToNewKey() throws {
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-override-migration-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }

        let settingsURL = configDirectory.appendingPathComponent("settings.toml")
        try """
        [gestures]
        mouseResizeModifierKey = "controlOption"
        scrollEnabled = true
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        let migrations = SettingsMigrationDetector.applicableMigrations(configDirectory: configDirectory)
        #expect(migrations.map(\.id).contains(SettingsMigrationRegistry.mouseResizeModifierToOverrideModifier.id))

        let backupURL = try MouseResizeModifierSettingsMigration.migrate(fileURL: settingsURL)
        let migrated = try String(contentsOf: settingsURL, encoding: .utf8)
        let backup = try String(contentsOf: backupURL, encoding: .utf8)
        let decoded = try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL))

        #expect(backup.contains("mouseResizeModifierKey = \"controlOption\""))
        #expect(migrated.contains("overrideModifier = \"controlOption\""))
        #expect(!migrated.contains("mouseResizeModifierKey"))
        #expect(decoded.overrideModifier == OverrideModifierKey.controlOption.rawValue)
        #expect(decoded.settingsTOMLUnknownFields["gestures"]?["mouseResizeModifierKey"] == nil)
    }

    @Test func mouseResizeModifierMigrationPreservesExplicitOverrideModifierWhenBothKeysExist() throws {
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-override-migration-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }

        let settingsURL = configDirectory.appendingPathComponent("settings.toml")
        try """
        [gestures]
        mouseResizeModifierKey = "command"
        overrideModifier = "controlOption"
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        _ = try MouseResizeModifierSettingsMigration.migrate(fileURL: settingsURL)
        let migrated = try String(contentsOf: settingsURL, encoding: .utf8)
        let decoded = try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL))

        #expect(migrated.contains("overrideModifier = \"controlOption\""))
        #expect(!migrated.contains("mouseResizeModifierKey"))
        #expect(decoded.overrideModifier == OverrideModifierKey.controlOption.rawValue)
    }

    @Test func migrationRegistryIncludesOverrideModifierEntry() {
        #expect(SettingsMigrationRegistry.all.contains(SettingsMigrationRegistry.mouseResizeModifierToOverrideModifier))
    }

    @Test func detectorSuppressesOnlyPostponedCurrentVersion() throws {
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-migration-config-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-migration-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: configDirectory)
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        let workspacesURL = configDirectory.appendingPathComponent("workspaces.toml")
        try """
        [[workspace]]
        name = "1"
        monitor = "main"
        """.write(to: workspacesURL, atomically: true, encoding: .utf8)

        let store = SettingsMigrationStateStore(directory: stateDirectory)
        #expect(SettingsMigrationDetector.pendingMigrations(
            configDirectory: configDirectory,
            stateStore: store,
            appVersion: "1.2.3"
        ).count == 1)

        try store.postpone(migrationID: "workspaces-array-to-keyed-tables", currentAppVersion: "1.2.3")
        #expect(SettingsMigrationDetector.pendingMigrations(
            configDirectory: configDirectory,
            stateStore: store,
            appVersion: "1.2.3"
        ).isEmpty)
        #expect(SettingsMigrationDetector.applicableMigrations(configDirectory: configDirectory).count == 1)
        #expect(SettingsMigrationDetector.pendingMigrations(
            configDirectory: configDirectory,
            stateStore: store,
            appVersion: "1.2.4"
        ).count == 1)
    }
}
