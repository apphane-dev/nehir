// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Observation
import SwiftUI

@MainActor @Observable
final class SettingsNavigationModel {
    var selectedSection: SettingsSection
    /// A one-shot search query handed to the Hotkeys tab on navigation. The
    /// Hotkeys view consumes and clears it on appear so it filters to the
    /// relevant bindings (e.g. the debug commands) instead of showing all.
    var hotkeySearchSeed: String?
    /// A one-shot pre-filled app-rule draft handed to the App Rules tab on
    /// navigation (e.g. from the "Create App Rule for Focused Window…"
    /// command). AppRulesView consumes and clears it on appear / change so the
    /// add editor opens on the seeded draft exactly once.
    var pendingAppRuleDraft: AppRuleDraft?

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
            SettingsSidebar(selection: $navigation.selectedSection, controller: controller, settings: settings)
        } detail: {
            SettingsDetailView(
                section: navigation.selectedSection,
                settings: settings,
                controller: controller,
                navigation: navigation,
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

    @State private var resultStatus: SettingsFileStatus?
    @State private var resultVisible = false
    @State private var dismissTask: DispatchWorkItem?

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

            Section("Onboarding") {
                Button("Re-run Setup Wizard") {
                    OnboardingWindowController.shared.rerun()
                }
                SettingInfo(text: "Walk through the onboarding steps again.", consequence: nil)
            }

            if let cliManager {
                CLISettingsSection(cliManager: cliManager)
            }

            ConfigurationFilesSection(settings: settings) { action in
                performAction(action)
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
        .onDisappear {
            dismissTask?.cancel()
            dismissTask = nil
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

    @State private var selectedScope: NiriSettingsScope = .global
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    private var inactiveOverrides: [MonitorNiriSettings] {
        settings.inactiveNiriSettings(connectedMonitors: connectedMonitors)
    }

    var body: some View {
        Form {
            NiriScopeSection(
                selectedScope: $selectedScope,
                connectedMonitors: connectedMonitors,
                inactiveOverrides: inactiveOverrides,
                hasOverrides: { settings.niriSettings(for: $0, connectedMonitors: connectedMonitors) != nil },
                resetConnected: { monitor in
                    settings.removeNiriSettings(for: monitor, connectedMonitors: connectedMonitors)
                    controller.updateMonitorNiriSettings()
                },
                deleteInactive: { id in
                    settings.removeNiriSettings(id: id)
                    selectedScope = .global
                    controller.updateMonitorNiriSettings()
                }
            )

            switch selectedScope {
            case .global:
                GlobalNiriSettingsSection(
                    settings: settings,
                    controller: controller
                )
            case let .connected(monitorId):
                if let monitor = connectedMonitors.first(where: { $0.id == monitorId }) {
                    MonitorNiriSettingsSection(
                        settings: settings,
                        controller: controller,
                        monitor: monitor,
                        connectedMonitors: connectedMonitors
                    )
                } else {
                    GlobalNiriSettingsSection(
                        settings: settings,
                        controller: controller
                    )
                }
            case let .inactiveOverride(id):
                if let override = inactiveOverrides.first(where: { $0.id == id }) {
                    SavedMonitorNiriOverrideSection(
                        override: override,
                        deleteOverride: {
                            settings.removeNiriSettings(id: id)
                            selectedScope = .global
                            controller.updateMonitorNiriSettings()
                        }
                    )
                } else {
                    GlobalNiriSettingsSection(
                        settings: settings,
                        controller: controller
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshConnectedMonitors()
        }
    }

    private func refreshConnectedMonitors() {
        connectedMonitors = Monitor.current()
        switch selectedScope {
        case .global:
            break
        case let .connected(monitorId):
            if !connectedMonitors.contains(where: { $0.id == monitorId }) {
                selectedScope = .global
            }
        case let .inactiveOverride(id):
            if !inactiveOverrides.contains(where: { $0.id == id }) {
                selectedScope = .global
            }
        }
    }
}

enum NiriSettingsScope: Hashable {
    case global
    case connected(Monitor.ID)
    case inactiveOverride(MonitorNiriSettings.ID)
}

struct NiriScopeSection: View {
    @Binding var selectedScope: NiriSettingsScope
    let connectedMonitors: [Monitor]
    let inactiveOverrides: [MonitorNiriSettings]
    let hasOverrides: (Monitor) -> Bool
    let resetConnected: (Monitor) -> Void
    let deleteInactive: (MonitorNiriSettings.ID) -> Void

    var body: some View {
        Section("Configuration Scope") {
            Picker("Configure", selection: $selectedScope) {
                Text("Global Defaults").tag(NiriSettingsScope.global)
                if !connectedMonitors.isEmpty {
                    Divider()
                    ForEach(connectedMonitors, id: \.id) { monitor in
                        HStack {
                            Text(monitor.name)
                            if monitor.isMain {
                                Text("(Main)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(NiriSettingsScope.connected(monitor.id))
                    }
                }
                if !inactiveOverrides.isEmpty {
                    Divider()
                    ForEach(inactiveOverrides) { override in
                        Text("\(override.monitorName) — Inactive")
                            .tag(NiriSettingsScope.inactiveOverride(override.id))
                    }
                }
            }

            statusRow
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch selectedScope {
        case .global:
            EmptyView()
        case let .connected(monitorId):
            if let monitor = connectedMonitors.first(where: { $0.id == monitorId }) {
                LabeledContent("Overrides") {
                    HStack {
                        Text(hasOverrides(monitor) ? "Custom" : "Using global defaults")
                            .foregroundStyle(.secondary)
                        Button("Reset to Global") {
                            resetConnected(monitor)
                        }
                        .disabled(!hasOverrides(monitor))
                    }
                }
            }
        case let .inactiveOverride(id):
            LabeledContent("Status") {
                HStack {
                    Text("Inactive / disconnected")
                        .foregroundStyle(.secondary)
                    Button("Delete Override") {
                        deleteInactive(id)
                    }
                }
            }
        }
    }
}

struct SavedMonitorNiriOverrideSection: View {
    let override: MonitorNiriSettings
    let deleteOverride: () -> Void

    var body: some View {
        Section("Saved Display Override") {
            LabeledContent("Display") {
                Text(override.monitorName)
            }
            LabeledContent("Status") {
                Text("Inactive / disconnected")
                    .foregroundStyle(.secondary)
            }
            if let displayId = override.monitorDisplayId {
                LabeledContent("Runtime Display ID") {
                    Text("\(displayId) (advisory)")
                        .foregroundStyle(.secondary)
                }
            }
            if let anchor = override.monitorAnchorPoint {
                LabeledContent("Saved Position") {
                    Text("x \(formatCoordinate(anchor.x)), y \(formatCoordinate(anchor.y))")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Delete Override", role: .destructive) {
                deleteOverride()
            }
            SettingsCaption(
                "This saved display override is not active for any connected monitor. It is kept on disk until you delete it."
            )
        }

        Section("Saved Niri Values") {
            LabeledContent("Columns to Fit") {
                Text(override.balancedColumnCount.map(String.init) ?? "Uses global default")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Single-Window Default") {
                Text(loneWindowPolicyDescription)
                    .foregroundStyle(.secondary)
            }
            SettingsCaption(
                "Inactive overrides are read-only here; reconnect the display to edit them as an active monitor."
            )
        }
    }

    private var loneWindowPolicyDescription: String {
        switch override.loneWindowPolicy {
        case .fill:
            return "Fill"
        case let .centered(maxWidthFraction):
            return "Centered (\(Int((maxWidthFraction * 100).rounded()))%)"
        case .none:
            return "Uses global default"
        }
    }

    private func formatCoordinate(_ coordinate: CGFloat) -> String {
        coordinate == coordinate.rounded() ? String(Int(coordinate)) : String(Double(coordinate))
    }
}

private enum DefaultColumnWidthMode: String, CaseIterable, Identifiable {
    case balanced
    case custom

    var id: String {
        rawValue
    }
}

private enum LoneWindowMode: String, CaseIterable, Identifiable {
    case fill
    case centered

    var id: String {
        rawValue
    }
}

private enum LoneWindowOverrideMode: String, CaseIterable, Identifiable {
    case inherit
    case fill
    case centered

    var id: String {
        rawValue
    }
}

private struct StableSettingsControlRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        LabeledContent(label) {
            content()
                .frame(minHeight: 32, alignment: .center)
        }
    }
}

private struct PercentTextField: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let onCommit: (Int) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var clampedValue: Int {
        value.clamped(to: range)
    }

    var body: some View {
        HStack {
            TextField(title, text: $draft)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .onSubmit(commitDraft)
                .onAppear { restoreDraftFromValue() }
                .onChange(of: value) { _, _ in
                    if !isFocused { restoreDraftFromValue() }
                }
                .onChange(of: isFocused) { _, focused in
                    if focused {
                        restoreDraftFromValue()
                    } else {
                        commitDraft()
                    }
                }
            Text("%")
                .foregroundStyle(.secondary)
        }
    }

    private func restoreDraftFromValue() {
        draft = String(clampedValue)
    }

    private func commitDraft() {
        let parsed = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)) ?? clampedValue
        let committed = parsed.clamped(to: range)
        draft = String(committed)
        onCommit(committed)
    }
}

struct GlobalNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        let defaultColumnWidthMode = Binding(
            get: { settings.niriDefaultColumnWidth == nil ? DefaultColumnWidthMode.balanced : .custom },
            set: { mode in
                settings.niriDefaultColumnWidth = mode == .balanced ? nil : (settings.niriDefaultColumnWidth ?? 0.5)
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
        let niriBalancedColumnCount = Binding(
            get: { settings.niriBalancedColumnCount },
            set: { newValue in
                settings.niriBalancedColumnCount = newValue.clamped(to: 1 ... 5)
                controller.updateNiriConfig(balancedColumnCount: settings.niriBalancedColumnCount)
            }
        )
        let loneWindowMode = Binding(
            get: { settings.niriLoneWindowMaxWidth == nil ? LoneWindowMode.fill : .centered },
            set: { mode in
                settings.niriLoneWindowMaxWidth = mode == .fill ? nil : (settings.niriLoneWindowMaxWidth ?? 0.6)
                controller.updateNiriConfig(loneWindowPolicy: settings.loneWindowPolicy)
            }
        )
        let loneWindowMaxWidthPercent = Binding(
            get: { Int((settings.niriLoneWindowMaxWidth ?? 0.6) * 100) },
            set: { newPercent in
                settings.niriLoneWindowMaxWidth = Double(newPercent.clamped(to: 10 ... 100)) / 100.0
                controller.updateNiriConfig(loneWindowPolicy: settings.loneWindowPolicy)
            }
        )
        let presets = settings.niriColumnWidthPresets

        Section("Default Column Width") {
            LabeledContent("Mode") {
                Picker("Default Column Width Mode", selection: defaultColumnWidthMode) {
                    Text("Balanced").tag(DefaultColumnWidthMode.balanced)
                    Text("Custom").tag(DefaultColumnWidthMode.custom)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            if settings.niriDefaultColumnWidth == nil {
                StableSettingsControlRow("Columns to Fit") {
                    Stepper("\(settings.niriBalancedColumnCount)", value: niriBalancedColumnCount, in: 1 ... 5)
                }
            } else {
                StableSettingsControlRow("Width") {
                    PercentTextField(
                        title: "Width",
                        value: defaultColumnWidthPercent.wrappedValue,
                        range: 5 ... 100,
                        onCommit: { defaultColumnWidthPercent.wrappedValue = $0 }
                    )
                }
            }

            SettingsCaption(
                "Applies when a column is created or reset. Existing columns are not resized by this setting."
            )
        }

        Section("Single-Window Default") {
            LabeledContent("Mode") {
                Picker("Single-Window Default Mode", selection: loneWindowMode) {
                    Text("Fill").tag(LoneWindowMode.fill)
                    Text("Centered").tag(LoneWindowMode.centered)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            if settings.niriLoneWindowMaxWidth != nil {
                StableSettingsControlRow("Centered Width") {
                    PercentTextField(
                        title: "Centered Width",
                        value: loneWindowMaxWidthPercent.wrappedValue,
                        range: 10 ... 100,
                        onCommit: { loneWindowMaxWidthPercent.wrappedValue = $0 }
                    )
                }
            }

            SettingsCaption(
                "Applies only while a workspace has exactly one normal, non-tabbed window. Manual width changes override it."
            )
        }

        Section("Resize Presets") {
            ForEach(presets.indices, id: \.self) { index in
                LabeledContent("Preset \(index + 1)") {
                    HStack {
                        PercentTextField(
                            title: "Preset \(index + 1)",
                            value: Int(presets[index] * 100),
                            range: 5 ... 100,
                            onCommit: { newPercent in
                                var current = settings.niriColumnWidthPresets
                                current[index] = Double(newPercent) / 100.0
                                settings.niriColumnWidthPresets = current
                                controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                            }
                        )
                        .accessibilityLabel("Preset \(index + 1) width")
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
                Button("Reset Resize Presets") {
                    settings.niriColumnWidthPresets = SettingsStore.defaultColumnWidthPresets
                    controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                }
            }
            SettingsCaption("Used only by width-cycle commands. These do not affect default column width.")
        }
        .id(settings.niriColumnWidthPresets.count)
    }
}

struct MonitorNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor
    var connectedMonitors: [Monitor] = []

    private var monitorSettings: MonitorNiriSettings {
        settings.niriSettings(for: monitor, connectedMonitors: connectedMonitors) ?? MonitorNiriSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId,
            monitorAnchorPoint: monitor.workspaceAnchorPoint
        )
    }

    private func updateSetting(_ update: (inout MonitorNiriSettings) -> Void) {
        var ms = monitorSettings
        ms.monitorName = monitor.name
        ms.monitorDisplayId = monitor.displayId
        ms.monitorAnchorPoint = monitor.workspaceAnchorPoint
        update(&ms)
        settings.updateNiriSettings(ms)
        controller.updateMonitorNiriSettings()
    }

    var body: some View {
        let ms = monitorSettings

        let loneWindowOverrideMode = Binding<LoneWindowOverrideMode>(
            get: {
                if let policy = ms.loneWindowPolicy {
                    switch policy {
                    case .fill: return .fill
                    case .centered: return .centered
                    }
                }
                return .inherit
            },
            set: { mode in
                updateSetting {
                    switch mode {
                    case .inherit:
                        $0.loneWindowPolicy = nil
                    case .fill:
                        $0.loneWindowPolicy = .fill
                    case .centered:
                        let existingWidth: Double
                        if case let .centered(widthFraction) = ms.loneWindowPolicy {
                            existingWidth = widthFraction
                        } else if let globalWidth = settings.niriLoneWindowMaxWidth {
                            existingWidth = globalWidth
                        } else {
                            existingWidth = 0.6
                        }
                        $0.loneWindowPolicy = .centered(maxWidthFraction: existingWidth)
                    }
                }
            }
        )
        let loneWindowMaxWidthPercent = Binding(
            get: {
                let fraction: Double
                if case let .centered(widthFraction) = ms.loneWindowPolicy {
                    fraction = widthFraction
                } else {
                    fraction = settings.niriLoneWindowMaxWidth ?? 0.6
                }
                return Int(fraction * 100)
            },
            set: { newPercent in
                updateSetting {
                    $0
                        .loneWindowPolicy =
                        .centered(maxWidthFraction: Double(newPercent.clamped(to: 10 ... 100)) / 100.0)
                }
            }
        )

        Section("Monitor Column Defaults") {
            OverridableStepper(
                label: "Columns to Fit",
                value: ms.balancedColumnCount.map { Double($0) },
                globalValue: Double(settings.niriBalancedColumnCount),
                range: 1 ... 5,
                step: 1,
                formatter: { "\(Int($0))" },
                onChange: { newValue in updateSetting { $0.balancedColumnCount = Int(newValue) } },
                onReset: { updateSetting { $0.balancedColumnCount = nil } }
            )
            SettingsCaption(
                "Overrides the Balanced column count on this monitor. Used only when Default Column Width is Balanced."
            )
        }

        Section("Monitor Single-Window Default") {
            LabeledContent("Mode") {
                HStack {
                    Picker("Single-Window Default Mode", selection: loneWindowOverrideMode) {
                        Text("Use Global").tag(LoneWindowOverrideMode.inherit)
                        Text("Fill").tag(LoneWindowOverrideMode.fill)
                        Text("Centered").tag(LoneWindowOverrideMode.centered)
                    }
                    .labelsHidden()

                    OverrideStatusIndicator(
                        isOverridden: ms.loneWindowPolicy != nil,
                        resetTitle: "Reset one-window layout to global default",
                        globalAccessibilityLabel: "Single-window default uses global setting"
                    ) {
                        updateSetting { $0.loneWindowPolicy = nil }
                    }
                }
            }

            if case .centered = ms.loneWindowPolicy {
                StableSettingsControlRow("Centered Width") {
                    PercentTextField(
                        title: "Centered Width",
                        value: loneWindowMaxWidthPercent.wrappedValue,
                        range: 10 ... 100,
                        onCommit: { loneWindowMaxWidthPercent.wrappedValue = $0 }
                    )
                }
            }

            SettingsCaption(
                "Use Global inherits the main setting. Fill or Centered overrides only this monitor's single-window default."
            )
        }
    }
}
