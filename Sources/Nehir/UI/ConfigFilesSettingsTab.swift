import SwiftUI

struct ConfigFilesSettingsTab: View {
    @Bindable var settings: SettingsStore

    @State private var resultStatus: SettingsFileStatus?
    @State private var resultVisible = false
    @State private var dismissTask: DispatchWorkItem?

    var body: some View {
        Form {
            Section("Configuration") {
                LabeledContent("Config Folder") {
                    HStack {
                        Text(settings.configDirectoryURL.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Reveal in Finder") {
                            performAction(.revealConfigFolder)
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
                            performAction(.openMainSettingsFile)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if resultVisible, let status = resultStatus {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: status.icon)
                            .foregroundStyle(status.color)
                        Text(status.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .padding(.bottom, 16)
            }
        }
    }

    private func performAction(_ action: SettingsFileAction) {
        dismissTask?.cancel()
        withAnimation { resultVisible = false }
        do {
            let status = try SettingsFileWorkflow.perform(action, settings: settings)
            resultStatus = status
        } catch {
            resultStatus = .error(error.localizedDescription)
        }
        withAnimation { resultVisible = true }
        let task = DispatchWorkItem {
            withAnimation { self.resultVisible = false }
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }
}
