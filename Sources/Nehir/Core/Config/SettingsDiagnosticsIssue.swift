// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct UnknownSettingsKeysIssue: Identifiable, Equatable {
    let fileURL: URL
    let keyPaths: [String]

    var id: String {
        Self.postponeID(fileURL: fileURL)
    }

    static func postponeID(fileURL: URL) -> String {
        "unknown-settings-keys:\(fileURL.path)"
    }
}

/// A live (Carbon-level or internal Nehir) hotkey registration failure surfaced as a
/// Diagnostics row. Built from `HotkeyCenter.registrationFailures`.
struct HotkeyConflictIssue: Identifiable, Equatable {
    /// Stable Nehir action identifier (e.g. `"openCommandPalette"`), or a synthesized
    /// fallback when the failing command has no resolved binding.
    let actionID: String
    let command: HotkeyCommand
    let chordDisplayString: String
    let reason: HotkeyRegistrationFailureReason

    var id: String {
        "hotkey-conflict:\(actionID)"
    }

    var commandDisplayName: String {
        command.displayName
    }

    var remediation: String {
        switch reason {
        case .systemReserved:
            return "Another app registered this shortcut; reassign it in Hotkeys or quit the conflicting app."
        case .duplicateBinding:
            return "Two Nehir commands share this shortcut; assign a unique chord."
        }
    }
}

/// A curated, default-chord-scoped advisory for Nehir defaults that are known to
/// co-fire with macOS system shortcuts (where Carbon registration still succeeds,
/// so `HotkeyConflictIssue` cannot capture them). See `HotkeyAdvisoryCatalog`.
struct HotkeyAdvisoryIssue: Identifiable, Equatable {
    let actionID: String
    let command: HotkeyCommand
    let chordDisplayString: String
    let advisoryText: String

    var id: String {
        "hotkey-advisory:\(actionID)"
    }

    var commandDisplayName: String {
        command.displayName
    }
}

enum SettingsDiagnosticsIssue: Identifiable, Equatable {
    case softMigration(PendingSettingsMigration)
    case unknownKeys(UnknownSettingsKeysIssue)
    case hotkeyConflict(HotkeyConflictIssue)
    case hotkeyAdvisory(HotkeyAdvisoryIssue)

    var id: String {
        switch self {
        case .softMigration(let migration):
            return "migration:\(migration.id)"
        case .unknownKeys(let issue):
            return issue.id
        case .hotkeyConflict(let issue):
            return issue.id
        case .hotkeyAdvisory(let issue):
            return issue.id
        }
    }
}

