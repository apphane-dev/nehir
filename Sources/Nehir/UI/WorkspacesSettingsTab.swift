import NehirIPC
import SwiftUI

@MainActor
enum WorkspaceConfigurationDeletePolicy {
    static func canDelete(
        _ config: WorkspaceConfiguration,
        settings: SettingsStore,
        workspaceManager: WorkspaceManager
    ) -> Bool {
        if settings.workspaceConfigurations.count <= 1 {
            return false
        }
        guard let workspaceId = workspaceManager.workspaceId(named: config.name) else { return true }
        return workspaceManager.entries(in: workspaceId).isEmpty
    }

    static func deleteHelp(
        _ config: WorkspaceConfiguration,
        settings: SettingsStore,
        workspaceManager: WorkspaceManager
    ) -> String {
        if settings.workspaceConfigurations.count <= 1 {
            return "Nehir requires at least one configured workspace"
        }
        guard let workspaceId = workspaceManager.workspaceId(named: config.name) else {
            return "Delete workspace"
        }
        return workspaceManager.entries(in: workspaceId).isEmpty ?
            "Delete workspace" :
            "Move or close all windows in this workspace before deleting it"
    }
}

enum WorkspaceConfigurationAddPolicy {
    static func nextAvailableWorkspaceName(in configurations: [WorkspaceConfiguration]) -> String {
        WorkspaceIDPolicy.lowestUnusedRawID(in: configurations.map(\.name))
    }

    static let addButtonHelp = "Add the lowest unused workspace ID"
    static let footerText =
        "Workspace IDs use positive integers. Display Name is optional. Direct hotkeys only reach workspaces 1–9; add higher-numbered ones here or via nehirctl."
}

