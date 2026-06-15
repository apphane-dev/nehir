import AppKit
import SwiftUI

/// Shown when `settings.toml` contains keys the current config schema doesn't recognize.
/// Shown after Nehir has backed up the original file and attempted to write a clean
/// (recognized-keys-only) version before app activation. Copies an AI prompt that asks
/// the assistant to consult the release notes to migrate equivalent values from backup.
struct MigrationView: View {
    let unknownKeys: [String]
    let backupURL: URL?
    let backupError: String?
    let cleanupError: String?
    let onDismiss: () -> Void

    @State private var confirmation: String?

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Hero (top-aligned, matches OnboardingStepView typography)
            VStack(spacing: 8) {
                Text("Config Update Required")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(bodyText)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 28)

            // MARK: Unrecognized entries card
            VStack(spacing: 0) {
                ForEach(Array(unknownKeys.enumerated()), id: \.element) { index, key in
                    if index > 0 {
                        Divider().opacity(0.5)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red.opacity(0.7))
                        Text(key)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.red.opacity(0.75))
                        Spacer()
                        Text("ignored")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .padding(.horizontal, 40)

            Spacer(minLength: 20)

            // MARK: Hint + actions (bottom)
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
                .disabled(backupURL == nil)

                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 580)
        .background(.thickMaterial)
        .animation(.easeInOut(duration: 0.2), value: confirmation)
    }

    private var actionHint: String {
        if let backupURL {
            if let cleanupError {
                return "A timestamped backup was created at \(backupURL.lastPathComponent), but Nehir couldn't clean settings.toml (\(cleanupError)). Copy an AI prompt to migrate manually, or dismiss to continue startup."
            }
            return "A timestamped backup was created at \(backupURL.lastPathComponent) and settings.toml has already been cleaned. Copy an AI prompt to restore equivalent values from the backup, or dismiss."
        }
        if let backupError {
            return "Nehir couldn't create a backup (\(backupError)), so it left settings.toml unchanged. Dismiss to fix the file manually."
        }
        return "Nehir couldn't create a backup, so it left settings.toml unchanged. Dismiss to fix the file manually."
    }

    private var bodyText: String {
        if backupURL != nil, cleanupError == nil {
            return "Some entries in your settings.toml aren't recognized by this version. Nehir backed up the original and removed those entries before activation."
        }
        return "Some entries in your settings.toml aren't recognized by this version. Nehir will ignore them and continue with the current config schema, so you should update your file to avoid unexpected behavior."
    }

    /// Copies an AI prompt that references the timestamped backup created before this dialog
    /// was shown. Cleanup has already been attempted before app activation.
    private func copyPrompt() {
        guard let backupURL else {
            confirmation = "Couldn't copy prompt because no backup was created"
            return
        }

        let prompt = buildPrompt(backupURL: backupURL)
        NSPasteboard.general.clearContents()
        let didCopy = NSPasteboard.general.setString(prompt, forType: .string)

        confirmation = didCopy ? "Prompt copied to clipboard" : nil
    }

    private func buildPrompt(backupURL: URL) -> String {
        let version = Bundle.main.appVersion ?? "dev"
        let releaseURL = ReleaseNotes.url(forVersion: version).absoluteString

        var lines: [String] = []
        lines.append("I use Nehir (a macOS tiling window manager). I'm running version \(version).")
        lines.append("My settings.toml contained config keys that the current version no longer recognizes:")
        lines.append("")
        for key in unknownKeys {
            lines.append("- \(key)")
        }
        lines.append("")
        if let cleanupError {
            lines.append("Nehir created a timestamped backup, but couldn't automatically rewrite settings.toml:")
            lines.append(cleanupError)
        } else {
            lines.append("Nehir created a timestamped backup before activation and rewrote settings.toml")
            lines.append("with a clean version (the unrecognized entries were dropped; the current schema is in effect).")
        }
        lines.append("")
        lines.append("Please read the backup, then consult the Nehir release notes/changelog to discover")
        lines.append("what these keys were renamed or replaced with. Start with this release page:")
        lines.append(releaseURL)
        lines.append("")
        lines.append("Repository releases page:")
        lines.append(ReleaseNotes.releasesURL.absoluteString)
        lines.append("")
        lines.append("If the relevant rename happened in an older version, discover and inspect older")
        lines.append("release notes on your own until you find the change. Then update settings.toml to")
        lines.append("use the current key names with equivalent values from the backup.")
        lines.append("")
        lines.append("Backup path: \(backupURL.path)")
        return lines.joined(separator: "\n")
    }
}
