import SwiftUI

struct LayoutSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()
    @State private var draftGapSize: Double?
    @State private var draftOuterGapLeft: Double?
    @State private var draftOuterGapRight: Double?
    @State private var draftOuterGapTop: Double?
    @State private var draftOuterGapBottom: Double?

    private var effectiveGapSize: Double { draftGapSize ?? settings.gapSize }
    private var effectiveOuterGapLeft: Double { draftOuterGapLeft ?? settings.outerGapLeft }
    private var effectiveOuterGapRight: Double { draftOuterGapRight ?? settings.outerGapRight }
    private var effectiveOuterGapTop: Double { draftOuterGapTop ?? settings.outerGapTop }
    private var effectiveOuterGapBottom: Double { draftOuterGapBottom ?? settings.outerGapBottom }

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.niriSettings(for: $0) != nil || settings.gapSettings(for: $0)?.hasOverrides == true },
                reset: { monitor in
                    settings.removeGapSettings(for: monitor)
                    settings.removeNiriSettings(for: monitor)
                    controller.updateMonitorGapSettings()
                    controller.updateMonitorNiriSettings()
                }
            )

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorGapSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )

                MonitorNiriSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                globalSpacingSections

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
                valueText: "\(Int(effectiveGapSize)) px",
                valueWidth: 64,
                onEditingChanged: { editing in
                    if !editing { commitGapSizeDraft() }
                }
            )
            SettingsCaption("Global default spacing between neighboring tiled windows. Select a monitor above to override this for that display.")
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
                valueText: "\(Int(effectiveOuterGapLeft)) px",
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
                valueText: "\(Int(effectiveOuterGapRight)) px",
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
                valueText: "\(Int(effectiveOuterGapTop)) px",
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
                valueText: "\(Int(effectiveOuterGapBottom)) px",
                valueWidth: 64,
                onEditingChanged: { editing in
                    if !editing { commitOuterGapDrafts() }
                }
            )
            SettingsCaption("Global default margins for the tiled working area. Select a monitor above to override individual edges for that display.")
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

struct MonitorGapSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorGapSettings {
        settings.gapSettings(for: monitor) ?? MonitorGapSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId
        )
    }

    private func updateSetting(_ update: (inout MonitorGapSettings) -> Void) {
        var ms = monitorSettings
        ms.monitorName = monitor.name
        ms.monitorDisplayId = monitor.displayId
        update(&ms)
        if ms.hasOverrides {
            settings.updateGapSettings(ms)
        } else {
            settings.removeGapSettings(for: monitor)
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
