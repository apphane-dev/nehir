// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI

private func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}

private func openExternal(_ url: URL) {
    NSWorkspace.shared.open(url)
}

/// GitHub Discussions — community feedback and feature ideas.
private let discussionsURL = URL(string: "\(ReleaseNotes.repositoryURLString)/discussions")!
/// GitHub Sponsors — financial support for Nehir's development.
private let sponsorsURL = URL(string: "https://github.com/sponsors/guria")!

/// Card-style link row used on the final onboarding step. Same visual treatment for
/// in-app destinations (e.g. What's New) and external browser links (feedback,
/// sponsorship): an icon, a two-line title/caption, and a trailing affordance that
/// reflects whether the destination is in-app (`chevron.right`) or external
/// (`arrow.up.right.square`).
private struct DoneStepLinkCard: View {
    let iconName: String
    let iconColor: Color
    let title: String
    let caption: String
    let external: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.callout)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: external ? "arrow.up.right.square" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct AccessibilityStepControl: View {
    let isGranted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "lock.fill")
                .font(.title3)
                .foregroundStyle(isGranted ? .green : .orange)
            if isGranted {
                Text("Accessibility access granted")
                    .foregroundStyle(.secondary)
            } else {
                Button("Open System Settings", action: openAccessibilitySettings)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 40)
        .animation(.easeInOut(duration: 0.2), value: isGranted)
    }
}

/// Reassurance shown on the final step. The Accessibility slide is optional, so if the
/// user skipped it we remind them here — without blocking completion. Also offers links
/// to What's New (in-app), GitHub Discussions for feedback, and GitHub Sponsors for
/// support, all rendered as `DoneStepLinkCard` rows.
struct DoneStepControl: View {
    let isGranted: Bool
    var onShowWhatsNew: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            if !isGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Accessibility access is needed to manage windows")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                Button("Open System Settings", action: openAccessibilitySettings)
                    .buttonStyle(.bordered)
                Text("You can finish now and enable it later from Settings → Diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let onShowWhatsNew {
                DoneStepLinkCard(
                    iconName: "sparkles",
                    iconColor: .accentColor,
                    title: "See What's New",
                    caption: "Review the latest changes in this release",
                    external: false,
                    action: onShowWhatsNew
                )
            }
            DoneStepLinkCard(
                iconName: "bubble.left.and.bubble.right",
                iconColor: .blue,
                title: "Share Feedback",
                caption: "Join discussions and suggest features",
                external: true,
                action: { openExternal(discussionsURL) }
            )
            DoneStepLinkCard(
                iconName: "heart.fill",
                iconColor: .pink,
                title: "Support Nehir",
                caption: "Sponsor development on GitHub",
                external: true,
                action: { openExternal(sponsorsURL) }
            )
        }
        .padding(.horizontal, 40)
    }
}

private struct WorkspaceBarFeatureRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $isOn) {
                Text(title)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Live-preview controls for the Workspace Bar step. Mirrors the `ExperimentalStepControl`
/// layout (left-aligned title + caption rows, no enclosing box) so choices here match what
/// users find later in Settings → Workspace Bar. Every row binds directly to `SettingsStore`,
/// so flipping any one re-renders `WorkspaceBarAnimation` above in real time.
struct WorkspaceBarStepControl: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceBarFeatureRow(
                title: "Enable Workspace Bar",
                description: "Floating bar tracking your active workspaces.",
                isOn: $settings.workspaceBarEnabled
            )

            Divider()

            WorkspaceBarFeatureRow(
                title: "Show Workspace Labels",
                description: "Number each workspace pill.",
                isOn: $settings.workspaceBarShowLabels
            )
            WorkspaceBarFeatureRow(
                title: "Show Floating Windows",
                description: "Include windows outside the tile layout.",
                isOn: $settings.workspaceBarShowFloatingWindows
            )
            WorkspaceBarFeatureRow(
                title: "Group Windows by App",
                description: "Collapse duplicate apps into a badge.",
                isOn: $settings.workspaceBarDeduplicateAppIcons
            )
            WorkspaceBarFeatureRow(
                title: "Hide Empty Workspaces",
                description: "Hide pills with no windows.",
                isOn: $settings.workspaceBarHideEmptyWorkspaces
            )
        }
        .padding(.horizontal, 32)
    }
}

struct NavigationStepControl: View {
    private struct Row {
        let bindingID: String
        let description: String
    }

    private let rows: [Row] = [
        Row(bindingID: "focus.left", description: "Focus windows"),
        Row(bindingID: "move.left", description: "Move windows"),
        Row(bindingID: "switchWorkspace.next", description: "Switch workspace"),
        Row(bindingID: "openCommandPalette", description: "Command Palette")
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                NavigationShortcutRow(
                    keys: keyDisplayString(for: row.bindingID),
                    description: row.description
                )
                if index < rows.count - 1 {
                    Divider()
                        .padding(.leading, 4)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                }
        }
        .padding(.horizontal, 40)
    }

    /// Resolves a binding's display string from `ActionCatalog` so the onboarding slide always
    /// matches the real default bindings and the formatting used in Settings → Hotkeys.
    private func keyDisplayString(for bindingID: String) -> String {
        let binding = ActionCatalog
            .defaultHotkeyBindings()
            .first { $0.id == bindingID }?
            .binding
        return binding?.displayString ?? "—"
    }
}

struct NavigationShortcutRow: View {
    let keys: String
    let description: String

    var body: some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ExperimentalFeatureRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $isOn) {
                HStack(spacing: 8) {
                    Text(title)
                    ExperimentalBadge()
                }
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExperimentalStepControl: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExperimentalFeatureRow(
                title: "Focus Follows Mouse",
                description: "Moves keyboard focus to whichever window is under the cursor.",
                isOn: $settings.focusFollowsMouse
            )
            ExperimentalFeatureRow(
                title: "Move Cursor to Focused Window",
                description: "Warps the cursor to the center of a window when it receives keyboard focus.",
                isOn: $settings.moveMouseToFocusedWindow
            )
            ExperimentalFeatureRow(
                title: "Window Borders",
                description: "Highlights the currently focused window with a colored border.",
                isOn: $settings.bordersEnabled
            )

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: $settings.developerModeEnabled) {
                    HStack(spacing: 8) {
                        Text("Developer Mode")
                        DeveloperBadge()
                    }
                }
                Text(
                    "Recommended if you try the features above: lets you capture layout traces from the status bar so issues are easier to diagnose."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
    }
}
