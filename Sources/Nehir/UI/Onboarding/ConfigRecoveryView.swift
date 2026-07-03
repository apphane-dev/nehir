// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI

/// Blocking pre-bootstrap recovery shown only when `settings.toml` cannot be safely loaded
/// (parse failure, wrong known-key type, or an unsupported/enforced legacy format). Unknown
/// keys in otherwise valid TOML are handled non-blockingly in Diagnostics.
struct ConfigRecoveryView: View {
    let affectedFile: URL
    let details: [String]
    let backupURL: URL?
    let onDismiss: () -> Void

    @State private var confirmation: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Couldn't load settings.toml")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(
                    "Nehir found invalid or unsupported settings before startup. The file was not rewritten automatically."
                )
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 10) {
                Text("File: \(affectedFile.path)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                ForEach(details, id: \.self) { detail in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red.opacity(0.75))
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red.opacity(0.8))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .padding(.horizontal, 40)

            Spacer(minLength: 20)

            VStack(spacing: 14) {
                Text(actionHint)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                    .padding(.horizontal, 24)

                if let confirmation {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(confirmation)
                    }
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
                }

                Button("Copy AI Prompt") {
                    copyPrompt()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Continue with Defaults") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 500, height: 580)
        .background(.thickMaterial)
        .animation(.easeInOut(duration: 0.2), value: confirmation)
    }

    private var actionHint: String {
        var text = "Copy a prompt for an AI assistant, fix settings.toml manually, then relaunch Nehir. Continuing starts with built-in defaults for this session."
        if let backupURL {
            text += " Backup: \(backupURL.lastPathComponent)."
        }
        return text
    }

    private func copyPrompt() {
        let prompt = ConfigAssistancePrompt.prompt(
            kind: .loadFailure,
            appVersion: Bundle.main.appVersion ?? "dev",
            affectedFile: affectedFile,
            details: details,
            backupURL: backupURL
        )
        NSPasteboard.general.clearContents()
        confirmation = NSPasteboard.general.setString(prompt, forType: .string) ? "Prompt copied to clipboard" : nil
    }
}
