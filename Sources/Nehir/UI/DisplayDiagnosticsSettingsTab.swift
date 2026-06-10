import AppKit
import SwiftUI

struct DisplayDiagnosticsSettingsTab: View {
    @State private var diagnostics = DisplayEnvironmentDiagnostics.current()
    @State private var monitors = Monitor.current()
    @State private var axGranted = AccessibilityPermissionMonitor.shared.isGranted

    var body: some View {
        Form {
            Section("Accessibility") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: axGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(axGranted ? .green : .red)
                        .font(.title3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(axGranted ? "Accessibility access granted" : "Accessibility access not granted")
                            .font(.headline)
                        Text("Nehir needs Accessibility access to observe and manage windows.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !axGranted {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section("Status") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: diagnostics.hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(diagnostics.hasWarnings ? .yellow : .green)
                        .font(.title3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(diagnostics.hasWarnings ? "Recommendations need attention" : "Display environment looks good")
                            .font(.headline)
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Refresh Diagnostics") {
                    refresh()
                }
            }

            Section("Display and Dock Recommendations") {
                SettingsCaption("For the best Niri scrolling experience, use an auto-hide Dock and arrange displays vertically in macOS System Settings.")

                if diagnostics.issues.isEmpty {
                    Label("No fixed Dock or side-by-side display arrangement detected.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    ForEach(diagnostics.issues) { issue in
                        DiagnosticIssueView(issue: issue)
                    }
                }
            }

            Section("Detected Displays") {
                if monitors.isEmpty {
                    Text("No displays detected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monitors, id: \.id) { monitor in
                        DisplayDiagnosticMonitorRow(monitor: monitor)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refresh()
        }
    }

    private var statusMessage: String {
        guard diagnostics.hasWarnings else {
            return "Auto-hide Dock and vertical display arrangement are the expected low-artifact configuration."
        }
        return "Nehir can still run, but parked offscreen windows may leave visible strips or bleed onto neighboring displays."
    }

    private func refresh() {
        monitors = Monitor.current()
        diagnostics = DisplayEnvironmentDiagnostics.evaluate(monitors: monitors)
        axGranted = AccessibilityPermissionMonitor.shared.isGranted
    }
}

private struct DiagnosticIssueView: View {
    let issue: DisplayEnvironmentDiagnostics.Issue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text(issue.message)
                .foregroundStyle(.secondary)
            Text(issue.recommendation)
        }
        .padding(.vertical, 4)
    }
}

private struct DisplayDiagnosticMonitorRow: View {
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(monitor.name)
                .font(.headline)
            Text("Frame: \(format(monitor.frame))")
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
            Text("Visible: \(format(monitor.visibleFrame))")
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 2)
    }

    private func format(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX.rounded())) y=\(Int(rect.minY.rounded())) w=\(Int(rect.width.rounded())) h=\(Int(rect.height.rounded()))"
    }
}
