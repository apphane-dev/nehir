import Foundation
@testable import Nehir
import Testing

@Suite struct ConfigMismatchDetectorTests {
    @Test func detectsUnknownTopLevelKey() throws {
        let base = try #require(String(data: SettingsTOMLCodec.encode(SettingsExport.defaults()), encoding: .utf8))
        let url = try writeSettings("removedTopLevel = true\n\n" + base)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(detectConfigMismatches(in: url).contains("removedTopLevel"))
    }

    @Test func detectsUnknownNestedKeyByPath() throws {
        let base = try #require(String(data: SettingsTOMLCodec.encode(SettingsExport.defaults()), encoding: .utf8))
        let url = try writeSettings(base + "\nwidth = 7\n")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(detectConfigMismatches(in: url).contains("workspaceBar.width"))
    }

    @Test func parseFailureReturnsEmptyMismatches() throws {
        let url = try writeSettings("[broken\n")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(detectConfigMismatches(in: url) == [])
    }

    private func writeSettings(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).toml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
