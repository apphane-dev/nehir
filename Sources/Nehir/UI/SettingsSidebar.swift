// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    @State private var diagnosticsIssueCount = 0

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsSectionGroup.allCases) { group in
                if let title = group.displayName {
                    Section(title) {
                        ForEach(group.sections) { section in
                            sidebarRow(for: section)
                                .tag(section)
                        }
                    }
                } else {
                    Section {
                        ForEach(group.sections) { section in
                            sidebarRow(for: section)
                                .tag(section)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        .onAppear { refreshDiagnostics() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsMigrationStateDidChange)) { _ in
            refreshDiagnostics()
        }
    }

    @ViewBuilder
    private func sidebarRow(for section: SettingsSection) -> some View {
        if section == .diagnostics && diagnosticsIssueCount > 0 {
            LabeledContent {
                Text("\(diagnosticsIssueCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange, in: Capsule())
            } label: {
                Label(section.displayName, systemImage: section.icon)
            }
        } else {
            Label(section.displayName, systemImage: section.icon)
        }
    }

    private func refreshDiagnostics() {
        let diagIssues = DisplayEnvironmentDiagnostics.current().issues.count
        let axIssue = AccessibilityPermissionMonitor.shared.isGranted ? 0 : 1
        let settingsIssues = SettingsDiagnosticsDetector.pendingIssues().count
        diagnosticsIssueCount = diagIssues + axIssue + settingsIssues
    }
}
