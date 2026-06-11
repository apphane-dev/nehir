import SwiftUI

struct LayoutSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            Section("Inner Gaps") {
                SettingsSliderRow(
                    label: "Gap Size",
                    value: $settings.gapSize,
                    range: 0 ... 32,
                    step: 1,
                    valueText: "\(Int(settings.gapSize)) px",
                    valueWidth: 64
                )
                .onChange(of: settings.gapSize) { _, newValue in
                    controller.setGapSize(newValue)
                }
                SettingsCaption("Space between tiled windows.")
            }

            Section("Outer Margins") {
                SettingsSliderRow(
                    label: "Left",
                    value: $settings.outerGapLeft,
                    range: 0 ... 64,
                    step: 1,
                    valueText: "\(Int(settings.outerGapLeft)) px",
                    valueWidth: 64
                )
                .onChange(of: settings.outerGapLeft) { _, _ in
                    syncOuterGaps()
                }

                SettingsSliderRow(
                    label: "Right",
                    value: $settings.outerGapRight,
                    range: 0 ... 64,
                    step: 1,
                    valueText: "\(Int(settings.outerGapRight)) px",
                    valueWidth: 64
                )
                .onChange(of: settings.outerGapRight) { _, _ in
                    syncOuterGaps()
                }

                SettingsSliderRow(
                    label: "Top",
                    value: $settings.outerGapTop,
                    range: 0 ... 64,
                    step: 1,
                    valueText: "\(Int(settings.outerGapTop)) px",
                    valueWidth: 64
                )
                .onChange(of: settings.outerGapTop) { _, _ in
                    syncOuterGaps()
                }

                SettingsSliderRow(
                    label: "Bottom",
                    value: $settings.outerGapBottom,
                    range: 0 ... 64,
                    step: 1,
                    valueText: "\(Int(settings.outerGapBottom)) px",
                    valueWidth: 64
                )
                .onChange(of: settings.outerGapBottom) { _, _ in
                    syncOuterGaps()
                }
                SettingsCaption("Inset the entire tiled layout from the screen edges.")
            }

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

    private func syncOuterGaps() {
        controller.setOuterGaps(
            left: settings.outerGapLeft,
            right: settings.outerGapRight,
            top: settings.outerGapTop,
            bottom: settings.outerGapBottom
        )
    }
}