struct WorkspacesSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedConfigId: WorkspaceConfiguration.ID?
    @State private var addDraft: WorkspaceConfiguration?
    @State private var pendingDeleteConfig: WorkspaceConfiguration?
    @State private var connectedMonitors: [Monitor] = Monitor.sortedByPosition(Monitor.current())

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(sortedConfigurations, selection: $selectedConfigId) { config in
                    WorkspaceSidebarRow(configuration: config, connectedMonitors: connectedMonitors)
                        .tag(config.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDeleteConfig = config
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(!canDeleteConfiguration(config))
                        }
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 0) {
                    Button(action: startAdding) {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(addButtonHelp)
                    .accessibilityLabel("Add workspace")

                    Divider().frame(height: 16)

                    Button {
                        if let config = selectedConfig {
                            pendingDeleteConfig = config
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(minusButtonHelp)
                    .accessibilityLabel("Remove selected workspace")
                    .disabled(selectedConfig == nil || !canDeleteSelected)

                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(minWidth: 160, maxWidth: 240)

            Divider()

            Group {
                if let draft = addDraft {
                    WorkspaceAddPane(
                        initialConfiguration: draft,
                        connectedMonitors: connectedMonitors,
                        onSave: { newConfig in
                            addConfiguration(newConfig)
                            selectedConfigId = newConfig.id
                            addDraft = nil
                        },
                        onCancel: { addDraft = nil }
                    )
                } else if let configId = selectedConfigId,
                          let configIndex = settings.workspaceConfigurations.firstIndex(where: { $0.id == configId })
                {
                    let config = settings.workspaceConfigurations[configIndex]
                    WorkspaceDetailPane(
                        configuration: $settings.workspaceConfigurations[configIndex],
                        connectedMonitors: connectedMonitors,
                        canDelete: canDeleteConfiguration(config),
                        deleteHelp: deleteConfigurationHelp(config),
                        onDelete: { pendingDeleteConfig = config },
                        onChange: { controller.updateWorkspaceConfig() }
                    )
                    .id(configId)
                } else {
                    WorkspacesEmptyState(onAdd: startAdding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .omniBackgroundExtensionEffect()
        }
        .onKeyPress(.escape) {
            if addDraft != nil {
                addDraft = nil
                return .handled
            }
            if selectedConfigId != nil {
                selectedConfigId = nil
                return .handled
            }
            return .ignored
        }
        .confirmationDialog(
            "Delete workspace?",
            isPresented: isConfirmingDelete,
            presenting: pendingDeleteConfig
        ) { config in
            Button("Delete Workspace", role: .destructive) {
                deleteConfiguration(config)
            }
            Button("Cancel", role: .cancel) {}
        } message: { config in
            Text(deleteConfirmationMessage(for: config))
        }
    }

    private var sortedConfigurations: [WorkspaceConfiguration] {
        settings.workspaceConfigurations.sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
    }

    private var selectedConfig: WorkspaceConfiguration? {
        guard let id = selectedConfigId else { return nil }
        return settings.workspaceConfigurations.first(where: { $0.id == id })
    }

    private var canDeleteSelected: Bool {
        guard let config = selectedConfig else { return false }
        return canDeleteConfiguration(config)
    }

    private var minusButtonHelp: String {
        guard let config = selectedConfig else { return "Remove selected workspace" }
        return deleteConfigurationHelp(config)
    }

    private var addButtonHelp: String {
        WorkspaceConfigurationAddPolicy.addButtonHelp
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDeleteConfig != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteConfig = nil
                }
            }
        )
    }

    private func startAdding() {
        addDraft = WorkspaceConfiguration(
            name: WorkspaceConfigurationAddPolicy.nextAvailableWorkspaceName(in: settings.workspaceConfigurations),
            monitorAssignment: .main
        )
        selectedConfigId = nil
    }

    private func deleteConfirmationMessage(for config: WorkspaceConfiguration) -> String {
        let matchingRuleCount = settings.appRules.count { $0.assignToWorkspace == config.name }
        guard matchingRuleCount > 0 else {
            return "Delete workspace \(config.effectiveDisplayName)?"
        }
        let ruleText = matchingRuleCount == 1 ? "1 app rule" : "\(matchingRuleCount) app rules"
        return "Delete workspace \(config.effectiveDisplayName)? This also clears workspace assignments from \(ruleText)."
    }

    private func canDeleteConfiguration(_ config: WorkspaceConfiguration) -> Bool {
        WorkspaceConfigurationDeletePolicy.canDelete(
            config,
            settings: settings,
            workspaceManager: controller.workspaceManager
        )
    }

    private func deleteConfigurationHelp(_ config: WorkspaceConfiguration) -> String {
        WorkspaceConfigurationDeletePolicy.deleteHelp(
            config,
            settings: settings,
            workspaceManager: controller.workspaceManager
        )
    }

    private func addConfiguration(_ config: WorkspaceConfiguration) {
        settings.workspaceConfigurations.append(config)
        settings.workspaceConfigurations.sort { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
        controller.updateWorkspaceConfig()
    }

    private func deleteConfiguration(_ config: WorkspaceConfiguration) {
        guard canDeleteConfiguration(config) else { return }
        settings.workspaceConfigurations.removeAll { $0.id == config.id }
        for index in settings.appRules.indices where settings.appRules[index].assignToWorkspace == config.name {
            settings.appRules[index].assignToWorkspace = nil
        }
        controller.updateWorkspaceConfig()
        controller.updateAppRules()
        if selectedConfigId == config.id {
            selectedConfigId = nil
        }
    }
}

struct WorkspaceSidebarRow: View {
    let configuration: WorkspaceConfiguration
    let connectedMonitors: [Monitor]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(configuration.name)
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundColor(.secondary)

                Text(configuration.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "Workspace \(configuration.name)")
                    .font(.body)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(monitorColor.opacity(0.8))
                    .frame(width: 6, height: 6)
                Text(monitorLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var monitorLabel: String {
        monitorAssignmentLabel(configuration.monitorAssignment, monitors: connectedMonitors)
    }

    private var monitorColor: Color {
        if case let .specificDisplay(output) = configuration.monitorAssignment,
           output.resolveMonitor(in: connectedMonitors) == nil
        {
            return .orange
        }
        return .indigo
    }
}

struct WorkspacesEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No Workspace Selected")
                    .font(.headline)
                Text("Select a workspace from the sidebar to edit it,\nor add a new workspace to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Add Workspace", action: onAdd)
                    .buttonStyle(.borderedProminent)

                GroupBox {
                    Text(WorkspaceConfigurationAddPolicy.footerText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 480)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct WorkspaceDetailPane: View {
    @Binding var configuration: WorkspaceConfiguration
    let connectedMonitors: [Monitor]
    let canDelete: Bool
    let deleteHelp: String
    let onDelete: () -> Void
    let onChange: () -> Void

    @State private var pendingConfigSync: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("Display Name", text: displayNameBinding, prompt: Text("Workspace \(configuration.name)"))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.weight(.medium))

                LabeledContent("Internal ID") {
                    Text(configuration.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("A custom name to help identify this workspace in the overview and sidebar.")
            }

            Section("Home Monitor") {
                HomeMonitorPicker(
                    assignment: $configuration.monitorAssignment,
                    connectedMonitors: connectedMonitors
                )

                SettingsCaption(
                    "Main follows the current main display. Secondary follows the first non-main display. Specific Display pins this workspace to the selected monitor when available."
                )
            }

            Section {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Workspace", systemImage: "trash")
                }
                .disabled(!canDelete)

                if !canDelete {
                    SettingsCaption(deleteHelp)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: configuration) { _, _ in
            debouncedConfigSync()
        }
    }

    private func debouncedConfigSync() {
        pendingConfigSync?.cancel()
        pendingConfigSync = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            onChange()
        }
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: { configuration.displayName ?? "" },
            set: { configuration.displayName = $0.isEmpty ? nil : $0 }
        )
    }
}

struct WorkspaceAddPane: View {
    @State private var configuration: WorkspaceConfiguration
    let connectedMonitors: [Monitor]
    let onSave: (WorkspaceConfiguration) -> Void
    let onCancel: () -> Void

    init(
        initialConfiguration: WorkspaceConfiguration,
        connectedMonitors: [Monitor],
        onSave: @escaping (WorkspaceConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _configuration = State(initialValue: initialConfiguration)
        self.connectedMonitors = connectedMonitors
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        Form {
            Section {
                TextField("Display Name", text: displayNameBinding, prompt: Text("Workspace \(configuration.name)"))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.weight(.medium))

                LabeledContent("Internal ID") {
                    Text(configuration.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("A custom name to help identify this workspace in the overview and sidebar.")
            }

            Section("Home Monitor") {
                HomeMonitorPicker(
                    assignment: $configuration.monitorAssignment,
                    connectedMonitors: connectedMonitors
                )

                SettingsCaption(
                    "Main follows the current main display. Secondary follows the first non-main display. Specific Display pins this workspace to the selected monitor when available."
                )
            }

            Section {
                Button("Add Workspace") {
                    onSave(configuration)
                }
                .keyboardShortcut(.defaultAction)

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .formStyle(.grouped)
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: { configuration.displayName ?? "" },
            set: { configuration.displayName = $0.isEmpty ? nil : $0 }
        )
    }
}

struct HomeMonitorPicker: View {
    @Binding var assignment: MonitorAssignment
    let connectedMonitors: [Monitor]

    var body: some View {
        Picker("Home Monitor", selection: $assignment) {
            Text("Main").tag(MonitorAssignment.main)
            Text("Secondary").tag(MonitorAssignment.secondary)
            Divider()
            ForEach(connectedMonitors, id: \.id) { monitor in
                HStack {
                    Text(monitor.name)
                    if monitor.isMain {
                        Text("(Main)").foregroundColor(.secondary)
                    }
                }
                .tag(MonitorAssignment.specificDisplay(OutputId(from: monitor)))
            }
        }
    }
}

private func monitorAssignmentLabel(_ assignment: MonitorAssignment, monitors: [Monitor]) -> String {
    switch assignment {
    case .main:
        return "Main"
    case .secondary:
        return "Secondary"
    case let .specificDisplay(output):
        if output.resolveMonitor(in: monitors) != nil {
            return output.name
        }
        return "\(output.name) (Disconnected)"
    }
}
