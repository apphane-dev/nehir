// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Carbon
import Foundation
@testable import Nehir
import Testing

@Suite struct HotkeyConflictDiagnosticsTests {
    // MARK: - Prong 1: live registration failures

    @Test func hotkeyConflictIssueProducedForSystemReservedFailure() {
        let failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [
            .openCommandPalette: .systemReserved
        ]
        let issues = SettingsDiagnosticsDetector.applicableIssues(
            hotkeyFailures: failures,
            hotkeyBindings: HotkeyBindingRegistry.defaults()
        )
        let conflicts = issues.compactMap { issue -> HotkeyConflictIssue? in
            if case .hotkeyConflict(let conflict) = issue { return conflict }
            return nil
        }

        #expect(conflicts.count == 1)
        let conflict = conflicts[0]
        #expect(conflict.command == .openCommandPalette)
        #expect(conflict.reason == .systemReserved)
        #expect(conflict.actionID == "openCommandPalette")
        #expect(conflict.remediation.contains("Another app registered"))
        #expect(conflict.commandDisplayName == ActionCatalog.title(for: .openCommandPalette))
    }

    @Test func hotkeyConflictIssuesProducedForDuplicateBindingFailures() {
        let failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [
            .move(.left): .duplicateBinding,
            .move(.right): .duplicateBinding
        ]
        let issues = SettingsDiagnosticsDetector.applicableIssues(
            hotkeyFailures: failures,
            hotkeyBindings: HotkeyBindingRegistry.defaults()
        )
        let conflicts = issues.compactMap { issue -> HotkeyConflictIssue? in
            if case .hotkeyConflict(let conflict) = issue { return conflict }
            return nil
        }

        #expect(conflicts.count == 2)
        #expect(Set(conflicts.map(\.command)) == [.move(.left), .move(.right)])
        #expect(conflicts.allSatisfy { $0.reason == .duplicateBinding })
        #expect(conflicts.allSatisfy { $0.remediation.contains("unique chord") })
    }

