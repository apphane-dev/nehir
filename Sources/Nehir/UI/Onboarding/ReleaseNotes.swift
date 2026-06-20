// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Shared Nehir repository and release-note URLs.
///
/// Both the What's New screen and the config-migration prompt link users to the
/// GitHub release page for full notes. Centralizing the repository URL and the
/// `releases/tag/v<version>` convention keeps them from drifting apart.
enum ReleaseNotes {
    /// The canonical GitHub repository URL (no trailing slash).
    static let repositoryURLString = "https://github.com/apphane-dev/nehir"

    /// The "all releases" index page.
    static var releasesURL: URL {
        URL(string: "\(repositoryURLString)/releases")!
    }

    /// The release page for a specific version.
    ///
    /// Falls back to the releases index for placeholder versions (e.g. dev builds
    /// whose version isn't known), so the link is always valid.
    static func url(forVersion version: String?) -> URL {
        guard let version else { return releasesURL }

        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPlaceholderVersion(trimmed) else {
            return releasesURL
        }
        return URL(string: "\(repositoryURLString)/releases/tag/v\(trimmed)") ?? releasesURL
    }

    private static func isPlaceholderVersion(_ version: String) -> Bool {
        let lowercased = version.lowercased()
        let normalized = lowercased.hasPrefix("v") ? String(lowercased.dropFirst()) : lowercased
        if normalized == "dev" || normalized == "development" {
            return true
        }

        let numericPart = normalized.split { $0 == "-" || $0 == "+" }.first ?? ""
        let components = numericPart.split(separator: ".")
        return !components.isEmpty && components.allSatisfy { Int($0) == 0 }
    }
}
