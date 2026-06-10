import Foundation
@testable import Nehir
import Testing

private func makeSettingsWorkflowTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nehir-settings-workflow-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func makeSettingsWorkflowTestStore(directory: URL) -> SettingsStore {
    SettingsStore(
        persistence: SettingsFilePersistence(
            directory: directory,
            startWatching: false,
            deferSaves: false
        ),
        runtimeState: RuntimeStateStore(
            directory: directory,
            deferSaves: false
        )
    )
}

@Suite(.serialized) @MainActor struct SettingsViewTests {
    @Test func settingsFileStatusMessagesMatchWorkflowCopy() {
        #expect(SettingsFileStatus.revealedConfigFolder.message == "Config folder revealed in Finder")
        #expect(SettingsFileStatus.openedSettingsFile.message == "settings.toml opened")
    }

    @Test func settingsSidebarGroupsCoverEverySectionOnce() {
        let groupedSections = SettingsSectionGroup.allCases.flatMap(\.sections)

        #expect(Set(groupedSections) == Set(SettingsSection.allCases))
        #expect(Set(groupedSections).count == groupedSections.count)
    }

    @Test func revealActionCreatesSplitConfigAndReportsRevealed() throws {
        let directory = makeSettingsWorkflowTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsWorkflowTestStore(directory: directory)
        let tomlURL = directory.appendingPathComponent("settings.toml", isDirectory: false)
        try? FileManager.default.removeItem(at: tomlURL)
        var revealedURLs: [[URL]] = []

        let status = try SettingsFileWorkflow.perform(
            .revealConfigFolder,
            settings: settings,
            revealFile: { revealedURLs.append($0) }
        )

        #expect(status == .revealedConfigFolder)
        #expect(FileManager.default.fileExists(atPath: tomlURL.path) == true)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == [
            "settings.toml",
            "hotkeys.toml",
            "workspaces.toml",
            "apprules.d",
            "monitors.d"
        ])
        #expect(revealedURLs == [[directory]])
    }

    @Test func openActionUsesCanonicalTomlWithInjectedOpenHandler() throws {
        let directory = makeSettingsWorkflowTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsWorkflowTestStore(directory: directory)
        let tomlURL = directory.appendingPathComponent("settings.toml", isDirectory: false)
        try? FileManager.default.removeItem(at: tomlURL)
        var openedURLs: [URL] = []

        let status = try SettingsFileWorkflow.perform(
            .openMainSettingsFile,
            settings: settings,
            openFile: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(status == .openedSettingsFile)
        #expect(FileManager.default.fileExists(atPath: tomlURL.path) == true)
        #expect(openedURLs == [tomlURL])
    }

    @Test func openActionDoesNotRewriteExistingToml() throws {
        let directory = makeSettingsWorkflowTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsWorkflowTestStore(directory: directory)
        let tomlURL = directory.appendingPathComponent("settings.toml", isDirectory: false)
        let existingContents = """
        # Preserve user edits, comments, and even temporarily invalid TOML.
        not valid while user is editing =
        """
        try existingContents.write(to: tomlURL, atomically: true, encoding: .utf8)

        let status = try SettingsFileWorkflow.perform(
            .openMainSettingsFile,
            settings: settings,
            openFile: { _ in true }
        )

        #expect(status == .openedSettingsFile)
        #expect(try String(contentsOf: tomlURL, encoding: .utf8) == existingContents)
    }

    @Test func revealActionDoesNotRewriteExistingToml() throws {
        let directory = makeSettingsWorkflowTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsWorkflowTestStore(directory: directory)
        let tomlURL = directory.appendingPathComponent("settings.toml", isDirectory: false)
        let existingContents = "# user comment\n[general]\n"
        try existingContents.write(to: tomlURL, atomically: true, encoding: .utf8)

        let status = try SettingsFileWorkflow.perform(
            .revealConfigFolder,
            settings: settings,
            revealFile: { _ in }
        )

        #expect(status == .revealedConfigFolder)
        #expect(try String(contentsOf: tomlURL, encoding: .utf8) == existingContents)
    }
}
