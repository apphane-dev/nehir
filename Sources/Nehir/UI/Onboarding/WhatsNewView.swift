import AppKit
import SwiftUI

struct WhatsNewView: View {
    let version: String
    let bullets: [String]
    let onDismiss: () -> Void
    var onRerunOnboarding: (() -> Void)? = nil
    var onOpenDiagnostics: (() -> Void)? = nil

    @State private var settingsIssues: [SettingsDiagnosticsIssue] = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("What's New")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text("Nehir \(version)")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, settingsIssues.isEmpty ? 28 : 16)

            ScrollView {
                VStack(spacing: 16) {
                    if !settingsIssues.isEmpty {
                        settingsWarningsCard
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(bullets.enumerated()), id: \.offset) { index, bullet in
                            if index > 0 {
                                Divider().opacity(0.5)
                            }
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.tint)
                                    .padding(.top, 1)
                                Text(bullet)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                }
                .padding(.horizontal, 40)
            }

            Spacer(minLength: 20)

            Link(destination: ReleaseNotes.url(forVersion: version)) {
                HStack(spacing: 4) {
                    Text("Read full release notes")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.footnote)
            }
            .padding(.bottom, 16)

            HStack(spacing: 12) {
                if let onRerunOnboarding {
                    Button("Re-run Setup Wizard", action: onRerunOnboarding)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Button("Got it", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 640)
        .background(.thickMaterial)
        .onAppear(perform: refreshSettingsIssues)
        .onReceive(NotificationCenter.default.publisher(for: .settingsMigrationStateDidChange)) { _ in
            refreshSettingsIssues()
        }
    }

    private var settingsWarningsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Settings needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.yellow)

            ForEach(settingsIssues) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: issue))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(label(for: issue))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button("Open Diagnostics") {
                (onOpenDiagnostics ?? defaultOpenDiagnostics)()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1)
        )
    }

    private func icon(for issue: SettingsDiagnosticsIssue) -> String {
        switch issue {
        case .softMigration: return "arrow.triangle.2.circlepath"
        case .unknownKeys: return "questionmark.circle"
        }
    }

    private func label(for issue: SettingsDiagnosticsIssue) -> String {
        switch issue {
        case .softMigration(let migration):
            return migration.descriptor.title
        case .unknownKeys(let unknownKeys):
            let suffix = unknownKeys.keyPaths.count == 1 ? "key" : "keys"
            return "\(unknownKeys.keyPaths.count) unrecognized settings \(suffix)"
        }
    }

    private func refreshSettingsIssues() {
        settingsIssues = SettingsDiagnosticsDetector.pendingIssues()
    }

    private var defaultOpenDiagnostics: () -> Void {
        {
            guard let settings = AppDelegate.sharedBootstrap?.settings,
                  let controller = AppDelegate.sharedBootstrap?.controller else { return }
            SettingsWindowController.shared.show(
                settings: settings,
                controller: controller,
                section: .diagnostics
            )
        }
    }
}
