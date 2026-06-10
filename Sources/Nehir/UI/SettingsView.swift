import Observation
import SwiftUI

@MainActor @Observable
final class SettingsNavigationModel {
    var selectedSection: SettingsSection

    init(selectedSection: SettingsSection = .general) {
        self.selectedSection = selectedSection
    }
}

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var navigation: SettingsNavigationModel
    var cliManager: AppCLIManager?

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $navigation.selectedSection)
        } detail: {
            SettingsDetailView(
                section: navigation.selectedSection,
                settings: settings,
                controller: controller,
                cliManager: cliManager
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
    }
}

struct GeneralSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    var cliManager: AppCLIManager?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: settings.appearanceMode) { _, _ in
                    controller.applyCurrentAppearanceMode()
                }

                SettingsCaption("Controls the appearance of menus and workspace bar")

            }

            Section("Status Bar") {
                Toggle("Show Workspace", isOn: $settings.statusBarShowWorkspaceName)
                    .onChange(of: settings.statusBarShowWorkspaceName) { _, _ in
                        controller.requestSettingsProjectionRefresh(reason: "statusBarShowWorkspaceName")
                    }
                Toggle("Show Number Instead of Name", isOn: $settings.statusBarUseWorkspaceId)
                    .onChange(of: settings.statusBarUseWorkspaceId) { _, _ in
                        controller.requestSettingsProjectionRefresh(reason: "statusBarUseWorkspaceId")
                    }
                    .disabled(!settings.statusBarShowWorkspaceName)
                Toggle("Show Focused App", isOn: $settings.statusBarShowAppNames)
                    .onChange(of: settings.statusBarShowAppNames) { _, _ in
                        controller.requestSettingsProjectionRefresh(reason: "statusBarShowAppNames")
                    }
                    .disabled(!settings.statusBarShowWorkspaceName)
                SettingsCaption("Shows the active workspace and focused app beside the menu bar icon")
            }

            Section("Power") {
                Toggle("Prevent Display Sleep", isOn: $settings.preventSleepEnabled)
                    .onChange(of: settings.preventSleepEnabled) { _, newValue in
                        controller.setPreventSleepEnabled(newValue)
                    }
                SettingsCaption("Keeps the display awake while Nehir is running.")
            }

            Section("Developer") {
                Toggle(isOn: $settings.developerModeEnabled) {
                    HStack(spacing: 8) {
                        Text("Developer Mode")
                        DeveloperBadge()
                    }
                }
                SettingsCaption("Shows debug commands in the palette, hotkey settings, and enables IPC debug endpoints.")
            }

            if let cliManager {
                CLISettingsSection(cliManager: cliManager)
            }

        }
        .formStyle(.grouped)
    }
}

@MainActor
struct CLISettingsSection: View {
    let cliManager: AppCLIManager

    @State private var status: AppCLIExposureStatus?
    @State private var actionError: String?

