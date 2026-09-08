// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

public struct IPCRuleValidationReport: Equatable, Sendable {
    public let bundleIdError: String?
    public let applicationSelectorError: String?
    public let invalidRegexMessage: String?

    public init(bundleIdError: String?, applicationSelectorError: String?, invalidRegexMessage: String?) {
        self.bundleIdError = bundleIdError
        self.applicationSelectorError = applicationSelectorError
        self.invalidRegexMessage = invalidRegexMessage
    }

    public var isValid: Bool {
        bundleIdError == nil && applicationSelectorError == nil && invalidRegexMessage == nil
    }
}

public enum IPCRuleValidator {
    private static let appIdentifierPattern = try! NSRegularExpression(
        pattern: "^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$"
    )

    public static func bundleIdError(for bundleId: String?) -> String? {
        guard let bundleId else { return nil }
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Invalid bundle ID format"
        }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard appIdentifierPattern.firstMatch(in: trimmed, range: range) != nil else {
            return "Invalid bundle ID format"
        }
        return nil
    }

    public static func invalidRegexMessage(for pattern: String?) -> String? {
        guard let pattern = pattern?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty else {
            return nil
        }

        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public static func validate(_ rule: IPCRuleDefinition) -> IPCRuleValidationReport {
        let bundleId = rule.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appNameSubstring = rule.appNameSubstring?.trimmingCharacters(in: .whitespacesAndNewlines)
        let applicationSelectorError = bundleId?.isEmpty == false || appNameSubstring?.isEmpty == false
            ? nil
            : "Bundle ID or app name is required"

        return IPCRuleValidationReport(
            bundleIdError: bundleIdError(for: rule.bundleId),
            applicationSelectorError: applicationSelectorError,
            invalidRegexMessage: invalidRegexMessage(for: rule.titleRegex)
        )
    }
}
