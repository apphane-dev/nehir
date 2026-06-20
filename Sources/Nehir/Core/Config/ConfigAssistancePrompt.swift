import Foundation

enum ConfigAssistancePrompt {
    enum AssistanceKind {
        case unknownKeys
        case loadFailure
        case enforcedMigration

        var summary: String {
            switch self {
            case .unknownKeys:
                return "config keys that Nehir does not recognize"
            case .loadFailure:
                return "settings.toml content that Nehir could not load"
            case .enforcedMigration:
                return "config content that must be migrated before this Nehir version can use it"
            }
        }
    }

    static func prompt(
        kind: AssistanceKind,
        appVersion: String,
        affectedFile: URL,
        details: [String],
        backupURL: URL? = nil
    ) -> String {
        let releaseURL = ReleaseNotes.url(forVersion: appVersion).absoluteString
        var lines: [String] = []
        lines.append("I use Nehir (a macOS tiling window manager). I'm running version \(appVersion).")
        lines.append("I need help with \(kind.summary) in this file:")
        lines.append(affectedFile.path)
        lines.append("")

        if !details.isEmpty {
            lines.append("Details:")
            for detail in details {
                lines.append("- \(detail)")
            }
            lines.append("")
        }

        switch kind {
        case .unknownKeys:
            lines
                .append(
                    "These keys are valid TOML and Nehir preserves them on save, but this version ignores them because they are not part of the current settings schema."
                )
            lines
                .append(
                    "Please consult the Nehir release notes/changelog to discover whether they were renamed, replaced, or removed, then suggest current settings.toml entries with equivalent behavior."
                )
        case .loadFailure:
            lines
                .append(
                    "Nehir could not safely load this file. Please identify the invalid or unsupported entries, consult the Nehir release notes/changelog, and suggest a corrected settings.toml that preserves equivalent behavior where possible."
                )
        case .enforcedMigration:
            lines
                .append(
                    "This file uses a config format that this version no longer accepts. Please consult the Nehir release notes/changelog and migrate it to the current format while preserving equivalent behavior."
                )
        }
        lines.append("")
        lines.append("Start with this release page:")
        lines.append(releaseURL)
        lines.append("")
        lines.append("Repository releases page:")
        lines.append(ReleaseNotes.releasesURL.absoluteString)

        if let backupURL {
            lines.append("")
            lines.append("Backup path: \(backupURL.path)")
        }

        return lines.joined(separator: "\n")
    }
}
