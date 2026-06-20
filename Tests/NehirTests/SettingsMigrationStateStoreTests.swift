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
