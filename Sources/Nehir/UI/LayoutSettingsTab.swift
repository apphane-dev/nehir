// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

struct LayoutSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedScope: LayoutSettingsScope = .global
    @State private var connectedMonitors: [Monitor] = Monitor.current()
    @State private var draftGapSize: Double?
    @State private var draftOuterGapLeft: Double?
    @State private var draftOuterGapRight: Double?
    @State private var draftOuterGapTop: Double?
    @State private var draftOuterGapBottom: Double?

    private var effectiveGapSize: Double {
        draftGapSize ?? settings.gapSize
    }

    private var effectiveOuterGapLeft: Double {
        draftOuterGapLeft ?? settings.outerGapLeft
    }

    private var effectiveOuterGapRight: Double {
        draftOuterGapRight ?? settings.outerGapRight
    }

    private var effectiveOuterGapTop: Double {
        draftOuterGapTop ?? settings.outerGapTop
    }

    private var effectiveOuterGapBottom: Double {
        draftOuterGapBottom ?? settings.outerGapBottom
    }

    private var inactiveNiriOverrides: [MonitorNiriSettings] {
        settings.inactiveNiriSettings(connectedMonitors: connectedMonitors)
    }

    private var inactiveGapOverrides: [MonitorGapSettings] {
        settings.inactiveGapSettings(connectedMonitors: connectedMonitors)
    }

    var body: some View {
        Form {
            LayoutScopeSection(
                selectedScope: $selectedScope,
                connectedMonitors: connectedMonitors,
                inactiveGapOverrides: inactiveGapOverrides,
                inactiveNiriOverrides: inactiveNiriOverrides,
                hasOverrides: {
                    settings.niriSettings(for: $0, connectedMonitors: connectedMonitors) != nil ||
                        settings.gapSettings(for: $0, connectedMonitors: connectedMonitors)?.hasOverrides == true
                },
                resetConnected: { monitor in
                    settings.removeGapSettings(for: monitor, connectedMonitors: connectedMonitors)
                    settings.removeNiriSettings(for: monitor, connectedMonitors: connectedMonitors)
                    controller.updateMonitorGapSettings()
                    controller.updateMonitorNiriSettings()
                },
                deleteInactiveGap: { id in
                    settings.removeGapSettings(id: id)
                    selectedScope = .global
                    controller.updateMonitorGapSettings()
                },
                deleteInactiveNiri: { id in
                    settings.removeNiriSettings(id: id)
                    selectedScope = .global
                    controller.updateMonitorNiriSettings()
                }
            )

            switch selectedScope {
            case .global:
                globalSpacingSections

                GlobalNiriSettingsSection(
                    settings: settings,
                    controller: controller
                )
            case let .connected(monitorId):
                if let monitor = connectedMonitors.first(where: { $0.id == monitorId }) {
                    MonitorGapSettingsSection(
                        settings: settings,
                        controller: controller,
                        monitor: monitor,
                        connectedMonitors: connectedMonitors
                    )

                    MonitorNiriSettingsSection(
                        settings: settings,
                        controller: controller,
                        monitor: monitor,
                        connectedMonitors: connectedMonitors
                    )
                } else {
                    globalSpacingSections

                    GlobalNiriSettingsSection(
                        settings: settings,
                        controller: controller
                    )
                }
            case let .inactiveGapOverride(id):
                if let override = inactiveGapOverrides.first(where: { $0.id == id }) {
                    SavedMonitorGapOverrideSection(
                        override: override,
                        deleteOverride: {
                            settings.removeGapSettings(id: id)
                            selectedScope = .global
                            controller.updateMonitorGapSettings()
                        }
                    )
                } else {
                    globalSpacingSections

                    GlobalNiriSettingsSection(
                        settings: settings,
                        controller: controller
                    )
                }
            case let .inactiveNiriOverride(id):
                if let override = inactiveNiriOverrides.first(where: { $0.id == id }) {
                    SavedMonitorNiriOverrideSection(
                        override: override,
                        deleteOverride: {
                            settings.removeNiriSettings(id: id)
                            selectedScope = .global
                            controller.updateMonitorNiriSettings()
                        }
                    )
                } else {
                    globalSpacingSections

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
        case let .inactiveGapOverride(id):
            if !inactiveGapOverrides.contains(where: { $0.id == id }) {
                selectedScope = .global
            }
        case let .inactiveNiriOverride(id):
            if !inactiveNiriOverrides.contains(where: { $0.id == id }) {
                selectedScope = .global
            }
        }
    }

    @ViewBuilder
    private var globalSpacingSections: some View {
        Section("Spacing Between Windows") {
            SettingsSliderRow(
                label: "Inner Gap",
                value: Binding(
                    get: { effectiveGapSize },
                    set: { newValue in
                        draftGapSize = newValue
                    }
                ),
                range: 0 ... 32,
                step: 1,
                formatter: { "\(Int($0)) px" },
                valueWidth: 64,
                onEditingChanged: { editing in
                    if !editing { commitGapSizeDraft() }
                }
            )
            SettingsCaption(
                "Global default spacing between neighboring tiled windows. Select a monitor above to override this for that display."
            )
        }

        Section("Screen Margins") {
            SettingsSliderRow(
                label: "Left",
                value: Binding(
                    get: { effectiveOuterGapLeft },
                    set: { newValue in
                        draftOuterGapLeft = newValue
                    }
                ),
                range: 0 ... 64,
                step: 1,
                formatter: { "\(Int($0)) px" },
                valueWidth: 64,
                onEditingChanged: { editing in
                    if !editing { commitOuterGapDrafts() }
                }
            )

            SettingsSliderRow(
                label: "Right",
                value: Binding(
                    get: { effectiveOuterGapRight },
                    set: { newValue in
                        draftOuterGapRight = newValue
                    }
                ),
                range: 0 ... 64,
                step: 1,
                formatter: { "\(Int($0)) px" },
                valueWidth: 64,
                onEditingChanged: { editing in
                    if !editing { commitOuterGapDrafts() }
                }
            )

            SettingsSliderRow(
                label: "Top",
                value: Binding(
                    get: { effectiveOuterGapTop },
                    set: { newValue in
                        draftOuterGapTop = newValue
                    }
                ),
                range: 0 ... 64,
                step: 1,
                formatter: { "\(Int($0)) px" },
                valueWidth: 64,
                onEditingChanged: { editing in
                    if !editing { commitOuterGapDrafts() }
                }
            )

            SettingsSliderRow(
                label: "Bottom",
                value: Binding(
                    get: { effectiveOuterGapBottom },
                    set: { newValue in
                        draftOuterGapBottom = newValue
                    }
                ),
                range: 0 ... 64,
                step: 1,
                formatter: { "\(Int($0)) px" },
                valueWidth: 64,
                onEditingChanged: { editing in
                    if !editing { commitOuterGapDrafts() }
                }
            )
            SettingsCaption(
                "Global default margins for the tiled working area. Select a monitor above to override individual edges for that display."
            )
        }
    }

    private func commitGapSizeDraft() {
        guard let draftGapSize else { return }
        settings.gapSize = draftGapSize
        controller.setGapSize(draftGapSize)
        self.draftGapSize = nil
    }

    private func commitOuterGapDrafts() {
        let left = effectiveOuterGapLeft
        let right = effectiveOuterGapRight
        let top = effectiveOuterGapTop
        let bottom = effectiveOuterGapBottom

        if draftOuterGapLeft != nil { settings.outerGapLeft = left }
        if draftOuterGapRight != nil { settings.outerGapRight = right }
        if draftOuterGapTop != nil { settings.outerGapTop = top }
        if draftOuterGapBottom != nil { settings.outerGapBottom = bottom }

        controller.setOuterGaps(left: left, right: right, top: top, bottom: bottom)

        draftOuterGapLeft = nil
        draftOuterGapRight = nil
        draftOuterGapTop = nil
        draftOuterGapBottom = nil
    }
}

private enum LayoutSettingsScope: Hashable {
    case global
    case connected(Monitor.ID)
    case inactiveGapOverride(MonitorGapSettings.ID)
    case inactiveNiriOverride(MonitorNiriSettings.ID)
}

private struct LayoutScopeSection: View {
    @Binding var selectedScope: LayoutSettingsScope
    let connectedMonitors: [Monitor]
    let inactiveGapOverrides: [MonitorGapSettings]
    let inactiveNiriOverrides: [MonitorNiriSettings]
    let hasOverrides: (Monitor) -> Bool
    let resetConnected: (Monitor) -> Void
    let deleteInactiveGap: (MonitorGapSettings.ID) -> Void
    let deleteInactiveNiri: (MonitorNiriSettings.ID) -> Void

    var body: some View {
        Section("Configuration Scope") {
            Picker("Configure", selection: $selectedScope) {
                Text("Global Defaults").tag(LayoutSettingsScope.global)
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
                        .tag(LayoutSettingsScope.connected(monitor.id))
                    }
                }
                if !inactiveGapOverrides.isEmpty || !inactiveNiriOverrides.isEmpty {
                    Divider()
                    ForEach(inactiveGapOverrides) { override in
                        Text("\(override.monitorName) — Inactive Spacing")
                            .tag(LayoutSettingsScope.inactiveGapOverride(override.id))
                    }
                    ForEach(inactiveNiriOverrides) { override in
                        Text("\(override.monitorName) — Inactive Columns")
                            .tag(LayoutSettingsScope.inactiveNiriOverride(override.id))
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
        case let .inactiveGapOverride(id):
            LabeledContent("Status") {
                HStack {
                    Text("Inactive / disconnected")
                        .foregroundStyle(.secondary)
                    Button("Delete Override") {
                        deleteInactiveGap(id)
                    }
                }
            }
        case let .inactiveNiriOverride(id):
            LabeledContent("Status") {
                HStack {
                    Text("Inactive / disconnected")
                        .foregroundStyle(.secondary)
                    Button("Delete Override") {
                        deleteInactiveNiri(id)
                    }
                }
            }
        }
    }
}

private struct SavedMonitorGapOverrideSection: View {
    let override: MonitorGapSettings
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
                "This saved layout override is not active for any connected monitor. It is kept on disk until you delete it."
            )
        }

        Section("Saved Spacing Values") {
            savedValue("Inner Gap", override.gapSize.map { "\(Int($0)) px" })
            savedValue("Left Margin", override.outerGapLeft.map { "\(Int($0)) px" })
            savedValue("Right Margin", override.outerGapRight.map { "\(Int($0)) px" })
            savedValue("Top Margin", override.outerGapTop.map { "\(Int($0)) px" })
            savedValue("Bottom Margin", override.outerGapBottom.map { "\(Int($0)) px" })
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

struct MonitorGapSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor
    var connectedMonitors: [Monitor] = []

    private var monitorSettings: MonitorGapSettings {
        settings.gapSettings(for: monitor, connectedMonitors: connectedMonitors) ?? MonitorGapSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId,
            monitorAnchorPoint: monitor.workspaceAnchorPoint
        )
    }

    private func updateSetting(_ update: (inout MonitorGapSettings) -> Void) {
        var ms = monitorSettings
        ms.monitorName = monitor.name
        ms.monitorDisplayId = monitor.displayId
        ms.monitorAnchorPoint = monitor.workspaceAnchorPoint
        update(&ms)
        if ms.hasOverrides {
            settings.updateGapSettings(ms)
        } else {
            settings.removeGapSettings(for: monitor, connectedMonitors: connectedMonitors)
        }
        controller.updateMonitorGapSettings()
    }

    var body: some View {
        let ms = monitorSettings

        Section("Monitor Spacing") {
            OverridableSlider(
                label: "Inner Gap",
                value: ms.gapSize,
                globalValue: settings.gapSize,
                range: 0 ... 32,
                step: 1,
                formatter: { "\(Int($0)) px" },
                commitOnEditingEnd: true,
                onChange: { newValue in updateSetting { $0.gapSize = newValue } },
                onReset: { updateSetting { $0.gapSize = nil } }
            )
            SettingsCaption("Overrides spacing between tiled windows on this monitor.")
        }

        Section("Monitor Screen Margins") {
            OverridableSlider(
                label: "Left",
                value: ms.outerGapLeft,
                globalValue: settings.outerGapLeft,
                range: 0 ... 64,
                step: 1,
                formatter: { "\(Int($0)) px" },
                commitOnEditingEnd: true,
                onChange: { newValue in updateSetting { $0.outerGapLeft = newValue } },
                onReset: { updateSetting { $0.outerGapLeft = nil } }
            )
            OverridableSlider(
                label: "Right",
                value: ms.outerGapRight,
                globalValue: settings.outerGapRight,
                range: 0 ... 64,
                step: 1,
                formatter: { "\(Int($0)) px" },
                commitOnEditingEnd: true,
                onChange: { newValue in updateSetting { $0.outerGapRight = newValue } },
                onReset: { updateSetting { $0.outerGapRight = nil } }
            )
            OverridableSlider(
                label: "Top",
                value: ms.outerGapTop,
                globalValue: settings.outerGapTop,
                range: 0 ... 64,
                step: 1,
                formatter: { "\(Int($0)) px" },
                commitOnEditingEnd: true,
                onChange: { newValue in updateSetting { $0.outerGapTop = newValue } },
                onReset: { updateSetting { $0.outerGapTop = nil } }
            )
            OverridableSlider(
                label: "Bottom",
                value: ms.outerGapBottom,
                globalValue: settings.outerGapBottom,
                range: 0 ... 64,
                step: 1,
                formatter: { "\(Int($0)) px" },
                commitOnEditingEnd: true,
                onChange: { newValue in updateSetting { $0.outerGapBottom = newValue } },
                onReset: { updateSetting { $0.outerGapBottom = nil } }
            )
            SettingsCaption("Overrides tiled working-area margins on this monitor.")
        }
    }
}