    var body: some View {
        Section("Command Line") {
            switch status {
            case .homebrewManaged:
                LabeledContent("nehirctl") {
                    Text("Managed by Homebrew")
                        .foregroundStyle(.secondary)
                }
            case let .appManaged(linkURL, directoryOnPath):
                LabeledContent("nehirctl") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(linkURL.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if !directoryOnPath {
                            Text("Directory not in PATH")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Button("Remove from PATH", role: .destructive) {
                    removeCLI()
                }
            case let .notInstalled(linkURL, directoryOnPath):
                LabeledContent("nehirctl") {
                    Text("Not installed")
                        .foregroundStyle(.secondary)
                }
                Button("Install to PATH") {
                    installCLI(linkURL: linkURL, directoryOnPath: directoryOnPath)
                }
            case let .conflict(existingURL):
                LabeledContent("nehirctl") {
                    Text("Conflict at \(existingURL.path)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case nil:
                EmptyView()
            }

            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            SettingsCaption("Install the `nehirctl` command line tool to control Nehir from Terminal.")
        }
        .onAppear { status = cliManager.exposureStatus() }
    }

    private func installCLI(linkURL _: URL, directoryOnPath _: Bool) {
        actionError = nil
        do {
            _ = try cliManager.installCLIToPATH()
            status = cliManager.exposureStatus()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func removeCLI() {
        actionError = nil
        do {
            _ = try cliManager.removeInstalledCLI()
            status = cliManager.exposureStatus()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

struct NiriSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.niriSettings(for: $0) != nil },
                reset: { monitor in
                    settings.removeNiriSettings(for: monitor)
                    controller.updateMonitorNiriSettings()
                }
            )

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorNiriSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                GlobalNiriSettingsSection(
                    settings: settings,
                    controller: controller
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            connectedMonitors = Monitor.current()
        }
    }
}

struct GlobalNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        let useAutoDefaultColumnWidth = Binding(
            get: { settings.niriDefaultColumnWidth == nil },
            set: { useAuto in
                settings.niriDefaultColumnWidth = useAuto ? nil : (settings.niriDefaultColumnWidth ?? 0.5)
                controller.updateNiriConfig(defaultColumnWidth: settings.niriDefaultColumnWidth)
            }
        )
        let defaultColumnWidthPercent = Binding(
            get: { Int((settings.niriDefaultColumnWidth ?? 0.5) * 100) },
            set: { newPercent in
                settings.niriDefaultColumnWidth = Double(min(100, max(5, newPercent))) / 100.0
                controller.updateNiriConfig(defaultColumnWidth: settings.niriDefaultColumnWidth)
            }
        )
        let presets = settings.niriColumnWidthPresets

        Section("Column Layout") {
            SettingsSliderRow(
                label: "Visible Columns",
                value: Binding(
                    get: { Double(settings.niriMaxVisibleColumns) },
                    set: { settings.niriMaxVisibleColumns = Int($0) }
                ),
                range: 1 ... 5,
                step: 1,
                valueText: "\(settings.niriMaxVisibleColumns)",
                valueWidth: 32
            )
            .onChange(of: settings.niriMaxVisibleColumns) { _, newValue in
                controller.updateNiriConfig(maxVisibleColumns: newValue)
            }

            Toggle("Wrap Navigation at Edges", isOn: $settings.niriInfiniteLoop)
                .onChange(of: settings.niriInfiniteLoop) { _, newValue in
                    controller.updateNiriConfig(infiniteLoop: newValue)
                }
            SettingsCaption("When navigating past the last column, wrap around to the first.")

            Picker("Center Focused Column", selection: $settings.niriCenterFocusedColumn) {
                ForEach(CenterFocusedColumn.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: settings.niriCenterFocusedColumn) { _, newValue in
                controller.updateNiriConfig(centerFocusedColumn: newValue)
            }

            Toggle("Always Center Single Column", isOn: $settings.niriAlwaysCenterSingleColumn)
                .onChange(of: settings.niriAlwaysCenterSingleColumn) { _, newValue in
                    controller.updateNiriConfig(alwaysCenterSingleColumn: newValue)
                }
            SettingsCaption("When only one column is visible, keep it centered on screen.")

            Picker("Single Window Width", selection: $settings.niriSingleWindowAspectRatio) {
                ForEach(SingleWindowAspectRatio.allCases, id: \.self) { ratio in
                    Text(ratio.displayName).tag(ratio)
                }
            }
            .onChange(of: settings.niriSingleWindowAspectRatio) { _, newValue in
                controller.updateNiriConfig(singleWindowAspectRatio: newValue)
            }
            SettingsCaption("Column width used when a window has no siblings on the same workspace.")
        }

        Section("Default New Column Width") {
            LabeledContent("Width Mode") {
                Picker("Width Mode", selection: useAutoDefaultColumnWidth) {
                    Text("Auto").tag(true)
                    Text("Custom").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            if settings.niriDefaultColumnWidth != nil {
                LabeledContent("Custom Width") {
                    HStack {
                        TextField("Custom Width", value: defaultColumnWidthPercent, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCaption(
                settings.niriDefaultColumnWidth == nil
                    ? "Auto uses the balanced width for the current Visible Columns setting."
                    : "New or claimed columns start at this width until you resize them."
            )
        }

        Section("Column Width Cycle Presets") {
            ForEach(presets.indices, id: \.self) { index in
                LabeledContent("Preset \(index + 1)") {
                    HStack {
                        TextField("Preset \(index + 1)", value: Binding(
                            get: { Int(presets[index] * 100) },
                            set: { newPercent in
                                var current = settings.niriColumnWidthPresets
                                current[index] = Double(min(100, max(5, newPercent))) / 100.0
                                settings.niriColumnWidthPresets = current
                                controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                            }
                        ), format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Preset \(index + 1) width")
                        Text("%")
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            var presets = settings.niriColumnWidthPresets
                            presets.remove(at: index)
                            settings.niriColumnWidthPresets = presets
                            controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                        } label: {
                            Label("Remove preset \(index + 1)", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove preset \(index + 1)")
                        .disabled(settings.niriColumnWidthPresets.count <= 2)
                    }
                }
            }

            HStack {
                Button("Add Preset") {
                    var presets = settings.niriColumnWidthPresets
                    presets.append(0.5)
                    settings.niriColumnWidthPresets = presets
                    controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                }
                Button("Reset Cycle Presets") {
                    settings.niriColumnWidthPresets = SettingsStore.defaultColumnWidthPresets
                    controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                }
            }
            SettingsCaption("Resize commands cycle through these presets in order. Duplicates are allowed.")
        }
        .id(settings.niriColumnWidthPresets.count)
    }
}

struct MonitorNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorNiriSettings {
        settings.niriSettings(for: monitor) ?? MonitorNiriSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId
        )
    }

    private func updateSetting(_ update: (inout MonitorNiriSettings) -> Void) {
        var ms = monitorSettings
        ms.monitorName = monitor.name
        ms.monitorDisplayId = monitor.displayId
        update(&ms)
        settings.updateNiriSettings(ms)
        controller.updateMonitorNiriSettings()
    }

    var body: some View {
        let ms = monitorSettings

        Section("Column Layout") {
            OverridableSlider(
                label: "Visible Columns",
                value: ms.maxVisibleColumns.map { Double($0) },
                globalValue: Double(settings.niriMaxVisibleColumns),
                range: 1 ... 5,
                step: 1,
                formatter: { "\(Int($0))" },
                onChange: { newValue in updateSetting { $0.maxVisibleColumns = Int(newValue) } },
                onReset: { updateSetting { $0.maxVisibleColumns = nil } }
            )

            OverridableToggle(
                label: "Wrap Navigation at Edges",
                value: ms.infiniteLoop,
                globalValue: settings.niriInfiniteLoop,
                onChange: { newValue in updateSetting { $0.infiniteLoop = newValue } },
                onReset: { updateSetting { $0.infiniteLoop = nil } }
            )

            OverridablePicker(
                label: "Center Focused Column",
                value: ms.centerFocusedColumn,
                globalValue: settings.niriCenterFocusedColumn,
                options: CenterFocusedColumn.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.centerFocusedColumn = newValue } },
                onReset: { updateSetting { $0.centerFocusedColumn = nil } }
            )

            OverridableToggle(
                label: "Always Center Single Column",
                value: ms.alwaysCenterSingleColumn,
                globalValue: settings.niriAlwaysCenterSingleColumn,
                onChange: { newValue in updateSetting { $0.alwaysCenterSingleColumn = newValue } },
                onReset: { updateSetting { $0.alwaysCenterSingleColumn = nil } }
            )

            OverridablePicker(
                label: "Single Window Width",
                value: ms.singleWindowAspectRatio,
                globalValue: settings.niriSingleWindowAspectRatio,
                options: SingleWindowAspectRatio.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.singleWindowAspectRatio = newValue } },
                onReset: { updateSetting { $0.singleWindowAspectRatio = nil } }
            )
        }
    }
}