    @Test func emptyFailureMapYieldsNoHotkeyConflictIssue() {
        let issues = SettingsDiagnosticsDetector.applicableIssues(
            hotkeyFailures: [:],
            hotkeyBindings: HotkeyBindingRegistry.defaults()
        )

        #expect(issues.allSatisfy { issue in
            if case .hotkeyConflict = issue { return false }
            return true
        })
    }

    @Test func conflictIssueCarriesCurrentChordDisplayFromBindings() {
        // A failing command absent from the bindings list falls back to a non-empty
        // placeholder chord string instead of crashing.
        let failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [
            .toggleFullscreen: .systemReserved
        ]
        let issues = SettingsDiagnosticsDetector.applicableIssues(
            hotkeyFailures: failures,
            hotkeyBindings: []
        )
        let conflict = issues.compactMap { issue -> HotkeyConflictIssue? in
            if case .hotkeyConflict(let conflict) = issue { return conflict }
            return nil
        }.first

        #expect(conflict != nil)
        #expect(conflict?.chordDisplayString.isEmpty == false)
    }

    // MARK: - Prong 2: curated default-chord advisory

    @Test func curatedAdvisoryFiresForCommandPaletteDefaultChord() throws {
        let issues = SettingsDiagnosticsDetector.applicableIssues(
            hotkeyFailures: [:],
            hotkeyBindings: HotkeyBindingRegistry.defaults()
        )
        let advisories = issues.compactMap { issue -> HotkeyAdvisoryIssue? in
            if case .hotkeyAdvisory(let advisory) = issue { return advisory }
            return nil
        }

        #expect(advisories.count == 1)
        let advisory = try #require(advisories.first)
        #expect(advisory.command == .openCommandPalette)
        #expect(advisory.actionID == "openCommandPalette")
        #expect(advisory.advisoryText.contains("Command Palette"))
        #expect(advisory.chordDisplayString.isEmpty == false)
    }

    @Test func curatedAdvisoryDisappearsAfterReassign() {
        // Reassign the command palette chord away from its default; the advisory must
        // not fire on a custom chord (no false positives).
        let reassigned = HotkeyBindingRegistry.defaults().map { binding in
            guard binding.id == "openCommandPalette" else { return binding }
            return HotkeyBinding(
                id: binding.id,
                command: binding.command,
                binding: KeyBinding(keyCode: 123, modifiers: UInt32(cmdKey))
            )
        }
        let issues = SettingsDiagnosticsDetector.applicableIssues(
            hotkeyFailures: [:],
            hotkeyBindings: reassigned
        )

        #expect(issues.allSatisfy { issue in
            if case .hotkeyAdvisory = issue { return false }
            return true
        })
    }

    @Test func curatedAdvisorySuppressedWhenBindingUnassigned() {
        let unassigned = HotkeyBindingRegistry.defaults().map { binding in
            guard binding.id == "openCommandPalette" else { return binding }
            return HotkeyBinding(id: binding.id, command: binding.command, binding: .unassigned)
        }
        let issues = SettingsDiagnosticsDetector.applicableIssues(
            hotkeyFailures: [:],
            hotkeyBindings: unassigned
        )

        #expect(issues.allSatisfy { issue in
            if case .hotkeyAdvisory = issue { return false }
            return true
        })
    }

    // MARK: - Regression guard for the unified-diagnostics policy

    @Test func applicableIssuesPreservesExistingConfigIssuesUnchanged() throws {
        let configDirectory = makeIsolatedConfigDirectory()
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }

        // Empty hotkey inputs must produce exactly the same config-only issues as before.
        let withoutHotkeyData = SettingsDiagnosticsDetector.applicableIssues(configDirectory: configDirectory)
        let withEmptyHotkeyData = SettingsDiagnosticsDetector.applicableIssues(
            configDirectory: configDirectory,
            hotkeyFailures: [:],
            hotkeyBindings: []
        )
        #expect(withoutHotkeyData == withEmptyHotkeyData)
    }

    @Test func unknownKeysAndHotkeyConflictsCoexistAdditively() throws {
        let configDirectory = makeIsolatedConfigDirectory()
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }

        let settingsURL = configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        try #"completelyUnknownDiagnosticKey = true"#.write(to: settingsURL, atomically: true, encoding: .utf8)

        let issues = SettingsDiagnosticsDetector.applicableIssues(
            configDirectory: configDirectory,
            hotkeyFailures: [.openCommandPalette: .systemReserved],
            hotkeyBindings: HotkeyBindingRegistry.defaults()
        )

        // Existing unknown-keys detection is preserved alongside the new hotkey rows.
        #expect(issues.contains { if case .unknownKeys = $0 { return true }
            return false
        })
        #expect(issues.contains { if case .hotkeyConflict = $0 { return true }
            return false
        })
        #expect(issues.contains { if case .hotkeyAdvisory = $0 { return true }
            return false
        })
    }

    // MARK: - Badge / pending count

    @Test func pendingIssuesCountIncreasesWhenHotkeyConflictPresent() {
        let baseCount = SettingsDiagnosticsDetector.pendingIssues().count
        let withConflict = SettingsDiagnosticsDetector.pendingIssues(
            hotkeyFailures: [.openCommandPalette: .systemReserved, .toggleFullscreen: .duplicateBinding],
            hotkeyBindings: HotkeyBindingRegistry.defaults()
        ).count

        // Two conflicts plus the curated command-palette advisory all flow through the
        // pending-issue path that drives the sidebar badge.
        #expect(withConflict > baseCount)
        #expect(withConflict - baseCount == 3)
    }

    @Test func hotkeyIssuesAreNotPostponableAndAlwaysRemainPending() {
        let conflict = HotkeyConflictIssue(
            actionID: "openCommandPalette",
            command: .openCommandPalette,
            chordDisplayString: "⌥⌘Space",
            reason: .systemReserved
        )
        let advisory = HotkeyAdvisoryIssue(
            actionID: "openCommandPalette",
            command: .openCommandPalette,
            chordDisplayString: "⌥⌘Space",
            advisoryText: "advisory"
        )
        // Hotkey issues share a single non-postponable id sentinel, so they cannot be
        // hidden by the postponement filter the way migrations can.
        #expect(SettingsDiagnosticsDetector.postponeID(for: .hotkeyConflict(conflict))
            == SettingsDiagnosticsDetector.postponeID(for: .hotkeyAdvisory(advisory)))
    }

    // MARK: - Helpers

    private func makeIsolatedConfigDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nehir-hotkey-diagnostics-\(UUID().uuidString)")
    }
}
