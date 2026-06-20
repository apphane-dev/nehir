// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

/// Reveal/edit controls for Nehir's on-disk configuration files, rendered as a
/// `Section` inside the General settings tab. Action feedback (the result
/// toast) is surfaced by the hosting tab via the `onAction` callback.
struct ConfigurationFilesSection: View {
    let settings: SettingsStore
    let onAction: (SettingsFileAction) -> Void

    var body: some View {
        Section("Configuration") {
            LabeledContent("Config Folder") {
                HStack {
                    Text(settings.configDirectoryURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Reveal in Finder") {
                        onAction(.revealConfigFolder)
                    }
                }
            }

            LabeledContent("Settings File") {
                HStack {
                    Text(settings.settingsFileURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Edit") {
                        onAction(.openMainSettingsFile)
                    }
                }
            }
        }
    }
}
