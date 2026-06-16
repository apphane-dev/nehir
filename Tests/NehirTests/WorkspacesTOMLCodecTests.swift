import Foundation
@testable import Nehir
import Testing

@Suite struct WorkspacesTOMLCodecTests {
    @Test func encodesKeyedWorkspaceTables() throws {
        let data = WorkspacesTOMLCodec.encode([
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "6", displayName: "❤️", monitorAssignment: .secondary)
        ])
        let output = try #require(String(data: data, encoding: .utf8))

        #expect(output.contains("[[workspace]]") == false)
        #expect(output.contains("[1]\nmonitor = \"main\""))
        #expect(output.contains("[6]\ndisplayName = \"❤️\"\nmonitor = \"secondary\""))
    }

    @Test func decodesKeyedWorkspaceTables() {
        let decoded = WorkspacesTOMLCodec.decode(string: """
        [1]
        monitor = "main"

        [6]
        displayName = "❤️"
        monitor = "secondary"
        """)

        #expect(decoded == [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "6", displayName: "❤️", monitorAssignment: .secondary)
        ])
    }

    @Test func decodesLegacyWorkspaceArrays() {
        let decoded = WorkspacesTOMLCodec.decode(string: """
        [[workspace]]
        name = "1"
        monitor = "main"

        [[workspace]]
        name = "6"
        displayName = "❤️"
        monitor = "secondary"
        """)

        #expect(decoded == [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "6", displayName: "❤️", monitorAssignment: .secondary)
        ])
    }

    @Test func detectsLegacyWorkspaceArray() {
        #expect(WorkspacesTOMLCodec.containsLegacyWorkspaceArray(string: """
        # comment mentioning [[workspace]] should not count
        [1]
        monitor = "main"
        """) == false)

        #expect(WorkspacesTOMLCodec.containsLegacyWorkspaceArray(string: """
        [[workspace]]
        name = "1"
        """) == true)
    }

    @MainActor
    @Test func unrelatedSettingsSavePreservesLegacyWorkspaceFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-workspaces-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        let defaults = SettingsExport.defaults()
        try persistence.saveImmediately(defaults)

        let workspacesURL = directory.appendingPathComponent("workspaces.toml")
        try """
        [[workspace]]
        name = "1"
        monitor = "main"
        """.write(to: workspacesURL, atomically: true, encoding: .utf8)

        var loaded = persistence.load()
        loaded.gapSize += 1
        try persistence.saveImmediately(loaded)

        let preserved = try String(contentsOf: workspacesURL, encoding: .utf8)
        #expect(preserved.contains("[[workspace]]"))
    }

    @Test func migrationBacksUpAndRewritesToKeyedTables() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nehir-workspaces-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("workspaces.toml")
        try """
        [[workspace]]
        name = "1"
        monitor = "main"

        [[workspace]]
        name = "6"
        displayName = "❤️"
        monitor = "secondary"
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let backupURL = try WorkspacesConfigMigration.migrate(fileURL: fileURL)
        let migrated = try String(contentsOf: fileURL, encoding: .utf8)
        let backup = try String(contentsOf: backupURL, encoding: .utf8)

        #expect(backup.contains("[[workspace]]"))
        #expect(migrated.contains("[[workspace]]") == false)
        #expect(migrated.contains("[1]\nmonitor = \"main\""))
        #expect(migrated.contains("[6]\ndisplayName = \"❤️\"\nmonitor = \"secondary\""))
    }
}
