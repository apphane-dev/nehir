// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
import Testing

@Suite struct AppRulePersistenceContractTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func bundlelessRuleRoundTripsThroughExclusiveNewFileWrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000197")!
        let unsafeName = "../../\(String(repeating: "very unsafe ", count: 20))"
        let rule = AppRule(id: id, appNameSubstring: unsafeName, layout: .float)

        try AppRuleFileStore.write([rule], to: directory, previousRuleIDs: [])

        let filename = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path)
            .first { $0.hasSuffix(".toml") })
        #expect(filename.contains(id.uuidString.lowercased()))
        #expect(!filename.contains("/") && !filename.contains(".."))
        #expect(filename.count < 100)
        #expect(filename.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
        #expect(AppRuleFileStore.read(from: directory) == [rule])
        #expect(!AppRuleFileStore.encode(rule).contains("bundleId"))
    }

    @Test func omittedBundleIsValidButMalformedPresentBundleIsRejected() throws {
        #expect(AppRuleFileStore.decode("[match]\nappName = \"QEMU\"\n")?.bundleId == nil)
        #expect(AppRuleFileStore.decode("[match]\nbundleId = \"\"\nappName = \"QEMU\"\n") == nil)
        #expect(AppRuleFileStore.decode("[match]\nbundleId = QEMU\nappName = \"QEMU\"\n") == nil)

        let malformed = AppRule(bundleId: "   ", appNameSubstring: "QEMU")
        #expect(throws: AppRuleFileStore.WriteError.malformedBundleID(malformed.id)) {
            try AppRuleFileStore.write([malformed], to: temporaryDirectory(), previousRuleIDs: [])
        }
    }

    @Test func existingArbitraryFilenameSurvivesSelectorEdit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000198")!
        let source = directory.appendingPathComponent("my-custom-rule.toml")
        try "id = \"\(id.uuidString)\"\n\n[match]\nbundleId = \"legacy.literal\"\n"
            .write(to: source, atomically: true, encoding: .utf8)
        var rule = try #require(AppRuleFileStore.read(from: directory).first)
        rule.appNameSubstring = "Refined Name"

        try AppRuleFileStore.write([rule], to: directory, previousRuleIDs: [id])

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: source, encoding: .utf8).contains("appName = \"Refined Name\""))
    }

    @Test func explicitDeletionPreservesOpaqueFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppRule(bundleId: "com.example.first")
        let second = AppRule(bundleId: "com.example.second")
        try AppRuleFileStore.write([first, second], to: directory, previousRuleIDs: [])
        let opaque = directory.appendingPathComponent("notes.toml")
        try "not valid TOML".write(to: opaque, atomically: true, encoding: .utf8)

        try AppRuleFileStore.write([first], to: directory, previousRuleIDs: [first.id, second.id])

        #expect(AppRuleFileStore.read(from: directory) == [first])
        #expect(try String(contentsOf: opaque, encoding: .utf8) == "not valid TOML")
    }

    @Test func missingExpectedSourceFailsClosed() {
        let rule = AppRule(bundleId: "com.example.missing")
        #expect(throws: AppRuleFileStore.WriteError.missingExpectedSource(rule.id)) {
            try AppRuleFileStore.write([rule], to: temporaryDirectory(), previousRuleIDs: [rule.id])
        }
    }

    @Test func collidingBundledFilenameFailsWithoutChangingPersistedRule() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppRule(bundleId: "com.example.shared", axRole: "AXWindow")
        let second = AppRule(bundleId: "com.example.shared", axSubrole: "AXDialog")
        try AppRuleFileStore.write([first], to: directory, previousRuleIDs: [])
        let source = directory.appendingPathComponent("com-example-shared.toml")
        let original = try Data(contentsOf: source)

        #expect(throws: AppRuleFileStore.WriteError.duplicateOutputFilename("com-example-shared.toml")) {
            try AppRuleFileStore.write([first, second], to: directory, previousRuleIDs: [first.id])
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(AppRuleFileStore.read(from: directory) == [first])
    }
}