enum SettingsDiagnosticsDetector {
    /// Computes all applicable Diagnostics issues. The `hotkeyFailures` and
    /// `hotkeyBindings` parameters feed the live hotkey diagnostics (registration
    /// conflicts plus curated default-chord advisories); leaving them empty keeps
    /// the historical config-file-only behavior.
    static func applicableIssues(
        configDirectory: URL = SettingsFilePersistence.defaultDirectoryURL,
        hotkeyFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:],
        hotkeyBindings: [HotkeyBinding] = []
    ) -> [SettingsDiagnosticsIssue] {
        var issues = configBasedIssues(configDirectory: configDirectory)
        issues.append(contentsOf: hotkeyConflictIssues(failures: hotkeyFailures, bindings: hotkeyBindings))
        issues.append(contentsOf: hotkeyAdvisoryIssues(bindings: hotkeyBindings))
        return issues
    }

    static func pendingIssues(
        configDirectory: URL = SettingsFilePersistence.defaultDirectoryURL,
        stateStore: SettingsMigrationStateStore = SettingsMigrationStateStore(),
        appVersion: String = Bundle.main.appVersion ?? "dev",
        hotkeyFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:],
        hotkeyBindings: [HotkeyBinding] = []
    ) -> [SettingsDiagnosticsIssue] {
        applicableIssues(
            configDirectory: configDirectory,
            hotkeyFailures: hotkeyFailures,
            hotkeyBindings: hotkeyBindings
        ).filter { issue in
            !stateStore.isPostponed(migrationID: postponeID(for: issue), currentAppVersion: appVersion)
        }
    }

    static func postponeID(for issue: SettingsDiagnosticsIssue) -> String {
        switch issue {
        case .softMigration(let migration):
            return migration.id
        case .unknownKeys(let issue):
            return issue.id
        case .hotkeyConflict,
             .hotkeyAdvisory:
            // Live hotkey advisories are not postponable; they clear once the user
            // reassigns the conflicting chord, so they always pass the postponement filter.
            return Self.nonPostponableID
        }
    }

    /// Sentinel id that `SettingsMigrationStateStore` never records, so non-postponable
    /// issues are always reported by `pendingIssues`.
    private static let nonPostponableID = "hotkey:non-postponable"

    private static func configBasedIssues(configDirectory: URL) -> [SettingsDiagnosticsIssue] {
        var issues = SettingsMigrationDetector.applicableMigrations(configDirectory: configDirectory)
            .map(SettingsDiagnosticsIssue.softMigration)

        let settingsURL = configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        let unknownKeys = detectUnknownKeys(in: settingsURL)
        if !unknownKeys.isEmpty {
            issues.append(.unknownKeys(UnknownSettingsKeysIssue(fileURL: settingsURL, keyPaths: unknownKeys)))
        }
        return issues
    }

    private static func hotkeyConflictIssues(
        failures: [HotkeyCommand: HotkeyRegistrationFailureReason],
        bindings: [HotkeyBinding]
    ) -> [SettingsDiagnosticsIssue] {
        guard !failures.isEmpty else { return [] }
        let bindingsByCommand = Dictionary(
            bindings.map { ($0.command, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return failures
            .sorted { lhs, rhs in
                let lhsName = lhs.key.displayName
                let rhsName = rhs.key.displayName
                if lhsName != rhsName { return lhsName < rhsName }
                return (bindingsByCommand[lhs.key]?.id ?? "") < (bindingsByCommand[rhs.key]?.id ?? "")
            }
            .map { command, reason -> SettingsDiagnosticsIssue in
                let binding = bindingsByCommand[command]
                let actionID = binding?.id ?? "command:\(String(describing: command))"
                let chordDisplay = binding?.binding.displayString ?? "unknown"
                return .hotkeyConflict(HotkeyConflictIssue(
                    actionID: actionID,
                    command: command,
                    chordDisplayString: chordDisplay,
                    reason: reason
                ))
            }
    }

    /// Curated advisories fire only while the user is still on the Nehir default chord
    /// for the action (reassigning or unassigning suppresses them — no false positives
    /// on custom chords). The default chord is derived from `HotkeyBindingRegistry` so the
    /// catalog never hardcodes Carbon key constants.
    private static func hotkeyAdvisoryIssues(bindings: [HotkeyBinding]) -> [SettingsDiagnosticsIssue] {
        guard !bindings.isEmpty, !HotkeyAdvisoryCatalog.knownSystemConflicts.isEmpty else { return [] }
        let currentByID = Dictionary(
            bindings.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let defaultsByID = Dictionary(
            HotkeyBindingRegistry.defaults().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return HotkeyAdvisoryCatalog.knownSystemConflicts.compactMap { advisory in
            guard let current = currentByID[advisory.actionID],
                  let defaultBinding = defaultsByID[advisory.actionID],
                  current.binding == defaultBinding.binding,
                  case let .chord(chord) = current.binding,
                  !chord.isUnassigned
            else { return nil }
            return .hotkeyAdvisory(HotkeyAdvisoryIssue(
                actionID: advisory.actionID,
                command: advisory.command,
                chordDisplayString: chord.displayString,
                advisoryText: advisory.advisoryText
            ))
        }
    }
}
