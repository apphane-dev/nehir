import Foundation
@testable import Nehir
import Testing

private enum TOMLMutationError: Error {
    case noMatch(String)
    case residualMatch(String)
}

private extension String {
    func replacingRegex(
        _ pattern: String,
        with replacement: String = "",
        options: NSRegularExpression.Options = [.anchorsMatchLines]
    ) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(startIndex..., in: self)
        guard regex.numberOfMatches(in: self, range: range) > 0 else {
            throw TOMLMutationError.noMatch(pattern)
        }
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: replacement)
    }

    func removingKey(_ key: String) throws -> String {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        return try replacingRegex("^\\s*\(escaped)\\s*=.*\\n")
    }
}

@Suite struct SettingsTOMLCodecTests {
    @Test func roundTripsMainSettingsDefaults() throws {
        let original = SettingsExport.defaults()
        let data = try SettingsTOMLCodec.encode(original)
        let decoded = try SettingsTOMLCodec.decode(data)

        #expect(decoded == original)
    }

    @Test func mainSettingsUsesDefaultsForMissingKeys() throws {
        let data = try SettingsTOMLCodec.encode(SettingsExport.defaults())
        let output = try #require(String(data: data, encoding: .utf8))
        let edited = try output.removingKey("ipcEnabled")

        let decoded = try SettingsTOMLCodec.decode(Data(edited.utf8))
        #expect(decoded.ipcEnabled == SettingsExport.defaults().ipcEnabled)
    }

    @Test func mainSettingsRejectInvalidPresentValues() throws {
        let data = try SettingsTOMLCodec.encode(SettingsExport.defaults())
        let output = try #require(String(data: data, encoding: .utf8))
        let invalidType = try output.replacingRegex(
            "^hotkeysEnabled = true$",
            with: "hotkeysEnabled = \"true\""
        )

        #expect(throws: (any Error).self) {
            _ = try SettingsTOMLCodec.decode(Data(invalidType.utf8))
        }
    }

    @Test func splitConfigStateIsExcludedFromMainSettingsTOML() throws {
        var export = SettingsExport.defaults()
        export.hotkeyBindings = [try #require(export.hotkeyBindings.first)]
        export.appRules = [AppRule(bundleId: "com.example.app", layout: .float)]
        export.workspaceConfigurations = [WorkspaceConfiguration(name: "10", monitorAssignment: .secondary)]
        export.monitorBarSettings = [MonitorBarSettings(monitorName: "Display", enabled: false)]
        export.monitorOrientationSettings = [MonitorOrientationSettings(monitorName: "Display", orientation: .vertical)]
        export.monitorNiriSettings = [MonitorNiriSettings(monitorName: "Display", balancedColumnCount: 4)]

        let output = try #require(String(data: SettingsTOMLCodec.encode(export), encoding: .utf8))

        #expect(output.contains("[[hotkeys]]") == false)
        #expect(output.contains("[[appRules]]") == false)
        #expect(output.contains("[[workspaces]]") == false)
        #expect(output.contains("monitorBarOverrides") == false)
        #expect(output.contains("monitorOrientationOverrides") == false)
        #expect(output.contains("monitorNiriOverrides") == false)
        #expect(output.contains("modifierTrigger") == false)
    }

    @Test func runtimeStateIsExcludedFromMainSettingsTOML() throws {
        let output = try #require(String(data: SettingsTOMLCodec.encode(SettingsExport.defaults()), encoding: .utf8))

        #expect(output.contains("commandPaletteLastMode") == false)
        #expect(output.contains("useCustomFrame") == false)
        #expect(output.contains("customFrame") == false)
    }

    @Test func unknownNiriKeysAreIgnoredAndNotReencoded() throws {
        var export = SettingsExport.defaults()
        export.niriBalancedColumnCount = 4

        let output = try #require(String(data: SettingsTOMLCodec.encode(export), encoding: .utf8))
        let unknownKey = "maxWindows" + "PerColumn"
        let edited = output.replacingOccurrences(
            of: "balancedColumnCount = 4",
            with: "balancedColumnCount = 4\n\(unknownKey) = 7"
        )

        let decoded = try SettingsTOMLCodec.decode(Data(edited.utf8))
        #expect(decoded == export)

        let reencoded = try #require(String(data: SettingsTOMLCodec.encode(decoded), encoding: .utf8))
        #expect(reencoded.contains(unknownKey) == false)
    }

    @Test func roundTripsNestedColorQuartets() throws {
        var export = SettingsExport.defaults()
        export.borderColorRed = 0.1
        export.borderColorGreen = 0.2
        export.borderColorBlue = 0.3
        export.borderColorAlpha = 0.4
        export.workspaceBarAccentColor = SettingsColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 1)
        export.workspaceBarTextColor = SettingsColor(red: 0.9, green: 1.0, blue: 0.0, alpha: 1)

        let data = try SettingsTOMLCodec.encode(export)
        let output = try #require(String(data: data, encoding: .utf8))
        #expect(output.contains("[workspaceBar.accentColor]"))
        #expect(output.contains("[workspaceBar.textColor]"))

        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.borderColorRed == export.borderColorRed)
        #expect(decoded.borderColorGreen == export.borderColorGreen)
        #expect(decoded.borderColorBlue == export.borderColorBlue)
        #expect(decoded.borderColorAlpha == export.borderColorAlpha)
        #expect(decoded.workspaceBarAccentColor == export.workspaceBarAccentColor)
        #expect(decoded.workspaceBarTextColor == export.workspaceBarTextColor)
    }

    @Test func roundTripsOuterGaps() throws {
        var export = SettingsExport.defaults()
        export.outerGapLeft = 12
        export.outerGapRight = 14
        export.outerGapTop = 16
        export.outerGapBottom = 18

        let decoded = try SettingsTOMLCodec.decode(try SettingsTOMLCodec.encode(export))
        #expect(decoded.outerGapLeft == 12)
        #expect(decoded.outerGapRight == 14)
        #expect(decoded.outerGapTop == 16)
        #expect(decoded.outerGapBottom == 18)
    }

    @Test func preservesNilColumnWidthPresetsDistinctFromEmptyArray() throws {
        var exportWithNil = SettingsExport.defaults()
        exportWithNil.niriColumnWidthPresets = nil
        let decodedNil = try SettingsTOMLCodec.decode(try SettingsTOMLCodec.encode(exportWithNil))
        #expect(decodedNil.niriColumnWidthPresets == nil)

        var exportEmpty = SettingsExport.defaults()
        exportEmpty.niriColumnWidthPresets = []
        let decodedEmpty = try SettingsTOMLCodec.decode(try SettingsTOMLCodec.encode(exportEmpty))
        #expect(decodedEmpty.niriColumnWidthPresets == [])
    }

    @Test func canonicalDefaultsMatchGoldenFixture() throws {
        let bundle = Bundle.module
        guard let fixtureURL = bundle.url(forResource: "canonical-settings", withExtension: "toml") else {
            Issue.record("Golden fixture canonical-settings.toml is missing from test resources")
            return
        }

        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        let actual = try #require(String(data: SettingsTOMLCodec.encode(SettingsExport.defaults()), encoding: .utf8))

        if expected != actual {
            let diffURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("canonical-settings.actual.toml")
            try? actual.write(to: diffURL, atomically: true, encoding: .utf8)
            let message = "Canonical TOML output drifted from fixture. Expected length \(expected.count), got \(actual.count). Actual written to \(diffURL.path) for inspection."
            Issue.record(Comment(rawValue: message))
        }
    }
}
