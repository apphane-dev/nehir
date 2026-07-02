// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI

struct WorkspaceBarSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedScope: BarSettingsScope = .global
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    private var inactiveOverrides: [MonitorBarSettings] {
        settings.inactiveBarSettings(connectedMonitors: connectedMonitors)
    }

    var body: some View {
        Form {
            BarScopeSection(
                selectedScope: $selectedScope,
                connectedMonitors: connectedMonitors,
                inactiveOverrides: inactiveOverrides,
                hasOverrides: { settings.barSettings(for: $0, connectedMonitors: connectedMonitors) != nil },
                resetConnected: { monitor in
                    settings.removeBarSettings(for: monitor, connectedMonitors: connectedMonitors)
                    controller.updateWorkspaceBarSettings()
                },
                deleteInactive: { id in
                    settings.removeBarSettings(id: id)
                    selectedScope = .global
                    controller.updateWorkspaceBarSettings()
                }
            )

            WorkspaceBarPreviewSection(configuration: previewConfiguration)

            switch selectedScope {
            case .global:
                GlobalBarSettingsSection(
                    settings: settings,
                    controller: controller
                )
            case let .connected(monitorId):
                if let monitor = connectedMonitors.first(where: { $0.id == monitorId }) {
                    MonitorBarSettingsSection(
                        settings: settings,
                        controller: controller,
                        monitor: monitor,
                        connectedMonitors: connectedMonitors
                    )
                } else {
                    GlobalBarSettingsSection(
                        settings: settings,
                        controller: controller
                    )
                }
            case let .inactiveOverride(id):
                if let override = inactiveOverrides.first(where: { $0.id == id }) {
                    SavedMonitorBarOverrideSection(
                        override: override,
                        deleteOverride: {
                            settings.removeBarSettings(id: id)
                            selectedScope = .global
                            controller.updateWorkspaceBarSettings()
                        }
                    )
                } else {
                    GlobalBarSettingsSection(
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

    private var previewConfiguration: WorkspaceBarPreviewConfiguration {
        switch selectedScope {
        case .global:
            return WorkspaceBarPreviewConfiguration(
                isEnabled: settings.workspaceBarEnabled,
                showLabels: settings.workspaceBarShowLabels,
                showFloatingWindows: settings.workspaceBarShowFloatingWindows,
                showScrollLockButton: settings.workspaceBarShowScrollLockButton,
                deduplicateAppIcons: settings.workspaceBarDeduplicateAppIcons,
                hideEmptyWorkspaces: settings.workspaceBarHideEmptyWorkspaces,
                showWorkspacesFromOtherDisplays: settings.workspaceBarShowWorkspacesFromOtherDisplays,
                scopeDescription: "Preview reflects the global workspace bar defaults."
            )
        case let .connected(monitorId):
            guard let monitor = connectedMonitors.first(where: { $0.id == monitorId }) else {
                return WorkspaceBarPreviewConfiguration.global(settings: settings)
            }
            return WorkspaceBarPreviewConfiguration(
                resolved: settings.resolvedBarSettings(for: monitor, connectedMonitors: connectedMonitors),
                scopeDescription: "Preview reflects \(monitor.name)'s effective bar settings, including monitor overrides."
            )
        case let .inactiveOverride(id):
            guard let override = inactiveOverrides.first(where: { $0.id == id }) else {
                return WorkspaceBarPreviewConfiguration.global(settings: settings)
            }
            return WorkspaceBarPreviewConfiguration(
                override: override,
                settings: settings,
                scopeDescription: "Preview reflects the saved inactive override for \(override.monitorName)."
            )
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

private enum BarSettingsScope: Hashable {
    case global
    case connected(Monitor.ID)
    case inactiveOverride(MonitorBarSettings.ID)
}

private struct BarScopeSection: View {
    @Binding var selectedScope: BarSettingsScope
    let connectedMonitors: [Monitor]
    let inactiveOverrides: [MonitorBarSettings]
    let hasOverrides: (Monitor) -> Bool
    let resetConnected: (Monitor) -> Void
    let deleteInactive: (MonitorBarSettings.ID) -> Void

    var body: some View {
        Section("Configuration Scope") {
            Picker("Configure", selection: $selectedScope) {
                Text("Global Defaults").tag(BarSettingsScope.global)
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
                        .tag(BarSettingsScope.connected(monitor.id))
                    }
                }
                if !inactiveOverrides.isEmpty {
                    Divider()
                    ForEach(inactiveOverrides) { override in
                        Text("\(override.monitorName) — Inactive")
                            .tag(BarSettingsScope.inactiveOverride(override.id))
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

private struct WorkspaceBarPreviewConfiguration {
    let isEnabled: Bool
    let showLabels: Bool
    let showFloatingWindows: Bool
    let showScrollLockButton: Bool
    let deduplicateAppIcons: Bool
    let hideEmptyWorkspaces: Bool
    let showWorkspacesFromOtherDisplays: Bool
    let scopeDescription: String

    init(
        isEnabled: Bool,
        showLabels: Bool,
        showFloatingWindows: Bool,
        showScrollLockButton: Bool,
        deduplicateAppIcons: Bool,
        hideEmptyWorkspaces: Bool,
        showWorkspacesFromOtherDisplays: Bool,
        scopeDescription: String
    ) {
        self.isEnabled = isEnabled
        self.showLabels = showLabels
        self.showFloatingWindows = showFloatingWindows
        self.showScrollLockButton = showScrollLockButton
        self.deduplicateAppIcons = deduplicateAppIcons
        self.hideEmptyWorkspaces = hideEmptyWorkspaces
        self.showWorkspacesFromOtherDisplays = showWorkspacesFromOtherDisplays
        self.scopeDescription = scopeDescription
    }

    init(resolved: ResolvedBarSettings, scopeDescription: String) {
        self.init(
            isEnabled: resolved.enabled,
            showLabels: resolved.showLabels,
            showFloatingWindows: resolved.showFloatingWindows,
            showScrollLockButton: resolved.showScrollLockButton,
            deduplicateAppIcons: resolved.deduplicateAppIcons,
            hideEmptyWorkspaces: resolved.hideEmptyWorkspaces,
            showWorkspacesFromOtherDisplays: resolved.showWorkspacesFromOtherDisplays,
            scopeDescription: scopeDescription
        )
    }

    @MainActor init(override: MonitorBarSettings, settings: SettingsStore, scopeDescription: String) {
        self.init(
            isEnabled: override.enabled ?? settings.workspaceBarEnabled,
            showLabels: override.showLabels ?? settings.workspaceBarShowLabels,
            showFloatingWindows: override.showFloatingWindows ?? settings.workspaceBarShowFloatingWindows,
            showScrollLockButton: override.showScrollLockButton ?? settings.workspaceBarShowScrollLockButton,
            deduplicateAppIcons: override.deduplicateAppIcons ?? settings.workspaceBarDeduplicateAppIcons,
            hideEmptyWorkspaces: override.hideEmptyWorkspaces ?? settings.workspaceBarHideEmptyWorkspaces,
            showWorkspacesFromOtherDisplays: override.showWorkspacesFromOtherDisplays ??
                settings.workspaceBarShowWorkspacesFromOtherDisplays,
            scopeDescription: scopeDescription
        )
    }

    @MainActor static func global(settings: SettingsStore) -> WorkspaceBarPreviewConfiguration {
        WorkspaceBarPreviewConfiguration(
            isEnabled: settings.workspaceBarEnabled,
            showLabels: settings.workspaceBarShowLabels,
            showFloatingWindows: settings.workspaceBarShowFloatingWindows,
            showScrollLockButton: settings.workspaceBarShowScrollLockButton,
            deduplicateAppIcons: settings.workspaceBarDeduplicateAppIcons,
            hideEmptyWorkspaces: settings.workspaceBarHideEmptyWorkspaces,
            showWorkspacesFromOtherDisplays: settings.workspaceBarShowWorkspacesFromOtherDisplays,
            scopeDescription: "Preview reflects the global workspace bar defaults."
        )
    }
}

private struct WorkspaceBarPreviewSection: View {
    let configuration: WorkspaceBarPreviewConfiguration

    var body: some View {
        Section("Preview & Behavior") {
            VStack(alignment: .leading, spacing: 14) {
                preview
                SettingsCaption(configuration.scopeDescription)
                behaviorList
            }
            .padding(.vertical, 4)
        }
    }

    private var preview: some View {
        ZStack {
            HStack {
                Spacer(minLength: 0)
                WorkspaceBarAnimation(
                    showLabels: configuration.showLabels,
                    showFloatingWindows: configuration.showFloatingWindows,
                    showScrollLockButton: configuration.showScrollLockButton,
                    deduplicateAppIcons: configuration.deduplicateAppIcons,
                    hideEmptyWorkspaces: configuration.hideEmptyWorkspaces,
                    showWorkspacesFromOtherDisplays: configuration.showWorkspacesFromOtherDisplays
                )
                .frame(maxWidth: 360)
                .opacity(configuration.isEnabled ? 1 : 0.35)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)

            if !configuration.isEnabled {
                Text("Disabled for this scope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private var behaviorList: some View {
        VStack(alignment: .leading, spacing: 8) {
            behaviorRow(
                icon: "cursorarrow.click.2",
                title: "Click a workspace",
                text: "Focuses that workspace without warping the pointer."
            )
            behaviorRow(
                icon: "list.bullet.rectangle",
                title: "Right-click a workspace",
                text: "Shows explicit actions to focus it or move the focused window there."
            )
            behaviorRow(
                icon: "arrowshape.turn.up.right",
                title: "Shift-click a workspace",
                text: "Moves the focused window to that workspace as a quick shortcut."
            )
            behaviorRow(
                icon: "rectangle.connected.to.line.below",
                title: "Other displays' workspaces (optional)",
                text: "When enabled, other displays' workspaces appear after a display icon. Click one to switch its display; shift-click to move the focused window there."
            )
            behaviorRow(
                icon: "square.stack.3d.down.right",
                title: "Window, not column",
                text: "Only the focused window moves; moving an entire column is a separate action."
            )
            behaviorRow(
                icon: "macwindow.on.rectangle",
                title: "Window icons and scratchpad",
                text: "Window icons still focus windows, and the scratchpad pill opens the scratchpad."
            )
        }
    }

    private func behaviorRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GlobalBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var pendingAppearanceSync: Task<Void, Never>?

    var body: some View {
        Section("Workspace Bar") {
            Toggle("Enable Workspace Bar", isOn: $settings.workspaceBarEnabled)
                .onChange(of: settings.workspaceBarEnabled) { _, newValue in
                    controller.setWorkspaceBarEnabled(newValue)
                }

            if settings.workspaceBarEnabled {
                Toggle("Show Workspace Labels", isOn: $settings.workspaceBarShowLabels)
                    .onChange(of: settings.workspaceBarShowLabels) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Show Floating Windows", isOn: $settings.workspaceBarShowFloatingWindows)
                    .onChange(of: settings.workspaceBarShowFloatingWindows) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                Toggle("Group Windows by App", isOn: $settings.workspaceBarDeduplicateAppIcons)
                    .onChange(of: settings.workspaceBarDeduplicateAppIcons) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Hide Empty Workspaces", isOn: $settings.workspaceBarHideEmptyWorkspaces)
                    .onChange(of: settings.workspaceBarHideEmptyWorkspaces) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle(
                    "Show Other Displays' Workspaces",
                    isOn: $settings.workspaceBarShowWorkspacesFromOtherDisplays
                )
                .onChange(of: settings.workspaceBarShowWorkspacesFromOtherDisplays) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
                SettingsCaption(
                    "Also shows other displays' workspaces after a display icon. Click one to switch its display; shift-click to move the focused window there."
                )

                Toggle("Show Scroll Lock Button", isOn: $settings.workspaceBarShowScrollLockButton)
                    .onChange(of: settings.workspaceBarShowScrollLockButton) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                SettingsCaption(
                    "Adds a button that blocks background automatic reveal scrolling. Direct navigation — workspace-bar window clicks, focus commands, trackpad gestures, scroll-viewport hotkeys, and drags — can still move the viewport and does not unlock the workspace."
                )
            }
        }

        if settings.workspaceBarEnabled {
            Section("Actions") {
                SettingsCaption(
                    "Right-click a workspace, window icon, or scratchpad item for actions such as move, float, sticky, scratchpad, app-rule, and close."
                )
            }

            Section("Position & Level") {
                Picker("Position", selection: $settings.workspaceBarPosition) {
                    ForEach(WorkspaceBarPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .onChange(of: settings.workspaceBarPosition) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                Picker("Window Level", selection: $settings.workspaceBarWindowLevel) {
                    ForEach(WorkspaceBarWindowLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .onChange(of: settings.workspaceBarWindowLevel) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                Toggle("Notch-Aware Positioning", isOn: $settings.workspaceBarNotchAware)
                    .onChange(of: settings.workspaceBarNotchAware) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                SettingsCaption("Offsets the bar to avoid the display notch on MacBook Pro.")

                Toggle("Reserve Space for Workspace Bar", isOn: $settings.workspaceBarReserveLayoutSpace)
                    .onChange(of: settings.workspaceBarReserveLayoutSpace) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                SettingsCaption(
                    "Prevents tiled windows from appearing behind the bar. For finer control, adjust the top margin in Layout settings."
                )
            }

            Section("Position Offset") {
                SettingsNumberStepperRow(
                    label: "X Offset",
                    value: $settings.workspaceBarXOffset,
                    range: -500 ... 500,
                    step: 10,
                    valueText: "\(Int(settings.workspaceBarXOffset)) px"
                )
                .help("Horizontal offset (negative = left, positive = right)")
                .onChange(of: settings.workspaceBarXOffset) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                SettingsNumberStepperRow(
                    label: "Y Offset",
                    value: $settings.workspaceBarYOffset,
                    range: -500 ... 500,
                    step: 10,
                    valueText: "\(Int(settings.workspaceBarYOffset)) px"
                )
                .help("Vertical offset (negative = down, positive = up)")
                .onChange(of: settings.workspaceBarYOffset) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
            }

            Section("Appearance") {
                SettingsSliderRow(
                    label: "Bar Height",
                    value: $settings.workspaceBarHeight,
                    range: 20 ... 40,
                    step: 2,
                    formatter: { "\(Int($0)) px" }
                )
                .onChange(of: settings.workspaceBarHeight) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                SettingsSliderRow(
                    label: "Background Opacity",
                    value: $settings.workspaceBarBackgroundOpacity,
                    range: 0 ... 0.5,
                    step: 0.05,
                    formatter: { "\(Int($0 * 100))%" }
                )
                .onChange(of: settings.workspaceBarBackgroundOpacity) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                Toggle("Custom Accent Color", isOn: customAccentColorBinding)

                if settings.workspaceBarAccentColor != nil {
                    ColorPicker("Accent Color", selection: accentColorBinding, supportsOpacity: false)
                }

                Toggle("Custom Text Color", isOn: customTextColorBinding)

                if settings.workspaceBarTextColor != nil {
                    ColorPicker("Text Color", selection: textColorBinding, supportsOpacity: false)
                }
            }
        }
    }

    private var customAccentColorBinding: Binding<Bool> {
        Binding(
            get: { settings.workspaceBarAccentColor != nil },
            set: { enabled in
                settings.workspaceBarAccentColor = enabled ? settings
                    .workspaceBarAccentColor ?? defaultAccentColor : nil
                debouncedAppearanceSync()
            }
        )
    }

    private var customTextColorBinding: Binding<Bool> {
        Binding(
            get: { settings.workspaceBarTextColor != nil },
            set: { enabled in
                settings.workspaceBarTextColor = enabled ? settings.workspaceBarTextColor ?? defaultTextColor : nil
                debouncedAppearanceSync()
            }
        )
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { (settings.workspaceBarAccentColor ?? defaultAccentColor).swiftUIColor },
            set: { newColor in
                if let color = SettingsColor(color: newColor, preservesAlpha: false) {
                    settings.workspaceBarAccentColor = color
                    debouncedAppearanceSync()
                }
            }
        )
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { (settings.workspaceBarTextColor ?? defaultTextColor).swiftUIColor },
            set: { newColor in
                if let color = SettingsColor(color: newColor, preservesAlpha: false) {
                    settings.workspaceBarTextColor = color
                    debouncedAppearanceSync()
                }
            }
        )
    }

    private var defaultAccentColor: SettingsColor {
        SettingsColor(nsColor: .controlAccentColor, preservesAlpha: false)
            ?? SettingsColor(red: 0, green: 0.4784313725, blue: 1, alpha: 1)
    }

    private var defaultTextColor: SettingsColor {
        SettingsColor(nsColor: .labelColor, preservesAlpha: false)
            ?? SettingsColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    private func debouncedAppearanceSync() {
        pendingAppearanceSync?.cancel()
        pendingAppearanceSync = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            controller.updateWorkspaceBarAppearance()
        }
    }
}

private struct SavedMonitorBarOverrideSection: View {
    let override: MonitorBarSettings
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
                "This saved workspace-bar override is not active for any connected monitor. It is kept on disk until you delete it."
            )
        }

        Section("Saved Workspace Bar Values") {
            savedValue("Enabled", override.enabled.map { $0 ? "On" : "Off" })
            savedValue("Show Workspace Labels", override.showLabels.map { $0 ? "On" : "Off" })
            savedValue("Show Floating Windows", override.showFloatingWindows.map { $0 ? "On" : "Off" })
            savedValue("Group Windows by App", override.deduplicateAppIcons.map { $0 ? "On" : "Off" })
            savedValue("Hide Empty Workspaces", override.hideEmptyWorkspaces.map { $0 ? "On" : "Off" })
            savedValue(
                "Show Other Displays' Workspaces",
                override.showWorkspacesFromOtherDisplays.map { $0 ? "On" : "Off" }
            )
            savedValue("Show Trace Capture Button", override.showTraceButton.map { $0 ? "On" : "Off" })
            savedValue("Show Scroll Lock Button", override.showScrollLockButton.map { $0 ? "On" : "Off" })
            savedValue("Position", override.position?.displayName)
            savedValue("Window Level", override.windowLevel?.displayName)
            savedValue("Notch-Aware Positioning", override.notchAware.map { $0 ? "On" : "Off" })
            savedValue("Reserve Space", override.reserveLayoutSpace.map { $0 ? "On" : "Off" })
            savedValue("X Offset", override.xOffset.map { "\(Int($0)) px" })
            savedValue("Y Offset", override.yOffset.map { "\(Int($0)) px" })
            savedValue("Bar Height", override.height.map { "\(Int($0)) px" })
            savedValue("Background Opacity", override.backgroundOpacity.map { "\(Int($0 * 100))%" })
            SettingsCaption(
                "Inactive overrides are read-only here; reconnect the display to edit them as an active monitor."
            )
        }
    }

    private func savedValue(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? "Uses global default")
                .foregroundStyle(.secondary)
        }
    }

    private func formatCoordinate(_ coordinate: CGFloat) -> String {
        coordinate == coordinate.rounded() ? String(Int(coordinate)) : String(Double(coordinate))
    }
}

private struct MonitorBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor
    var connectedMonitors: [Monitor] = []

    private var monitorSettings: MonitorBarSettings {
        settings.barSettings(for: monitor, connectedMonitors: connectedMonitors) ?? MonitorBarSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId,
            monitorAnchorPoint: monitor.workspaceAnchorPoint
        )
    }

    private func updateSetting(_ update: (inout MonitorBarSettings) -> Void) {
        var ms = monitorSettings
        ms.monitorName = monitor.name
        ms.monitorDisplayId = monitor.displayId
        ms.monitorAnchorPoint = monitor.workspaceAnchorPoint
        update(&ms)
        settings.updateBarSettings(ms)
        controller.updateWorkspaceBarSettings()
    }

    var body: some View {
        let ms = monitorSettings

        Section("Workspace Bar") {
            OverridableToggle(
                label: "Enable Workspace Bar",
                value: ms.enabled,
                globalValue: settings.workspaceBarEnabled,
                onChange: { newValue in updateSetting { $0.enabled = newValue } },
                onReset: { updateSetting { $0.enabled = nil } }
            )

            OverridableToggle(
                label: "Show Workspace Labels",
                value: ms.showLabels,
                globalValue: settings.workspaceBarShowLabels,
                onChange: { newValue in updateSetting { $0.showLabels = newValue } },
                onReset: { updateSetting { $0.showLabels = nil } }
            )

            OverridableToggle(
                label: "Show Floating Windows",
                value: ms.showFloatingWindows,
                globalValue: settings.workspaceBarShowFloatingWindows,
                onChange: { newValue in updateSetting { $0.showFloatingWindows = newValue } },
                onReset: { updateSetting { $0.showFloatingWindows = nil } }
            )

            OverridableToggle(
                label: "Group Windows by App",
                value: ms.deduplicateAppIcons,
                globalValue: settings.workspaceBarDeduplicateAppIcons,
                onChange: { newValue in updateSetting { $0.deduplicateAppIcons = newValue } },
                onReset: { updateSetting { $0.deduplicateAppIcons = nil } }
            )
            .help("Group windows by app with badge count")

            OverridableToggle(
                label: "Hide Empty Workspaces",
                value: ms.hideEmptyWorkspaces,
                globalValue: settings.workspaceBarHideEmptyWorkspaces,
                onChange: { newValue in updateSetting { $0.hideEmptyWorkspaces = newValue } },
                onReset: { updateSetting { $0.hideEmptyWorkspaces = nil } }
            )

            OverridableToggle(
                label: "Show Other Displays' Workspaces",
                value: ms.showWorkspacesFromOtherDisplays,
                globalValue: settings.workspaceBarShowWorkspacesFromOtherDisplays,
                onChange: { newValue in
                    updateSetting { $0.showWorkspacesFromOtherDisplays = newValue }
                },
                onReset: { updateSetting { $0.showWorkspacesFromOtherDisplays = nil } }
            )
            .help(
                "Also show other displays' workspaces after a display icon."
            )

            OverridableToggle(
                label: "Show Scroll Lock Button",
                value: ms.showScrollLockButton,
                globalValue: settings.workspaceBarShowScrollLockButton,
                onChange: { newValue in updateSetting { $0.showScrollLockButton = newValue } },
                onReset: { updateSetting { $0.showScrollLockButton = nil } }
            )
            .help(
                "Show a button that blocks background automatic reveals. Direct navigation and manual scrolling still work while locked."
            )

            if settings.developerModeEnabled {
                OverridableToggle(
                    label: "Show Trace Capture Button",
                    value: ms.showTraceButton,
                    globalValue: settings.workspaceBarShowTraceButton,
                    onChange: { newValue in updateSetting { $0.showTraceButton = newValue } },
                    onReset: { updateSetting { $0.showTraceButton = nil } }
                )
                .help("Show a trace capture toggle button in the workspace bar")
            }
        }

        Section("Position & Level") {
            OverridablePicker(
                label: "Position",
                value: ms.position,
                globalValue: settings.workspaceBarPosition,
                options: WorkspaceBarPosition.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.position = newValue } },
                onReset: { updateSetting { $0.position = nil } }
            )

            OverridablePicker(
                label: "Window Level",
                value: ms.windowLevel,
                globalValue: settings.workspaceBarWindowLevel,
                options: WorkspaceBarWindowLevel.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.windowLevel = newValue } },
                onReset: { updateSetting { $0.windowLevel = nil } }
            )

            OverridableToggle(
                label: "Notch-Aware Positioning",
                value: ms.notchAware,
                globalValue: settings.workspaceBarNotchAware,
                onChange: { newValue in updateSetting { $0.notchAware = newValue } },
                onReset: { updateSetting { $0.notchAware = nil } }
            )

            OverridableToggle(
                label: "Reserve Space for Workspace Bar",
                value: ms.reserveLayoutSpace,
                globalValue: settings.workspaceBarReserveLayoutSpace,
                onChange: { newValue in updateSetting { $0.reserveLayoutSpace = newValue } },
                onReset: { updateSetting { $0.reserveLayoutSpace = nil } }
            )
            .help(
                "Prevents tiled windows from appearing behind the bar. For finer control, adjust the top margin in Layout settings."
            )
        }

        Section("Position Offset") {
            OverridableStepper(
                label: "X Offset",
                value: ms.xOffset,
                globalValue: settings.workspaceBarXOffset,
                range: -500 ... 500,
                step: 10,
                formatter: { "\(Int($0)) px" },
                onChange: { newValue in updateSetting { $0.xOffset = newValue } },
                onReset: { updateSetting { $0.xOffset = nil } }
            )
            .help("Horizontal offset (negative = left, positive = right)")

            OverridableStepper(
                label: "Y Offset",
                value: ms.yOffset,
                globalValue: settings.workspaceBarYOffset,
                range: -500 ... 500,
                step: 10,
                formatter: { "\(Int($0)) px" },
                onChange: { newValue in updateSetting { $0.yOffset = newValue } },
                onReset: { updateSetting { $0.yOffset = nil } }
            )
            .help("Vertical offset (negative = down, positive = up)")
        }

        Section("Appearance") {
            OverridableSlider(
                label: "Bar Height",
                value: ms.height,
                globalValue: settings.workspaceBarHeight,
                range: 20 ... 40,
                step: 2,
                formatter: { "\(Int($0)) px" },
                onChange: { newValue in updateSetting { $0.height = newValue } },
                onReset: { updateSetting { $0.height = nil } }
            )

            OverridableSlider(
                label: "Background Opacity",
                value: ms.backgroundOpacity,
                globalValue: settings.workspaceBarBackgroundOpacity,
                range: 0 ... 0.5,
                step: 0.05,
                formatter: { "\(Int($0 * 100))%" },
                onChange: { newValue in updateSetting { $0.backgroundOpacity = newValue } },
                onReset: { updateSetting { $0.backgroundOpacity = nil } }
            )
        }
    }
}
